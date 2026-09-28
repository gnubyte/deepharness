import XCTest
@testable import DSHCore

final class CompactionTests: XCTestCase {

    // MARK: - Plans

    /// A transcript of user/assistant pairs; `n` turns, each ~2k estimated
    /// tokens (~8k chars of content).
    private func transcript(turns: Int) -> [LLMMessage] {
        var out: [LLMMessage] = []
        for i in 0..<turns {
            out.append(.user("Question \(i) " + String(repeating: "a", count: 4_000)))
            out.append(.assistant("Answer \(i) " + String(repeating: "b", count: 4_000)))
        }
        return out
    }

    func testNoPlanUnderTrigger() {
        let msgs = transcript(turns: 2)   // ~8k tokens
        let plan = Compaction.plan(usedTokens: 8_000, limit: 262_144, transcript: msgs)
        XCTAssertNil(plan, "well under 75% of the window — no compaction")
    }

    func testPlanSplitsAtUserBoundary() {
        let msgs = transcript(turns: 60)  // 120 messages, ~120k estimated tokens
        let limit = 100_000               // trigger ≈ 75k → over budget
        let used = TokenEstimate.request(systemPrompt: "system", messages: msgs)
        guard let plan = Compaction.plan(usedTokens: used, limit: limit, transcript: msgs) else {
            return XCTFail("expected a plan for a near-full transcript (used \(used))")
        }
        // Every kept tail must start with a user message…
        XCTAssertEqual(plan.toKeep.first?.role, .user)
        // …and nothing is lost or duplicated.
        XCTAssertEqual(plan.toSummarize.count + plan.toKeep.count, msgs.count)
        // The split keeps a meaningful recent tail (≥ 25% of the window, or the
        // minimum floor), i.e. not the entire history and not zero.
        XCTAssertGreaterThanOrEqual(TokenEstimate.request(systemPrompt: "", messages: plan.toKeep),
                                    Compaction.minKeepTokens - 1)
        XCTAssertGreaterThanOrEqual(plan.toSummarize.count, Compaction.minSummarizable)
        XCTAssertLessThan(plan.toKeep.count, msgs.count)
    }

    func testPlanNeverOrphansToolResults() {
        // The cut must land before the last user message so the assistant's
        // tool call stays paired with its result in the kept tail.
        let call = ToolCall(id: "c1", name: "read_file", arguments: "{\"path\":\"a\"}")
        let msgs: [LLMMessage] = [
            .user("one" + String(repeating: "a", count: 8_000)),
            .assistant("two" + String(repeating: "b", count: 8_000)),
            .user("three" + String(repeating: "c", count: 8_000)),
            .assistant("four" + String(repeating: "d", count: 8_000)),
            .user("five" + String(repeating: "e", count: 8_000)),
            .assistant("", calls: [call]),
            .toolResult(id: "c1", name: "read_file", output: "result"),
        ]
        let limit = 2_000 // tiny window → everything is over budget
        guard let plan = Compaction.plan(usedTokens: 10_000, limit: limit, transcript: msgs) else {
            return XCTFail("expected a plan")
        }
        // Keep must begin at a user boundary: at "five" (index 4) or later, so
        // the tool call + result are kept together with their turn.
        XCTAssertEqual(plan.toKeep.first?.role, .user)
        if let cut = msgs.firstIndex(of: plan.toKeep[0]) {
            XCTAssertGreaterThanOrEqual(cut, 4, "must not cut between the assistant tool call and its result")
        }
        XCTAssertEqual(plan.toSummarize.count + plan.toKeep.count, msgs.count)
    }

    func testNoPlanWhenNothingOldEnoughToSummarize() {
        // Only two messages: the split would leave < minSummarizable to fold.
        let msgs = transcript(turns: 1)
        let plan = Compaction.plan(usedTokens: 100_000, limit: 2_000, transcript: msgs)
        XCTAssertNil(plan)
    }

    func testPlanHonoursLargeLimit() {
        // 1M window (YaRN): the trigger is ~750k, and a 400k transcript is fine.
        let msgs = transcript(turns: 50)  // ~400k tokens
        let plan = Compaction.plan(usedTokens: TokenEstimate.request(systemPrompt: "", messages: msgs),
                                   limit: 1_048_576, transcript: msgs)
        XCTAssertNil(plan, "400k used of a 1M window should not compact yet")
    }

    // MARK: - Estimation

    func testEstimateMessage() {
        let m = LLMMessage(role: .user, content: String(repeating: "x", count: 4_000))
        XCTAssertEqual(TokenEstimate.message(m), 1_000)
    }

    func testEstimateCountsToolCallsAndAttachments() {
        let call = ToolCall(id: "c", name: "grep", arguments: String(repeating: "p", count: 400))
        let data = Data(repeating: 0, count: 4_000) // base64 ≈ 5,333 chars
        let m = LLMMessage(role: .assistant, content: nil, toolCalls: [call],
                           attachments: [MessageAttachment(kind: .file, name: "f", data: data)])
        let est = TokenEstimate.message(m)
        XCTAssertGreaterThan(est, (400 + 4_000 * 4 / 3) / 4)
    }

    func testEstimateRequestIncludesSystemPrompt() {
        let sys = String(repeating: "s", count: 4_000)
        let req = TokenEstimate.request(systemPrompt: sys, messages: [LLMMessage.user("hi")])
        XCTAssertEqual(req, 1_000)
    }

    // MARK: - Summary prompt

    func testSummaryPromptHasStructureAndClips() {
        let huge = String(repeating: "z", count: 100_000)
        let msgs = [LLMMessage.user(huge), .assistant("short")]
        let prompt = Compaction.summaryPrompt(for: msgs, budgetTokens: 2_000)
        for section in ["Task:", "Decisions:", "Work done:", "Open items:", "State:"] {
            XCTAssertTrue(prompt.contains(section), "missing section \(section)")
        }
        // The 100k-char message must have been clipped, not included whole.
        XCTAssertFalse(prompt.contains(huge))
        XCTAssertTrue(prompt.contains("…[truncated]"))
        XCTAssertTrue(prompt.contains("<conversation>"))
    }

    // MARK: - Overflow parsing (OpenAIClient helpers)

    func testOverflowLimitSGLangMessage() {
        let body = """
        {"error":{"message":"This model's maximum context length is 262144 tokens; however, you requested 270000 tokens (255898 in messages + 14102 in the completion). Please reduce the length of the messages or the completion.","type":"InvalidRequestError","code":"context_length_exceeded"}}
        """
        XCTAssertEqual(OpenAIClient.overflowLimit(in: body), 262_144)
    }

    func testOverflowLimitLLamaCppMessage() {
        let body = "The model's maximum context length is 131072 tokens"
        XCTAssertEqual(OpenAIClient.overflowLimit(in: body), 131_072)
    }

    func testOverflowLimitNone() {
        XCTAssertNil(OpenAIClient.overflowLimit(in: "Internal server error"))
    }

    func testContextWindowFieldVariants() {
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["context_len": 262_144]), 262_144)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["max_model_len": 1_048_576]), 1_048_576)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["max_total_tokens": 100_000]), 100_000)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["context": 32_768]), 32_768)
        XCTAssertNil(OpenAIClient.contextWindow(from: ["foo": 1]))
        XCTAssertNil(OpenAIClient.contextWindow(from: ["context_len": 0]))
    }

    func testStrippingV1() {
        XCTAssertEqual(OpenAIClient.strippingV1("http://192.168.1.10:8002/v1"), "http://192.168.1.10:8002")
        XCTAssertEqual(OpenAIClient.strippingV1("http://192.168.1.10:8002/v1/"), "http://192.168.1.10:8002")
        XCTAssertEqual(OpenAIClient.strippingV1("http://192.168.1.10:8002"), "http://192.168.1.10:8002")
        XCTAssertEqual(OpenAIClient.strippingV1("http://h:8002/somepath"), "http://h:8002/somepath")
    }

    func testFallbackKnowsSGLangModels() {
        // Qwen3 on the Spark is usually served with a 256K window in SGLang's
        // config, but the native base window is what the fallback table records.
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3-30b-a3b"), 32_768)
        XCTAssertEqual(FallbackContextWindow.limit(for: "glm-4.5"), 131_072)
        XCTAssertEqual(FallbackContextWindow.limit(for: "GLM-4.5-Air"), 131_072)
        // Unknown model → nil (the default is applied by the caller).
        XCTAssertNil(FallbackContextWindow.limit(for: "totally-unknown-model"))
    }

    // MARK: - Engine integration (in-loop compaction)

    private func testRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-compact-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// When the request is over budget, the engine must hand the model the
    /// compacted transcript, not the full one.
    func testInLoopCompactionShrinksRequest() async throws {
        var history: [LLMMessage] = []
        for i in 0..<10 {
            history.append(.user("q\(i) " + String(repeating: "a", count: 4_000)))
            history.append(.assistant("r\(i) " + String(repeating: "b", count: 4_000)))
        }
        // Fold everything but the last two messages into a summary.
        let compacted: @Sendable (Int, [LLMMessage]) async throws -> [LLMMessage] = { _, msgs in
            [.system("SUMMARY")] + Array(msgs.suffix(2))
        }
        let client = ScriptedClient(turns: [.init(text: "final")])
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(client: client,
                            registry: ToolRegistry(tools: [EchoTool()]),
                            systemPrompt: "system",
                            config: .init(maxIterations: 3, toolTimeout: 5, model: "test",
                                          contextWindow: 8_000),   // trigger ≈ 6k; request is ~20k
                            workspace: root,
                            policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                            permissionGate: { _, _, _ in true },
                            compaction: compacted)
        let result = try await engine.run(messages: history, userText: "next", sink: { _ in })

        let sent = client.requests.last?.messages ?? []
        XCTAssertEqual(client.requests.count, 1, "compaction must happen before the one model call")
        XCTAssertEqual(sent.count, 3, "summed transcript + kept tail, not the full 21")
        XCTAssertEqual(sent.first?.content, "SUMMARY")
        XCTAssertEqual(result.finalText, "final")
    }

    /// When the server rejects a request as too long, the engine must compact and
    /// retry once rather than surfacing the error.
    func testOverflowTriggersCompactionAndRetry() async throws {
        final class OverflowOnce: LLMClient, @unchecked Sendable {
            private let lock = NSLock()
            private var threw = false
            private(set) var requests: [LLMRequest] = []
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
                lock.lock()
                requests.append(request)
                let first = !threw
                threw = true
                lock.unlock()
                return AsyncThrowingStream { continuation in
                    if first {
                        continuation.finish(throwing: LLMError.overflow(limit: 5_000, detail: "too long"))
                    } else {
                        continuation.yield(.text("ok"))
                        continuation.yield(.done(calls: [], finish: "stop", usage: nil))
                        continuation.finish()
                    }
                }
            }
            func listModels() async throws -> [String] { ["x"] }
        }

        var history: [LLMMessage] = []
        for i in 0..<8 {
            history.append(.user("q\(i) " + String(repeating: "a", count: 4_000)))
            history.append(.assistant("r\(i) " + String(repeating: "b", count: 4_000)))
        }
        let compacted: @Sendable (Int, [LLMMessage]) async throws -> [LLMMessage] = { _, msgs in
            [.system("SUMMARY")] + Array(msgs.suffix(2))
        }
        let client = OverflowOnce()
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(client: client,
                            registry: ToolRegistry(tools: [EchoTool()]),
                            systemPrompt: "system",
                            config: .init(maxIterations: 3, toolTimeout: 5, model: "test",
                                          contextWindow: 100_000), // big: the estimate won't trigger; the overflow will
                            workspace: root,
                            policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                            permissionGate: { _, _, _ in true },
                            compaction: compacted)
        let result = try await engine.run(messages: history, userText: "go", sink: { _ in })

        XCTAssertEqual(result.finalText, "ok", "the retry after compaction must succeed")
        XCTAssertEqual(client.requests.count, 2)
        let before = client.requests[0].messages.count
        let after = client.requests[1].messages.count
        XCTAssertLessThan(after, before, "the retried request must be the compacted, smaller transcript")
    }

    /// Compaction is capped so a pathological transcript can't loop forever.
    func testCompactionIsCapped() async throws {
        // A hook that always shrinks to one summary but never actually reduces
        // below the trigger (returns a transcript still over budget) — the cap
        // must stop the engine compacting beyond maxCompactions.
        final class AlwaysOverflow: LLMClient, @unchecked Sendable {
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: LLMError.overflow(limit: 10, detail: "no"))
                }
            }
            func listModels() async throws -> [String] { ["x"] }
        }
        let history: [LLMMessage] = [
            .user("q " + String(repeating: "a", count: 4_000)),
            .assistant("r " + String(repeating: "b", count: 4_000)),
        ]
        let compacted: @Sendable (Int, [LLMMessage]) async throws -> [LLMMessage] = { _, _ in
            [.system("S"), .user("x " + String(repeating: "a", count: 4_000))]
        }
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(client: AlwaysOverflow(),
                            registry: ToolRegistry(tools: [EchoTool()]),
                            systemPrompt: "system",
                            config: .init(maxIterations: 3, toolTimeout: 5, model: "test",
                                          contextWindow: 10, maxCompactions: 1),
                            workspace: root,
                            policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                            permissionGate: { _, _, _ in true },
                            compaction: compacted)
        do {
            _ = try await engine.run(messages: history, userText: "go", sink: { _ in })
            XCTFail("expected the overflow to propagate once compaction is exhausted")
        } catch let e as LLMError {
            if case .overflow = e { } else { XCTFail("wrong error \(e)") }
        }
    }
}
