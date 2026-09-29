import Foundation

// MARK: - Background subagents
//
// `agent` with run_in_background: true starts a subagent that works while
// the main agent carries on (several can run in parallel — "explore the API
// layer" + "audit the tests" at once). Each chat owns one pool. The main
// agent checks on them with `agent_status` (optionally waiting), stops one
// with `agent_stop`, and is told automatically — as an automatic message in
// its next step — when one finishes. Stopping the chat stops its background
// agents too.

public final class BackgroundAgents: @unchecked Sendable {
    public enum Status: String, Sendable {
        case running, done, failed, stopped
    }

    public struct Job: Identifiable, Sendable, Hashable {
        public let id: String
        public let description: String
        public let startedAt: Date
        public var finishedAt: Date?
        public var status: Status
        /// The subagent's final report (or the failure).
        public var report: String?

        public var elapsed: TimeInterval { (finishedAt ?? .now).timeIntervalSince(startedAt) }
    }

    /// How many may run at once — a local model server has finite throughput.
    public let maxConcurrent: Int
    /// Called (on any thread) whenever a job starts, finishes or is stopped.
    public var onChange: (@Sendable (Job) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    private let lock = NSLock()
    private var _onChange: (@Sendable (Job) -> Void)?
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Finished jobs whose result the main agent hasn't been given yet.
    private var unreported: [String] = []
    private var counter = 0

    public init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    public var all: [Job] { lock.withLock { order.compactMap { jobs[$0] } } }
    public var running: [Job] { all.filter { $0.status == .running } }
    public func job(_ id: String) -> Job? { lock.withLock { jobs[id] } }

    /// Start `work` in the background. Returns the job, or an error message
    /// when too many are already running.
    public func launch(description: String,
                       work: @escaping @Sendable () async -> (ok: Bool, report: String)) -> Result<Job, BackgroundAgentsError> {
        let job: Job = lock.withLock {
            counter += 1
            return Job(id: "bg-\(counter)", description: description, startedAt: .now, status: .running)
        }
        let started: Bool = lock.withLock {
            guard jobs.values.count(where: { $0.status == .running }) < maxConcurrent else { return false }
            jobs[job.id] = job
            order.append(job.id)
            return true
        }
        guard started else { return .failure(.tooMany(maxConcurrent)) }
        let task = Task { [weak self] in
            let outcome = await work()
            self?.finish(job.id, status: Task.isCancelled ? .stopped : (outcome.ok ? .done : .failed), report: outcome.report)
        }
        lock.withLock { tasks[job.id] = task }
        onChange?(job)
        return .success(job)
    }

    /// Stop one job. Returns false when there is no such running job.
    @discardableResult
    public func stop(_ id: String) -> Bool {
        let task: Task<Void, Never>? = lock.withLock {
            guard jobs[id]?.status == .running else { return nil }
            return tasks[id]
        }
        guard let task else { return false }
        task.cancel()
        finish(id, status: .stopped, report: "Stopped before it finished.")
        return true
    }

    public func stopAll() {
        for job in running { stop(job.id) }
    }

    /// Wait until the job finishes or `timeout` passes (cancellable).
    public func wait(_ id: String, timeout: TimeInterval) async -> Job? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while let current = job(id), current.status == .running, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return job(id)
    }

    /// Finished jobs the main agent hasn't seen yet (marks them seen).
    public func takeUnreported() -> [Job] {
        lock.withLock {
            let list = unreported.compactMap { jobs[$0] }
            unreported = []
            return list
        }
    }

    /// The main agent read this job's result (agent_status): don't announce it again.
    public func markReported(_ id: String) {
        lock.withLock { unreported.removeAll { $0 == id } }
    }

    private func finish(_ id: String, status: Status, report: String) {
        let job: Job? = lock.withLock {
            guard var job = jobs[id], job.status == .running else { return nil }
            job.status = status
            job.finishedAt = .now
            job.report = report
            jobs[id] = job
            tasks[id] = nil
            if status != .stopped { unreported.append(id) }
            return job
        }
        if let job { onChange?(job) }
    }

    /// The automatic message the main agent gets when jobs finish.
    public static func notice(for finished: [Job]) -> String {
        var lines = ["[Automatic message: \(finished.count == 1 ? "a background agent" : "\(finished.count) background agents") finished. Not from the user.]"]
        for job in finished {
            let report = job.report ?? ""
            let clipped = report.count > 6_000 ? String(report.prefix(6_000)) + "\n[… report truncated]" : report
            lines.append("\n## \(job.id) “\(job.description)” — \(job.status.rawValue) after \(job.elapsed.formattedDuration)\n\(clipped)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum BackgroundAgentsError: Error, Equatable, LocalizedError {
    case tooMany(Int)
    public var errorDescription: String? {
        switch self {
        case .tooMany(let n): "\(n) background agents are already running — wait for one (agent_status with wait_seconds) or stop one first."
        }
    }
}

// MARK: - Tools

public struct AgentStatusTool: ToolExecutor {
    public static let name = "agent_status"
    public static let spec = ToolSpec(
        name: name,
        description: "Check on background subagents started with agent(run_in_background: true). Without an id, lists them all. With an id, returns that agent's full report when it has finished; pass wait_seconds to wait for it (up to 600) instead of polling.",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"A background agent id, e.g. bg-1"},"wait_seconds":{"type":"integer","description":"Wait up to this many seconds for it to finish (max 600)"}}}"#
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pool = context.backgroundAgents else {
            return ToolResult(output: "Error: background agents aren't available here.")
        }
        let id = (Self.string(args, "id") ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            let jobs = pool.all
            guard !jobs.isEmpty else { return ToolResult(output: "No background agents have been started in this chat.") }
            let lines = jobs.map { j -> String in
                var line = "- \(j.id) “\(j.description)”: \(j.status.rawValue), \(j.elapsed.formattedDuration)"
                if j.status != .running, let r = j.report { line += " — " + (r.split(separator: "\n").first.map(String.init) ?? "").prefix(120) }
                return line
            }
            return ToolResult(output: "Background agents:\n" + lines.joined(separator: "\n")
                              + "\nPass an id for a full report (and wait_seconds to wait for a running one).")
        }
        let wait = min(max(JSONArgs.int(args, "wait_seconds", default: 0), 0), 600)
        guard let job = await pool.wait(id, timeout: TimeInterval(wait)) else {
            return ToolResult(output: "Error: no background agent \(id). agent_status without an id lists them.")
        }
        switch job.status {
        case .running:
            return ToolResult(output: "\(job.id) “\(job.description)” is still running (\(job.elapsed.formattedDuration)). Carry on with other work, or wait with wait_seconds.")
        case .done, .failed, .stopped:
            pool.markReported(job.id)
            return ToolResult(output: "\(job.id) “\(job.description)” \(job.status.rawValue) after \(job.elapsed.formattedDuration).\n\n\(job.report ?? "(no report)")")
        }
    }
}

public struct AgentStopTool: ToolExecutor {
    public static let name = "agent_stop"
    public static let spec = ToolSpec(
        name: name,
        description: "Stop a running background subagent (e.g. it's no longer needed, or it's going the wrong way).",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"The background agent id, e.g. bg-2"}},"required":["id"]}"#
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pool = context.backgroundAgents else {
            return ToolResult(output: "Error: background agents aren't available here.")
        }
        let id = (Self.string(args, "id") ?? "").trimmingCharacters(in: .whitespaces)
        return ToolResult(output: pool.stop(id) ? "Stopped \(id)." : "Error: \(id) isn't a running background agent.")
    }
}

/// Adds work to the app's task queue — background tasks that run unattended,
/// one at a time, each in its own chat, after (or alongside) this one.
public struct QueueAddTool: ToolExecutor {
    public static let name = "queue_task"
    public static let spec = ToolSpec(
        name: name,
        description: "Add a background task to the user's task queue. Queued tasks run unattended, one at a time, each in its own chat, until the model declares them complete — use it for follow-up work that can happen after (or independently of) this conversation, e.g. 'write tests for the parser'. Give full instructions: the task's chat won't see this conversation. Set start to true to start the queue if it isn't running.",
        parameters: #"{"type":"object","properties":{"title":{"type":"string","description":"Short title"},"details":{"type":"string","description":"Complete, self-contained instructions"},"front":{"type":"boolean","description":"Put it at the front of the queue"},"start":{"type":"boolean","description":"Start the queue if it isn't running"}},"required":["title","details"]}"#
    )

    /// (title, details, front, start) → a message for the model.
    public let add: @Sendable (String, String, Bool, Bool) async -> String

    public init(add: @escaping @Sendable (String, String, Bool, Bool) async -> String) {
        self.add = add
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let title = (Self.string(args, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (Self.string(args, "details") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ToolResult(output: "Error: title is required.") }
        let out = await add(title, details, JSONArgs.bool(args, "front", default: false), JSONArgs.bool(args, "start", default: false))
        return ToolResult(output: out)
    }
}
