import Foundation

// MARK: - The roster
//
// Every subagent a chat has started — waiting for a server, working, or finished — so a side panel can
// show who is doing what, and where. Foreground and background runs both land here.

public enum AgentRunStatus: String, Sendable, Hashable {
    case running, done, failed, stopped
}

/// One subagent run, as the UI lists it.
public struct AgentRun: Identifiable, Sendable, Hashable {
    public let id: String
    public let description: String
    public let agentType: String
    public let isBackground: Bool
    public let startedAt: Date
    /// The model server it is (or was) running on, once it has one. Only set when there was a choice of servers.
    public var server: String?
    public var status: AgentRunStatus
    /// What it is doing right now ("grep: TODO", "waiting for a free server").
    public var activity: String
    /// Tool calls made so far.
    public var steps: Int
    public var finishedAt: Date?
    /// Its final report (or the failure), once it is over.
    public var report: String?

    public init(id: String, description: String, agentType: String, isBackground: Bool, startedAt: Date,
                server: String? = nil, status: AgentRunStatus = .running, activity: String = "starting",
                steps: Int = 0, finishedAt: Date? = nil, report: String? = nil) {
        self.id = id
        self.description = description
        self.agentType = agentType
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.server = server
        self.status = status
        self.activity = activity
        self.steps = steps
        self.finishedAt = finishedAt
        self.report = report
    }

    public var isRunning: Bool { status == .running }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Every subagent a chat has started. Thread-safe: runs report from whatever thread they are on.
public final class AgentRoster: @unchecked Sendable {
    /// How many runs are kept; the oldest finished ones go first.
    private static let retained = 60

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var runs: [AgentRun] = []
    private var counter = 0
    private var changeHandler: (@Sendable (AgentRun) -> Void)?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Called (on any thread, never with the roster's lock held) whenever a run starts, moves or ends.
    /// A run with an empty `id` means the finished runs were cleared (see `clearFinished()`).
    public var onChange: (@Sendable (AgentRun) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public var all: [AgentRun] { lock.withLock { runs } }

    public var running: [AgentRun] { all.filter(\.isRunning) }

    public func run(_ id: String) -> AgentRun? {
        lock.withLock { runs.first { $0.id == id } }
    }

    /// Register a new run; its id.
    @discardableResult
    public func begin(description: String, agentType: String, background: Bool) -> String {
        let run: AgentRun = lock.withLock {
            counter += 1
            let run = AgentRun(id: "a\(counter)", description: description, agentType: agentType,
                               isBackground: background, startedAt: now())
            runs.append(run)
            // Keep the list bounded: the oldest finished runs go first.
            while runs.count > Self.retained, let old = runs.firstIndex(where: { !$0.isRunning }) {
                runs.remove(at: old)
            }
            return run
        }
        onChange?(run)
        return run.id
    }

    public func update(_ id: String, _ change: (AgentRun) -> AgentRun) {
        let updated: AgentRun? = lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
            let updated = change(runs[index])
            runs[index] = updated
            return updated
        }
        if let updated { onChange?(updated) }
    }

    public func setServer(_ id: String, _ label: String) {
        update(id) { var run = $0; run.server = label; return run }
    }

    /// What the run is doing now; `step` counts it as a tool call.
    public func note(_ id: String, _ activity: String, step: Bool = false) {
        update(id) { run in
            guard run.isRunning else { return run }
            var run = run
            run.activity = activity
            if step { run.steps += 1 }
            return run
        }
    }

    public func finish(_ id: String, status: AgentRunStatus, report: String) {
        let finishedAt = now()
        update(id) { run in
            guard run.isRunning else { return run }
            var run = run
            run.status = status
            run.finishedAt = finishedAt
            run.report = report
            switch status {
            case .done: run.activity = "done"
            case .stopped: run.activity = "stopped"
            default: run.activity = "failed"
            }
            return run
        }
    }

    /// Forget the runs that are over.
    public func clearFinished() {
        lock.withLock { runs.removeAll { !$0.isRunning } }
        onChange?(AgentRun(id: "", description: "", agentType: "", isBackground: false, startedAt: now(), status: .done))
    }
}

// MARK: - Which servers may see what

/// How the main agent is told about the subagent servers and their privacy, in its system prompt and in the `agent`
/// and `delegate` tools' descriptions.
public enum SubagentServers {
    /// One subagent server: its name, and whether it may see sensitive data.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var isPrivate: Bool

        public init(name: String, isPrivate: Bool) {
            self.name = name
            self.isPrivate = isPrivate
        }
    }

    /// "Subagent servers: Spark 2 (private), Kimi Code (not private)"
    public static func list(_ servers: [Entry]) -> String? {
        guard !servers.isEmpty else { return nil }
        return "Subagent servers: " + servers.map { "\($0.name) (\($0.isPrivate ? "private" : "not private"))" }
            .joined(separator: ", ")
    }

    /// What to do about servers that aren't private.
    public static let guidance =
        "Servers that aren't private must not receive sensitive data. Describe their tasks in general terms — no names, credentials, personal or client details; the app also masks what it detects."

    /// What `sensitive` does.
    public static let sensitiveParameter =
        "Set true when the task needs sensitive data (personal data, credentials, client details). It then runs only on a private server."

    /// The whole note, for the system prompt and the tools; nil when there are no subagent servers.
    public static func note(_ servers: [Entry]) -> String? {
        guard let list = list(servers) else { return nil }
        var text = list + ". "
        if servers.contains(where: { !$0.isPrivate }) {
            text += guidance + " A task that needs sensitive data gets sensitive: true, so it runs only on a private server."
        } else {
            text += "All of them are private."
        }
        return text
    }
}
