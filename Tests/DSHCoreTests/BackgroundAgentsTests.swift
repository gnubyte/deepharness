import XCTest
@testable import DSHCore

/// Answers main-agent and subagent requests from separate scripts (a
/// subagent's system prompt starts "You are a focused subagent").
final class RoleScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var main: [ScriptedClient.Turn]
    private let sub: @Sendable (String) -> String
    private(set) var mainRequests: [LLMRequest] = []

    init(main: [ScriptedClient.Turn], sub: @escaping @Sendable (String) -> String) {
        self.main = main
        self.sub = sub
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let isSub = request.systemPrompt.hasPrefix("You are a focused subagent")
        let turn: ScriptedClient.Turn = lock.withLock {
            if isSub {
                let task = request.messages.first(where: { $0.role == .user })?.content ?? ""
                return .init(text: sub(task))
            }
            mainRequests.append(request)
            return main.isEmpty ? .init(text: "done") : main.removeFirst()
        }
        return AsyncThrowingStream { c in
            for ch in turn.text.map(String.init) { c.yield(.text(ch)) }
            c.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
            c.finish()
        }
    }
    func listModels() async throws -> [String] { [] }
}

final class BackgroundAgentsTests: XCTestCase {

    func testPoolLifecycle() async {
        let pool = BackgroundAgents(maxConcurrent: 2)
        let changes = SeenArgs()
        pool.onChange = { changes.append("\($0.id):\($0.status.rawValue)") }
        guard case .success(let fast) = pool.launch(description: "fast", work: { (true, "fast report") }) else {
            return XCTFail("launch failed")
        }
        guard case .success(let slow) = pool.launch(description: "slow", work: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return (true, "slow report")
        }) else { return XCTFail("launch failed") }
        let finished = await pool.wait(fast.id, timeout: 5)
        XCTAssertEqual(finished?.status, .done)
        XCTAssertEqual(finished?.report, "fast report")
        // Only two at once.
        guard case .success(let third) = pool.launch(description: "third", work: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return (true, "")
        }) else {
            return XCTFail("a slot freed up when fast finished")
        }
        if case .success = pool.launch(description: "fourth", work: { try? await Task.sleep(nanoseconds: 5_000_000_000); return (true, "") }) {
            XCTFail("over the limit")
        }
        // Waiting on a running job times out quickly.
        let stillRunning = await pool.wait(slow.id, timeout: 0.2)
        XCTAssertEqual(stillRunning?.status, .running)
        XCTAssertTrue(pool.stop(slow.id))
        pool.stop(third.id)
        XCTAssertEqual(pool.job(slow.id)?.status, .stopped)
        // Finished (not stopped) jobs are reported once.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let unreported = pool.takeUnreported().map(\.id)
        XCTAssertTrue(unreported.contains(fast.id))
        XCTAssertFalse(unreported.contains(slow.id))
        XCTAssertTrue(pool.takeUnreported().isEmpty)
        XCTAssertTrue(changes.all.contains("\(fast.id):done"))
        XCTAssertTrue(BackgroundAgents.notice(for: [finished!]).contains("fast report"))
    }

    private func engine(_ client: any LLMClient, pool: BackgroundAgents) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let registry = ToolRegistry(tools: [AgentTool(), EchoTool()] + ToolRegistry.backgroundAgentTools())
        return Engine(client: client, registry: registry, systemPrompt: "main", config: .init(maxIterations: 8, model: "m"),
                      workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                      permissionGate: { _, _, _ in true }, backgroundAgents: pool)
    }

    func testLaunchInBackgroundThenCollectTheReport() async throws {
        let launch = ToolCall(id: "1", name: "agent",
                              arguments: #"{"description":"scan","prompt":"find TODOs","run_in_background":true}"#)
        let status = ToolCall(id: "2", name: "agent_status", arguments: #"{"id":"bg-1","wait_seconds":10}"#)
        let client = RoleScriptedClient(main: [.init(calls: [launch]), .init(calls: [status]), .init(text: "All collected.")],
                                        sub: { task in "found 3 TODOs for: \(task)" })
        let pool = BackgroundAgents()
        let result = try await engine(client, pool: pool).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.finalText, "All collected.")
        let toolResults = result.messages.filter { $0.role == .tool }.compactMap(\.content)
        XCTAssertTrue(toolResults[0].hasPrefix("Started background agent bg-1"), toolResults[0])
        XCTAssertTrue(toolResults[1].contains("found 3 TODOs for: find TODOs"), toolResults[1])
        XCTAssertEqual(pool.job("bg-1")?.status, .done)
        // Read via agent_status: not announced again.
        XCTAssertTrue(pool.takeUnreported().isEmpty)
    }

    func testFinishedAgentsAreAnnouncedAutomatically() async throws {
        let pool = BackgroundAgents()
        _ = pool.launch(description: "tests", work: { (true, "12 tests pass") })
        _ = await pool.wait("bg-1", timeout: 5)
        let client = RoleScriptedClient(main: [.init(text: "noted")], sub: { _ in "" })
        _ = try await engine(client, pool: pool).run(messages: [], userText: "what's up?", sink: { _ in })
        let sent = client.mainRequests.first?.messages.last?.content ?? ""
        XCTAssertTrue(sent.hasPrefix("what's up?"))
        XCTAssertTrue(sent.contains("[Automatic message: a background agent finished"))
        XCTAssertTrue(sent.contains("12 tests pass"))
    }

    func testBackgroundNeedsAPoolAndSubagentsCantNest() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let out = await AgentTool().execute(args: #"{"description":"x","prompt":"y","run_in_background":true}"#, in: ctx).output
        XCTAssertTrue(out.hasPrefix("Error: background subagents aren't available"))
        let status = await AgentStatusTool().execute(args: "{}", in: ctx).output
        XCTAssertTrue(status.hasPrefix("Error"))
    }

    func testQueueTaskToolPassesItsArguments() async {
        let seen = SeenArgs()
        let tool = QueueAddTool(add: { title, details, front, start in
            seen.append("\(title)|\(details)|\(front)|\(start)")
            return "queued"
        })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let out = await tool.execute(args: #"{"title":" Write tests ","details":"for the parser","start":true}"#, in: ctx).output
        XCTAssertEqual(out, "queued")
        XCTAssertEqual(seen.all, ["Write tests|for the parser|false|true"])
        let missing = await tool.execute(args: #"{"details":"x"}"#, in: ctx).output
        XCTAssertTrue(missing.hasPrefix("Error"))
    }
}
