import XCTest
@testable import DSHCore

/// Against a real OpenAI-compatible server. Skipped unless DSH_LIVE_BASE_URL is set:
///   DSH_LIVE_BASE_URL=https://192.168.68.69:11443/v1 DSH_LIVE_KEY=vllm-local swift test --filter LiveServerTests
final class LiveServerTests: XCTestCase {
    private var profile: ProviderProfile!

    override func setUpWithError() throws {
        guard let base = ProcessInfo.processInfo.environment["DSH_LIVE_BASE_URL"] else {
            throw XCTSkip("set DSH_LIVE_BASE_URL to run live server tests")
        }
        profile = ProviderProfile(kind: .openAI, name: "live", baseURL: base,
                                  apiKey: ProcessInfo.processInfo.environment["DSH_LIVE_KEY"],
                                  model: "a-model-that-was-swapped-out")
        ReasoningEffortCache.shared.reset()
    }

    func testDetectsWindowAndFollowsTheServedModel() async throws {
        let probed = await OpenAIClient(profile: profile).modelInfo()
        let info = try XCTUnwrap(probed)
        XCTAssertFalse(info.servedModels.isEmpty)
        XCTAssertNotEqual(info.id, profile.model, "should follow the single served model")
        let window = try XCTUnwrap(info.contextWindow)
        XCTAssertGreaterThanOrEqual(window, 262_144, "window was \(window)")
        print("LIVE: model=\(info.id) window=\(window)")
    }

    private func run(_ thinking: ThinkingLevel, model: String) async throws -> (text: String, reasoning: Int) {
        var p = profile!
        p.model = model
        let req = LLMRequest(systemPrompt: "", messages: [.user("What is 17*23? Reply with the number only.")],
                             tools: [], model: model, maxTokens: 4000, thinking: thinking)
        var text = "", reasoning = 0
        for try await ev in OpenAIClient(profile: p).stream(req) {
            switch ev {
            case .text(let t): text += t
            case .reasoning(let r): reasoning += r.count
            case .done: break
            }
        }
        return (text, reasoning)
    }

    func testThinkingLevelsWorkIncludingHighRemap() async throws {
        let probed = await OpenAIClient(profile: profile).modelInfo()
        let model = try XCTUnwrap(probed).id
        let off = try await run(.off, model: model)
        XCTAssertTrue(off.text.contains("391"))
        XCTAssertEqual(off.reasoning, 0, "off must not think")
        let high = try await run(.high, model: model)   // Qwen3.8 rejects "high"; must auto-remap
        XCTAssertTrue(high.text.contains("391"))
        XCTAssertGreaterThan(high.reasoning, 0, "reasoning deltas should stream")
        print("LIVE: off reasoning=\(off.reasoning) high reasoning=\(high.reasoning) learned=\(ReasoningEffortCache.shared.accepted(route: "\(profile.baseURL)|\(model)", requested: "high") ?? "-")")
    }
}
