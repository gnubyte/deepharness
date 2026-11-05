import XCTest
@testable import VisionHarnessCore

final class OpenAIClientTests: XCTestCase {

    private func client() -> OpenAIClient {
        OpenAIClient(profile: .init(kind: .openAICompat, name: "test",
                                    baseURL: "http://127.0.0.1:8000/v1", model: "test-model"))
    }

    private func wireMessages(_ request: LLMRequest) throws -> [[String: Any]] {
        let data = try client().makeBody(request)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return obj["messages"] as! [[String: Any]]
    }

    func testSystemPromptIsTheOnlySystemMessage() throws {
        let request = LLMRequest(systemPrompt: "You are a helpful agent.",
                                 messages: [.user("hi")], tools: [], model: "test-model")
        let messages = try wireMessages(request)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are a helpful agent.")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    /// Regression: compaction inserts a `.system`-role continuity note mid-transcript
    /// (see `AppTransport.compactTranscript` / `AgentTool`). A second system message
    /// anywhere but index 0 makes strict OpenAI-compatible servers (e.g. SGLang on a
    /// DGX Spark) reply 400 "System message must be at the beginning." Both the
    /// engine's own system prompt and any inline `.system` transcript messages must
    /// collapse into exactly one leading system message on the wire.
    func testCompactedSystemNoteMergesIntoLeadingSystemMessage() throws {
        let request = LLMRequest(
            systemPrompt: "You are a helpful agent.",
            messages: [
                .system(Compaction.summaryHeader + "Earlier work: did X, Y, Z."),
                .user("keep going"),
                .assistant("sure", calls: []),
            ],
            tools: [], model: "test-model")
        let messages = try wireMessages(request)

        let systemMessages = messages.enumerated().filter { $0.element["role"] as? String == "system" }
        XCTAssertEqual(systemMessages.count, 1, "exactly one system message on the wire")
        XCTAssertEqual(systemMessages.first?.offset, 0, "the system message must be first")

        let content = systemMessages.first?.element["content"] as? String ?? ""
        XCTAssertTrue(content.contains("You are a helpful agent."))
        XCTAssertTrue(content.contains("Earlier work: did X, Y, Z."))

        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
    }

    func testNoSystemPromptStillMergesInlineSystemMessages() throws {
        let request = LLMRequest(
            systemPrompt: "",
            messages: [.system("note one"), .system("note two"), .user("hi")],
            tools: [], model: "test-model")
        let messages = try wireMessages(request)
        XCTAssertEqual(messages.count, 2, "the two system notes merge into one")
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "note one\n\nnote two")
    }

    /// Compaction inside a long tool run can leave a summary plus assistant and tool
    /// turns and no user message. Qwen's chat template rejects that, so the wire
    /// request grows a placeholder user note (after the merged system message).
    func testCompactionWithoutAUserMessageInsertsAPlaceholder() throws {
        let request = LLMRequest(
            systemPrompt: "You are a helpful agent.",
            messages: [
                .system(Compaction.summaryHeader + "Earlier work: edited files."),
                .assistant("Edited it.", calls: [ToolCall(id: "c1", name: "edit", arguments: #"{"file_path":"a.txt"}"#)]),
                .toolResult(id: "c1", name: "edit", output: "Edited a.txt."),
            ],
            tools: [], model: "test-model")
        let messages = try wireMessages(request)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[1]["content"] as? String, OpenAIClient.noUserTurnNote)
        let system = messages[0]["content"] as? String ?? ""
        XCTAssertTrue(system.contains("You are a helpful agent."))
        XCTAssertTrue(system.contains("Earlier work: edited files."))
    }

    func testARequestThatAlreadyHasAUserMessageDoesNotGrowAPlaceholder() throws {
        let request = LLMRequest(
            systemPrompt: "sys",
            messages: [.assistant("thinking", calls: []), .user("the real question")],
            tools: [], model: "test-model")
        let messages = try wireMessages(request)
        let users = messages.filter { $0["role"] as? String == "user" }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0]["content"] as? String, "the real question")
    }

    /// vLLM fails the whole conversation if a replayed tool call's arguments are not a
    /// JSON object. Cut-off or empty arguments go out as `{}`; a real object is unchanged.
    func testBrokenToolArgumentsGoOutAsAnEmptyObject() throws {
        let request = LLMRequest(
            systemPrompt: "",
            messages: [
                .user("go"),
                .assistant("", calls: [
                    ToolCall(id: "c1", name: "edit", arguments: #"{"file_path":"#),
                    ToolCall(id: "c2", name: "edit", arguments: "  "),
                    ToolCall(id: "c3", name: "edit", arguments: "[1, 2]"),
                    ToolCall(id: "c4", name: "edit", arguments: #"{"file_path":"a.txt"}"#),
                ]),
            ],
            tools: [], model: "m")
        let messages = try wireMessages(request)
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        let calls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        func args(_ index: Int) -> String {
            let function = calls[index]["function"] as! [String: Any]
            return function["arguments"] as! String
        }
        XCTAssertEqual(args(0), "{}")
        XCTAssertEqual(args(1), "{}")
        XCTAssertEqual(args(2), "{}")
        XCTAssertEqual(args(3), #"{"file_path":"a.txt"}"#)
    }
}
