import XCTest
@testable import DSHCore

// Shared fakes for the fleet tests. Everything here is prefixed `Fleet` so it can sit next to the other
// test files' helpers (ScriptedClient, EchoTool, FlakyClient, …) without clashing with them.

// MARK: - Scratch space

/// A scratch folder under $TMPDIR (`NSTemporaryDirectory()` is not writable everywhere these tests run).
/// Files go in with plain, non-atomic writes for the same reason.
final class FleetTestDirectory: @unchecked Sendable {
    let url: URL

    init(_ name: String = "dsh-fleet") {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        url = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Write `text` at `relative` (folders are created), returning the file.
    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func folder(_ relative: String) -> URL {
        let folder = url.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: - Time and waiting

/// A clock the test moves by hand.
final class FleetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

struct FleetTestTimeout: Error, CustomStringConvertible {
    var description: String { "timed out waiting for the operation" }
}

/// An operation started on its own task, so a test can look at it while it is still waiting — and give up
/// waiting instead of hanging when it never finishes.
final class FleetPending<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var task: Task<Void, Never>?

    init(_ work: @escaping @Sendable () async throws -> T) {
        task = Task { [weak self] in
            let outcome: Result<T, Error>
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            self?.lock.withLock { self?.result = outcome }
        }
    }

    var isDone: Bool { lock.withLock { result != nil } }

    func cancel() { task?.cancel() }

    func value(within seconds: TimeInterval = 4) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let done = lock.withLock({ result }) { return try done.get() }
            if Date() >= deadline {
                task?.cancel()
                throw FleetTestTimeout()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Run `work`, failing the test with a timeout instead of hanging it if it takes longer than `seconds` (a fleet that
/// stopped waking its waiters would otherwise leave the whole test run stuck).
func fleetBounded<T: Sendable>(_ seconds: TimeInterval = 20, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await FleetPending(work).value(within: seconds)
}

/// Poll until `condition` holds (or `seconds` pass); whether it did.
func fleetEventually(_ seconds: TimeInterval = 4, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// A counter that any thread may bump.
final class FleetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func bump() { lock.withLock { count += 1 } }
}

/// A list any thread may append to.
final class FleetLog<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var all: [Element] { lock.withLock { items } }

    func append(_ item: Element) { lock.withLock { items.append(item) } }
}

// MARK: - Servers and contexts

func fleetServer(_ id: String, _ client: any LLMClient, primary: Bool = false, max: Int = 2,
                 resolve: (@Sendable () async throws -> FleetTarget)? = nil) -> FleetServer {
    FleetServer(id: id, label: id, isPrimary: primary, maxParallel: max, resolve: resolve ?? {
        FleetTarget(client: client, model: "model-" + id, contextWindow: 8_000)
    })
}

/// A server whose resolve step fails the way an unreachable Spark's does.
func fleetDeadServer(_ id: String, primary: Bool = false, max: Int = 2,
                     error: any Error = LLMError.connection("no route to host")) -> FleetServer {
    fleetServer(id, FleetReportsClient("never"), primary: primary, max: max, resolve: { throw error })
}

/// A retry policy that does not wait between attempts.
let fleetFastRetry = RetryPolicy(delay: { _ in 0 })

/// A context for running the agent tools directly (no engine around them).
func fleetContext(_ client: any LLMClient, root: URL, fleet: AgentFleet? = nil, roster: AgentRoster? = nil,
                  catalog: AgentCatalog? = nil, registry: ToolRegistry? = nil, depth: Int = 0,
                  retry: RetryPolicy? = nil, background: BackgroundAgents? = nil,
                  contextWindow: Int? = nil) -> ToolContext {
    ToolContext(workspace: root,
                policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                client: client,
                registry: registry ?? ToolRegistry.standard(depth: depth, agents: catalog),
                depth: depth, model: "parent", contextWindow: contextWindow,
                backgroundAgents: background,
                fleet: fleet, roster: roster, agentTypes: catalog, retry: retry)
}

/// A tool that does nothing, under a name of the test's choosing (like a plugin's).
struct FleetStubTool: ToolExecutor {
    static let name = "stub"
    static let spec = ToolSpec(name: "stub", description: "", parameters: "{}")

    let stubName: String

    init(_ name: String) { stubName = name }

    var name: String { stubName }
    var spec: ToolSpec { ToolSpec(name: stubName, description: "stub", parameters: #"{"type":"object","properties":{}}"#) }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        ToolResult(output: "stub")
    }
}

// MARK: - Fake model clients

/// Answers every request with one fixed report and remembers what it was asked.
final class FleetReportsClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var seen: [LLMRequest] = []

    init(_ text: String) { self.text = text }

    var requests: [LLMRequest] { lock.withLock { seen } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.withLock { seen.append(request) }
        let text = text
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.done(calls: [], finish: "stop", usage: nil))
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { ["m"] }
}

/// A barrier: `arrive()` reports whether `parties` callers were inside at once — proof of concurrency. Someone who
/// gives up waiting (or is cancelled) leaves, so callers that come one after another never add up to a meeting.
final class FleetMeeting: @unchecked Sendable {
    private let lock = NSLock()
    private let parties: Int
    private var inside = 0
    private var met = false

    init(parties: Int) { self.parties = parties }

    func arrive(patience: TimeInterval = 4) async -> Bool {
        lock.withLock {
            inside += 1
            if inside >= parties { met = true }
        }
        let deadline = Date().addingTimeInterval(patience)
        while !lock.withLock({ met }) {
            if Date() >= deadline || Task.isCancelled {
                lock.withLock { inside -= 1 }
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

/// Answers only when the meeting's other parties are inside too.
final class FleetRendezvousClient: LLMClient, @unchecked Sendable {
    private let meeting: FleetMeeting
    private let name: String

    init(meeting: FleetMeeting, name: String) {
        self.meeting = meeting
        self.name = name
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let meeting = meeting, name = name
        return AsyncThrowingStream { continuation in
            let task = Task {
                let together = await meeting.arrive()
                continuation.yield(.text("\(name): \(together ? "together" : "alone")"))
                continuation.yield(.done(calls: [], finish: "stop", usage: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { [] }
}

/// Records how many requests were in flight at once.
final class FleetConcurrencyClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                lock.withLock {
                    active += 1
                    highest = max(highest, active)
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
                lock.withLock { active -= 1 }
                continuation.yield(.text("done"))
                continuation.yield(.done(calls: [], finish: "stop", usage: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { [] }
}

/// Never answers; ends when the task waiting on it is cancelled.
final class FleetBlockingClient: LLMClient, @unchecked Sendable {
    private let started = FleetCounter()

    var hasStarted: Bool { started.value > 0 }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        started.bump()
        return AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] { [] }
}

/// Counts how often it is asked, and always refuses with the same error.
final class FleetRefusingClient: LLMClient, @unchecked Sendable {
    private let asks = FleetCounter()
    private let error: any Error

    init(_ error: any Error) { self.error = error }

    var asked: Int { asks.value }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        asks.bump()
        let error = error
        return AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
    }

    func listModels() async throws -> [String] { ["m"] }
}

/// Does one piece of work (an echo), then loses its connection.
final class FleetWritesThenDiesClient: LLMClient, @unchecked Sendable {
    private let calls = FleetCounter()

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        calls.bump()
        let first = calls.value == 1
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.done(calls: [ToolCall(id: "w1", name: "echo", arguments: #"{"text":"x"}"#)],
                                         finish: "stop", usage: nil))
                continuation.finish()
            } else {
                continuation.finish(throwing: LLMError.connection("the server went away"))
            }
        }
    }

    func listModels() async throws -> [String] { ["m"] }
}

/// Answers according to the task it is given: a prompt that says "slow" takes its time, so the tasks of a fan-out
/// finish in a different order than they were started.
final class FleetSlowFirstClient: LLMClient, @unchecked Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let task = request.messages.first { $0.role == .user }?.content ?? ""
        return AsyncThrowingStream { continuation in
            let work = Task {
                if task == "slow" { try? await Task.sleep(nanoseconds: 250_000_000) }
                continuation.yield(.text("report for \(task)"))
                continuation.yield(.done(calls: [], finish: "stop", usage: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    func listModels() async throws -> [String] { [] }
}

/// Serves its scripted turns, then fails every later request.
final class FleetScriptedThenFailsClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ScriptedClient.Turn]
    private let error: any Error
    private var seen: [LLMRequest] = []

    init(turns: [ScriptedClient.Turn], then error: any Error) {
        self.turns = turns
        self.error = error
    }

    var requests: [LLMRequest] { lock.withLock { seen } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let (turn, error): (ScriptedClient.Turn?, any Error) = lock.withLock {
            seen.append(request)
            return (turns.isEmpty ? nil : turns.removeFirst(), self.error)
        }
        return AsyncThrowingStream { continuation in
            if let turn {
                if !turn.text.isEmpty { continuation.yield(.text(turn.text)) }
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    func listModels() async throws -> [String] { [] }
}

/// Records every context the engine hands it.
final class FleetCapturingTool: ToolExecutor, @unchecked Sendable {
    static let name = "capture"
    static let spec = ToolSpec(name: "capture", description: "capture", parameters: "{}")

    private let lock = NSLock()
    private var seen: [ToolContext] = []

    var contexts: [ToolContext] { lock.withLock { seen } }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        lock.withLock { seen.append(context) }
        return ToolResult(output: "captured")
    }
}

/// A tool under a name of the test's choosing that takes its time.
struct FleetSleepyTool: ToolExecutor {
    static let name = "sleepy"
    static let spec = ToolSpec(name: "sleepy", description: "", parameters: "{}")

    let toolName: String
    let seconds: TimeInterval

    init(_ name: String, seconds: TimeInterval) {
        toolName = name
        self.seconds = seconds
    }

    var name: String { toolName }
    var spec: ToolSpec { ToolSpec(name: toolName, description: "sleepy", parameters: #"{"type":"object","properties":{}}"#) }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return ToolResult(output: "slept \(seconds)s")
    }
}

/// A tool under a name of the test's choosing that answers only when its peers are running at the same time.
struct FleetGateTool: ToolExecutor {
    static let name = "gate"
    static let spec = ToolSpec(name: "gate", description: "", parameters: "{}")

    let toolName: String
    let meeting: FleetMeeting
    let patience: TimeInterval

    init(_ name: String, meeting: FleetMeeting, patience: TimeInterval = 4) {
        toolName = name
        self.meeting = meeting
        self.patience = patience
    }

    var name: String { toolName }
    var spec: ToolSpec { ToolSpec(name: toolName, description: "gate", parameters: #"{"type":"object","properties":{}}"#) }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let together = await meeting.arrive(patience: patience)
        return ToolResult(output: together ? "together" : "alone")
    }
}

/// What the engine announced, in order.
final class FleetEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] { lock.withLock { lines } }

    var sink: @Sendable (EngineEvent) -> Void {
        { [self] event in
            let line: String?
            switch event {
            case .toolStarted(let id, _, _): line = "started \(id)"
            case .toolFinished(let id, _, let ok, _, _): line = "finished \(id)\(ok ? "" : " (failed)")"
            case .assistantMessage(let id, _, _): line = "assistant \(id)"
            case .finished: line = "finished run"
            default: line = nil
            }
            if let line { lock.withLock { lines.append(line) } }
        }
    }
}
