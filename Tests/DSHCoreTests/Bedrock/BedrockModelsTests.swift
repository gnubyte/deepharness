import XCTest
@testable import DSHCore

/// The per-model table: which ids are Bedrock ids, the context window the gauge shows, and the request
/// shape (thinking style, sampling, caching, output ceiling) of each family and Claude generation.
final class BedrockModelsTests: XCTestCase {

    // MARK: Ids

    func testBaseIDDropsRegionPrefixesAndArnsAndLowerCases() {
        let cases: [(String, String?)] = [
            ("anthropic.claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-sonnet-4-5-20250929-v1:0"),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-sonnet-4-5-20250929-v1:0"),
            ("eu.anthropic.claude-3-haiku-20240307-v1:0", "anthropic.claude-3-haiku-20240307-v1:0"),
            ("apac.amazon.nova-lite-v1:0", "amazon.nova-lite-v1:0"),
            ("us-gov.anthropic.claude-3-haiku-20240307-v1:0", "anthropic.claude-3-haiku-20240307-v1:0"),
            ("global.anthropic.claude-opus-4-6-v1", "anthropic.claude-opus-4-6-v1"),
            ("  US.Anthropic.Claude-3-Haiku-20240307-V1:0 \n", "anthropic.claude-3-haiku-20240307-v1:0"),
            ("arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.claude-opus-4-1-20250805-v1:0",
             "anthropic.claude-opus-4-1-20250805-v1:0"),
            ("arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
             "anthropic.claude-3-haiku-20240307-v1:0"),
            ("meta.llama3-3-70b-instruct-v1:0", "meta.llama3-3-70b-instruct-v1:0"),
            ("us.deepseek.r1-v1:0", "deepseek.r1-v1:0"),
            ("moonshotai.kimi-k2", "moonshotai.kimi-k2"),
            // Not Bedrock ids.
            ("claude-sonnet-4-5", nil),
            ("gpt-4o", nil),
            ("qwen3:8b", nil),
            ("unknownvendor.model-v1", nil),
            ("eu.unknownvendor.model-v1", nil),
            ("us.nova", nil),
            (".anthropic.x", nil),
            ("arn:aws:bedrock:us-east-1:1:application-inference-profile/abc123", nil),
            ("", nil),
        ]
        for (id, base) in cases {
            XCTAssertEqual(BedrockModels.baseID(id), base, id)
        }
    }

    func testContextWindowsForTheGauge() {
        let cases: [(String, Int?)] = [
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", 200_000),
            ("arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.claude-opus-4-1-20250805-v1:0", 200_000),
            ("global.anthropic.claude-opus-4-6-v1", 1_000_000),
            ("anthropic.claude-haiku-4-5-20251001-v1:0", 200_000),
            ("anthropic.claude-3-haiku-20240307-v1:0", 200_000),
            ("amazon.nova-pro-v1:0", 300_000),
            ("us.amazon.nova-lite-v1:0", 300_000),
            ("amazon.nova-micro-v1:0", 128_000),
            ("amazon.nova-premier-v1:0", 1_000_000),
            ("meta.llama3-3-70b-instruct-v1:0", 128_000),
            ("mistral.mistral-large-2402-v1:0", 32_000),
            ("mistral.mistral-large-2407-v1:0", 128_000),
            ("mistral.pixtral-large-2502-v1:0", 128_000),
            ("mistral.mistral-7b-instruct-v0:2", 32_000),
            ("us.deepseek.r1-v1:0", 128_000),
            ("openai.gpt-oss-120b-1:0", 128_000),
            ("qwen.qwen3-32b-v1:0", 128_000),
            // A Bedrock id we have no window for, and ids that are not Bedrock's at all.
            ("cohere.command-r-v1:0", nil),
            ("claude-sonnet-4-5", nil),
            ("gpt-4o", nil),
            ("arn:aws:bedrock:us-east-1:1:application-inference-profile/abc123", nil),
        ]
        for (id, window) in cases {
            XCTAssertEqual(BedrockModels.contextWindow(id), window, id)
        }
    }

    // MARK: Claude generations

    private func claude(_ id: String) -> BedrockModelTraits {
        let traits = BedrockModels.traits(id)
        XCTAssertTrue(traits.isClaude, id)
        return traits
    }

    func testClaude3HasNoThinkingAndSmallOutput() {
        let haiku3 = claude("anthropic.claude-3-haiku-20240307-v1:0")
        XCTAssertEqual(haiku3.thinking, ClaudeThinking.none)
        XCTAssertFalse(haiku3.cachePoints)
        XCTAssertFalse(haiku3.toolCachePoint)
        XCTAssertEqual(haiku3.defaultMaxTokens, 4096)
        XCTAssertEqual(haiku3.maxTokensCeiling, 4096)
        XCTAssertTrue(haiku3.documents)
        XCTAssertTrue(haiku3.toolResultStatus)

        let sonnet3 = claude("anthropic.claude-3-sonnet-20240229-v1:0")
        XCTAssertEqual(sonnet3.maxTokensCeiling, 4096)
        let opus3 = claude("anthropic.claude-3-opus-20240229-v1:0")
        XCTAssertEqual(opus3.maxTokensCeiling, 4096)
    }

    func testClaude35CachesOnlyFromHaikuAndOutputsEightK() {
        let haiku = claude("us.anthropic.claude-3-5-haiku-20241022-v1:0")
        XCTAssertTrue(haiku.cachePoints, "prompt caching starts with 3.5 Haiku")
        XCTAssertTrue(haiku.toolCachePoint)
        XCTAssertEqual(haiku.defaultMaxTokens, 8192)
        XCTAssertEqual(haiku.maxTokensCeiling, 8192)
        XCTAssertEqual(haiku.thinking, ClaudeThinking.none)

        let sonnet = claude("anthropic.claude-3-5-sonnet-20241022-v2:0")
        XCTAssertFalse(sonnet.cachePoints, "…but 3.5 Sonnet has none")
        XCTAssertEqual(sonnet.maxTokensCeiling, 8192)
    }

    func testClaude37ThroughClaude45ThinkWithABudget() {
        let cases: [(String, Int)] = [
            ("anthropic.claude-3-7-sonnet-20250219-v1:0", 64_000),
            ("us.anthropic.claude-sonnet-4-20250514-v1:0", 64_000),
            ("anthropic.claude-opus-4-20250514-v1:0", 32_000),
            ("anthropic.claude-opus-4-1-20250805-v1:0", 32_000),
            ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", 64_000),
            ("anthropic.claude-haiku-4-5-20251001-v1:0", 64_000),
            ("anthropic.claude-opus-4-5-20251101-v1:0", 64_000),
        ]
        for (id, ceiling) in cases {
            let traits = claude(id)
            XCTAssertEqual(traits.thinking, .budget, id)
            XCTAssertEqual(traits.maxTokensCeiling, ceiling, id)
            XCTAssertEqual(traits.defaultMaxTokens, 16_000, id)
            XCTAssertEqual(traits.contextWindow, 200_000, id)
            XCTAssertTrue(traits.cachePoints, id)
            XCTAssertTrue(traits.toolCachePoint, id)
            XCTAssertTrue(traits.sampling, id)
            XCTAssertFalse(traits.summarizedThinking, id)
        }
    }

    func testTheDateAfterAMajorVersionIsNotAMinorVersion() {
        // "claude-sonnet-4-20250514" is 4.0; "claude-sonnet-4-5-20250929" is 4.5.
        XCTAssertEqual(claude("anthropic.claude-opus-4-20250514-v1:0").maxTokensCeiling, 32_000, "Opus 4.0 stops at 32K")
        XCTAssertEqual(claude("anthropic.claude-opus-4-5-20251101-v1:0").maxTokensCeiling, 64_000, "Opus 4.5 does not")
    }

    func testClaude46To48ThinkAdaptivelyAndOmitTheFieldToTurnItOff() {
        let opus46 = claude("global.anthropic.claude-opus-4-6-v1")
        XCTAssertEqual(opus46.thinking, .adaptive)
        XCTAssertEqual(opus46.off, .omit)
        XCTAssertTrue(opus46.sampling)
        XCTAssertFalse(opus46.summarizedThinking)
        XCTAssertEqual(opus46.contextWindow, 1_000_000)
        XCTAssertEqual(opus46.maxTokensCeiling, 128_000)
        XCTAssertEqual(opus46.defaultMaxTokens, 16_000)

        for id in ["us.anthropic.claude-opus-4-7", "anthropic.claude-sonnet-4-8"] {
            let traits = claude(id)
            XCTAssertEqual(traits.thinking, .adaptive, id)
            XCTAssertEqual(traits.off, .omit, id)
            XCTAssertFalse(traits.sampling, "4.7 and later reject temperature: \(id)")
            XCTAssertTrue(traits.summarizedThinking, id)
        }
    }

    func testClaude5HasAModelSpecificWayToSwitchThinkingOff() {
        XCTAssertEqual(claude("anthropic.claude-opus-5").off, .disabled)
        XCTAssertEqual(claude("anthropic.claude-sonnet-5").off, .disabled)
        XCTAssertEqual(claude("anthropic.claude-sonnet-5-5").off, .betweenTools)
        XCTAssertEqual(claude("us.anthropic.claude-opus-5-5").off, .lowEffort)
        XCTAssertEqual(claude("anthropic.claude-haiku-5").off, .lowEffort)
        XCTAssertEqual(claude("anthropic.claude-fable-5").off, .lowEffort)
        XCTAssertEqual(claude("anthropic.claude-mythos-5-5").off, .lowEffort)
        for id in ["anthropic.claude-opus-5", "anthropic.claude-sonnet-5-5", "us.anthropic.claude-opus-5-5"] {
            XCTAssertFalse(claude(id).sampling, id)
            XCTAssertTrue(claude(id).summarizedThinking, id)
        }
    }

    func testAClaudeWeCannotPlaceIsTreatedAsTheNewestGeneration() {
        let unknown = claude("anthropic.claude-something-new-v1:0")
        XCTAssertEqual(unknown.thinking, .adaptive)
        XCTAssertEqual(unknown.off, .lowEffort)
        XCTAssertEqual(unknown.contextWindow, 1_000_000)
    }

    func testTheOldTextClaudesHaveNoThinkingOrCaching() {
        for id in ["anthropic.claude-v2:1", "anthropic.claude-instant-v1"] {
            let traits = claude(id)
            XCTAssertEqual(traits.thinking, ClaudeThinking.none, id)
            XCTAssertFalse(traits.cachePoints, id)
            XCTAssertEqual(traits.maxTokensCeiling, 4096, id)
        }
    }

    // MARK: Other families

    func testNovaCachesAndTakesDocumentsButNotToolCaching() {
        for (id, window) in [("amazon.nova-micro-v1:0", 128_000), ("amazon.nova-lite-v1:0", 300_000),
                             ("us.amazon.nova-pro-v1:0", 300_000), ("amazon.nova-premier-v1:0", 1_000_000)] {
            let traits = BedrockModels.traits(id)
            XCTAssertFalse(traits.isClaude, id)
            XCTAssertEqual(traits.contextWindow, window, id)
            XCTAssertTrue(traits.cachePoints, id)
            XCTAssertFalse(traits.toolCachePoint, id)
            XCTAssertTrue(traits.toolResultStatus, id)
            XCTAssertTrue(traits.documents, id)
            XCTAssertEqual(traits.thinking, ClaudeThinking.none, id)
            XCTAssertEqual(traits.defaultMaxTokens, 4096, id)
            XCTAssertNil(traits.maxTokensCeiling, id)
        }
    }

    func testOtherFamiliesGetConservativeDefaultsAndTheirOwnOutputDefaults() {
        let llama = BedrockModels.traits("meta.llama3-3-70b-instruct-v1:0")
        XCTAssertEqual(llama.defaultMaxTokens, 2048)
        XCTAssertFalse(llama.cachePoints)
        XCTAssertFalse(llama.toolResultStatus)
        XCTAssertFalse(llama.documents)
        XCTAssertTrue(llama.sampling)

        XCTAssertEqual(BedrockModels.traits("us.deepseek.r1-v1:0").defaultMaxTokens, 16_384)
        XCTAssertEqual(BedrockModels.traits("deepseek.v3-v1:0").defaultMaxTokens, 8192)
        XCTAssertEqual(BedrockModels.traits("openai.gpt-oss-120b-1:0").defaultMaxTokens, 8192)
        XCTAssertEqual(BedrockModels.traits("qwen.qwen3-32b-v1:0").defaultMaxTokens, 8192)
        XCTAssertEqual(BedrockModels.traits("mistral.mistral-large-2407-v1:0").defaultMaxTokens, 4096)
        XCTAssertEqual(BedrockModels.traits("cohere.command-r-v1:0").defaultMaxTokens, 4096)
    }

    func testAnIdWithNoModelInItGetsTheConservativeDefaults() {
        let application = BedrockModels.traits("arn:aws:bedrock:us-east-1:1:application-inference-profile/abc123")
        XCTAssertEqual(application, BedrockModelTraits())
        XCTAssertFalse(application.isClaude)
        XCTAssertNil(application.contextWindow)
        XCTAssertNil(application.maxTokensCeiling)
        XCTAssertEqual(application.defaultMaxTokens, 4096)
    }

    func testAnAnthropicStyleClaudeNameStillGetsClaudeTraits() {
        // Not a Bedrock id (no window for the gauge), but the request shaping still recognises Claude.
        XCTAssertNil(BedrockModels.contextWindow("claude-sonnet-4-5"))
        XCTAssertEqual(BedrockModels.traits("claude-sonnet-4-5").thinking, .budget)
    }
}
