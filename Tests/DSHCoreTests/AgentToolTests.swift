import XCTest
@testable import DSHCore

final class AgentToolTests: XCTestCase {

    private func testRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-agenttool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Compaction.plan: the assistant-boundary escape hatch

    /// One user message, then many assistant(+tool call)/tool-result rounds —
    /// exactly the shape of a subagent's entire run (it never gets a second
    /// `.user` message).
    private func toolMarathon(rounds: Int) -> [LLMMessage] {
        var out: [LLMMessage] = [.user("start " + String(repeating: "a", count: 4_000))]
        for i in 0..<rounds {
            let call = ToolCall(id: "c\(i)", name: "read_file", arguments: "{\"path\":\"f\(i)\"}")
            out.append(.assistant("round \(i) " + String(repeating: "b", count: 4_000), calls: [call]))
            out.append(.toolResult(id: "c\(i)", name: "read_file", output: "result \(i)"))
        }
        return out
    }

    func testPlanWithoutFlagFallsBackToAssistantBoundaryForASingleTurnToolMarathon() {
        // With only one `.user` message in the whole transcript the user-only
        // rule has no boundary to cut at; rather than run into the server's
        // hard limit, the plan falls back to an assistant boundary.
        let msgs = toolMarathon(rounds: 20)
        let used = TokenEstimate.request(systemPrompt: "", messages: msgs)
        let plan = Compaction.plan(usedTokens: used, limit: 8_000, transcript: msgs)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.toKeep.first?.role, .assistant)
    }

    func testPlanWithAssistantBoundaryCompactsASingleTurnToolMarathon() {
        let msgs = toolMarathon(rounds: 20)
        let used = TokenEstimate.request(systemPrompt: "", messages: msgs)
        guard let plan = Compaction.plan(usedTokens: used, limit: 8_000, transcript: msgs,
                                         allowAssistantBoundary: true) else {
            return XCTFail("expected a plan once assistant boundaries are allowed")
        }
        // The kept tail must start at a complete round: the assistant's call
        // together with its own result, never split from it.
        XCTAssertEqual(plan.toKeep.first?.role, .assistant)
        guard let call = plan.toKeep.first?.toolCalls?.first else {
            return XCTFail("expected the boundary assistant message to carry its tool call")
        }
        XCTAssertEqual(plan.toKeep.dropFirst().first?.toolCallID, call.id,
                       "the kept assistant's own tool result must follow it, never left behind")
        XCTAssertEqual(plan.toSummarize.count + plan.toKeep.count, msgs.count)
        XCTAssertGreaterThanOrEqual(plan.toSummarize.count, Compaction.minSummarizable)
    }

    // MARK: - Compaction.summarize (generic over any LLMClient)

    func testCompactionSummarizeReturnsTrimmedModelText() async throws {
        let client = ScriptedClient(turns: [.init(text: "  a continuity note  ")])
        let plan = Compaction.Plan(toSummarize: [.user("old"), .assistant("a"), .user("more"), .assistant("b")],
                                   toKeep: [.user("recent")], usedTokens: 1_000, limit: 10_000)
        let summary = await Compaction.summarize(client: client, plan: plan)
        XCTAssertEqual(summary, "a continuity note")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.requests[0].tools.isEmpty)
        XCTAssertEqual(client.requests[0].thinking, .off, "summaries are written with thinking off")
    }

    func testCompactionSummarizeReturnsNilOnClientFailure() async throws {
        final class ThrowingClient: LLMClient, @unchecked Sendable {
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: LLMError.sse("boom"))
                }
            }
            func listModels() async throws -> [String] { [] }
        }
        let plan = Compaction.Plan(toSummarize: [.user("old"), .assistant("a"), .user("more"), .assistant("b")],
                                   toKeep: [.user("recent")], usedTokens: 1_000, limit: 10_000)
        let summary = await Compaction.summarize(client: ThrowingClient(), plan: plan)
        XCTAssertNil(summary)
    }

    // MARK: - Engine → ToolContext wiring

    /// Records the `ToolContext` it was handed, so a test can inspect what
    /// the engine threaded through to a tool (and, transitively, to any
    /// subagent that tool spawns).
    private final class CapturingTool: ToolExecutor, @unchecked Sendable {
        static let name = "capture"
        static let spec = ToolSpec(name: name, description: "capture", parameters: "{}")
        private(set) var captured: ToolContext?
        func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
            captured = context
            return ToolResult(output: "ok")
        }
    }

    func testToolContextCarriesTheEnginesContextWindow() async throws {
        let call = ToolCall(id: "c1", name: "capture", arguments: "{}")
        let client = ScriptedClient(turns: [
            .init(text: "checking", calls: [call]),
            .init(text: "done"),
        ])
        let tool = CapturingTool()
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(client: client,
                            registry: ToolRegistry(tools: [tool]),
                            systemPrompt: "system",
                            config: .init(model: "test", contextWindow: 12_345),
                            workspace: root,
                            policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                            permissionGate: { _, _, _ in true })
        _ = try await engine.run(messages: [], userText: "go", sink: { _ in })

        XCTAssertEqual(tool.captured?.contextWindow, 12_345,
                       "a tool (and any subagent it spawns) must see the engine's resolved window")
    }

    // MARK: - AgentTool: subagents actually auto-compact

    /// Serves both a subagent's ordinary turns and its internal
    /// summarization calls from one client (as a real `OpenAIClient` would),
    /// distinguishing them by shape (a summarization request has no tools,
    /// thinking off, and exactly one user message) rather than by
    /// call order.
    private final class SubagentClient: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [ScriptedClient.Turn]
        private(set) var requests: [LLMRequest] = []
        init(turns: [ScriptedClient.Turn]) { self.turns = turns }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            lock.lock()
            requests.append(request)
            let isSummaryRequest = request.tools.isEmpty && request.thinking == .off
                && request.messages.count == 1 && request.messages[0].role == .user
            let turn: ScriptedClient.Turn
            if isSummaryRequest {
                turn = .init(text: "SUMMARY")
            } else {
                turn = turns.isEmpty ? .init(text: "done") : turns.removeFirst()
            }
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for chunk in turn.text.map(String.init) { continuation.yield(.text(chunk)) }
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: turn.usage))
                continuation.finish()
            }
        }
        func listModels() async throws -> [String] { ["x"] }
    }

    func testAgentToolAutoCompactsALongSubagentRun() async throws {
        // Each round: a large assistant text + a todo_write call, so the
        // subagent's own transcript grows across its internal iterations
        // exactly like the top-level session's does — but a subagent never
        // gets a second `.user` message (see the Compaction.plan tests
        // above), which used to mean it could never compact at all.
        let bigText = String(repeating: "a", count: 4_000)
        var turns: [ScriptedClient.Turn] = []
        for i in 0..<12 {
            let call = ToolCall(id: "t\(i)", name: "todo_write", arguments: #"{"todos":[]}"#)
            turns.append(.init(text: bigText, calls: [call]))
        }
        turns.append(.init(text: "final report"))
        let client = SubagentClient(turns: turns)

        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(workspace: root,
                                  policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                                  client: client, registry: ToolRegistry.standard(),
                                  depth: 0, model: "test", contextWindow: 8_000,
                                  requestPermission: { _, _, _ in true })

        let result = await AgentTool().execute(
            args: #"{"description":"scan","prompt":"go look at things"}"#,
            in: context)

        XCTAssertTrue(result.output.contains("final report"),
                      "the subagent must finish despite a tiny window: \(result.output)")

        // Real turns always carry the tool specs; the interleaved
        // summarization calls never do, so filtering isolates them.
        let mainRequestSizes = client.requests.filter { !$0.tools.isEmpty }.map { $0.messages.count }
        let shrank = zip(mainRequestSizes, mainRequestSizes.dropFirst()).contains { prev, next in next < prev }
        XCTAssertTrue(shrank, "expected at least one request to shrink after compaction fired; sizes=\(mainRequestSizes)")
    }
}
