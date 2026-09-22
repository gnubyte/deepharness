import XCTest
@testable import DSHCore

final class ContextWindowTests: XCTestCase {
    func testExactOllamaTags() {
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3:8b"), 32_768)
        XCTAssertEqual(FallbackContextWindow.limit(for: "llama3.1:70b"), 131_072)
    }

    func testVendorPrefixesStripDown() {
        // "meta-llama/Llama-3.3-70B-Instruct" → base "Llama-3.3-70B-Instruct"
        // → lowercased → prefix "llama-3.3-" → 128k.
        XCTAssertEqual(FallbackContextWindow.limit(for: "meta-llama/Llama-3.3-70B-Instruct"), 131_072)
        XCTAssertEqual(FallbackContextWindow.limit(for: "openai/gpt-4o"), 128_000)
        XCTAssertEqual(FallbackContextWindow.limit(for: "gpt-4o-mini"), 128_000)
    }

    func testUnknownModelReturnsNil() {
        XCTAssertNil(FallbackContextWindow.limit(for: "my-custom-fine-tune-xyz"))
    }

    func testOllamaTagStrippedForPrefixMatch() {
        // "deepseek-r1:32b" is in the exact table; "deepseek-r1:14b" too.
        XCTAssertEqual(FallbackContextWindow.limit(for: "deepseek-r1:32b"), 65_536)
        // A tag not in the exact table should still match the family prefix.
        XCTAssertEqual(FallbackContextWindow.limit(for: "qwen3:60b"), 32_768)
    }

    func testMatchesModelToleratesVendorAndTags() {
        XCTAssertTrue(OpenAIClient.matchesModel("qwen3:8b", "qwen3:8b"))
        XCTAssertTrue(OpenAIClient.matchesModel("meta-llama/Llama-3.3-70B-Instruct",
                                                "Llama-3.3-70B-Instruct"))
        XCTAssertTrue(OpenAIClient.matchesModel("Llama-3.3-70B-Instruct",
                                                "meta-llama/Llama-3.3-70B-Instruct"))
        XCTAssertFalse(OpenAIClient.matchesModel("gpt-4o", "gpt-4o-mini"))
    }

    func testContextWindowFieldExtraction() {
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["context": 131072]), 131_072)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["context_length": 32768]), 32_768)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["max_context_length": 128000]), 128_000)
        XCTAssertEqual(OpenAIClient.contextWindow(from: ["context_window": 200000]), 200_000)
        XCTAssertNil(OpenAIClient.contextWindow(from: ["id": "gpt-4o"]))
        // Zero / negative should be ignored, so a bogus 0 doesn't win.
        XCTAssertNil(OpenAIClient.contextWindow(from: ["context": 0]))
    }
}
