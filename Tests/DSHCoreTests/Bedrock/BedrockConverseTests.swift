import XCTest
@testable import DSHCore

/// Transcripts → ConverseStream request bodies: every Converse rule the client enforces, the
/// per-model thinking and caching shapes, and the replay of Claude's signed reasoning.
///
/// The bodies are `JSONValue`s, whose objects are unordered, so every JSON expectation is compared
/// structurally (the text is parsed first); array order, which Converse cares about, is compared as is.
final class BedrockConverseTests: XCTestCase {
    private static let sonnet45 = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    private static let opus41 = "anthropic.claude-opus-4-1-20250805-v1:0"
    private static let opus46 = "global.anthropic.claude-opus-4-6-v1"
    private static let opus47 = "us.anthropic.claude-opus-4-7"
    private static let opus5 = "anthropic.claude-opus-5"
    private static let sonnet55 = "anthropic.claude-sonnet-5-5"
    private static let opus55 = "us.anthropic.claude-opus-5-5"
    private static let haiku3 = "anthropic.claude-3-haiku-20240307-v1:0"
    private static let llama = "meta.llama3-3-70b-instruct-v1:0"
    private static let nova = "amazon.nova-pro-v1:0"

    private static let echo = ToolSpec(name: "echo", description: "Echo text back",
                                       parameters: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)

    /// A 1×1 PNG.
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private static func profile(_ model: String) -> ProviderProfile {
        ProviderProfile(kind: .bedrock, name: "Bedrock", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                        model: model, awsProfile: "dsh", awsRegion: "us-east-1")
    }

    private func makeBody(_ messages: [LLMMessage], model: String = BedrockConverseTests.llama, tools: [ToolSpec] = [],
                      thinking: ThinkingLevel? = nil, maxTokens: Int? = nil, temperature: Double? = nil,
                      replay: Bool = true, profile: ProviderProfile? = nil, system: String = "You are DSH.") -> JSONValue {
        BedrockConverse.request(
            LLMRequest(systemPrompt: system, messages: messages, tools: tools, model: model,
                       temperature: temperature, maxTokens: maxTokens, thinking: thinking),
            profile: profile ?? Self.profile(model), replayReasoning: replay)
    }

    private func turns(_ body: JSONValue) -> [JSONValue] { body["messages"]?.array ?? [] }
    private func role(_ body: JSONValue, _ turn: Int) -> String? { turns(body)[turn]["role"]?.string }
    private func content(_ body: JSONValue, _ turn: Int) -> [JSONValue] { turns(body)[turn]["content"]?.array ?? [] }
    private func maxTokens(_ body: JSONValue) -> Int? { body["inferenceConfig"]?["maxTokens"]?.int }
    private func temperature(_ body: JSONValue) -> Double? { body["inferenceConfig"]?["temperature"]?.double }
    private func thinking(_ body: JSONValue) -> JSONValue? { body["additionalModelRequestFields"] }

    private func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> JSONValue {
        guard let value = JSONValue(parsing: text) else {
            XCTFail("not JSON: \(text)", file: file, line: line)
            return .null
        }
        return value
    }

    private func assistant(_ text: String, calls: [ToolCall] = [], state: String? = nil) -> LLMMessage {
        var message = LLMMessage.assistant(text, calls: calls)
        message.providerState = state
        return message
    }

    // MARK: System, roles, merging

    func testSystemPromptAndSystemNotesBecomeSystemBlocks() {
        let body = makeBody([
            .system("[Earlier conversation, compacted] summary"),
            .user("hi"),
            .assistant("hello"),
            .system("note in the middle"),
            .user("again"),
        ])
        XCTAssertEqual(body["system"], json(#"[{"text":"You are DSH."},{"text":"[Earlier conversation, compacted] summary"},{"text":"note in the middle"}]"#))
        XCTAssertEqual(turns(body).count, 3)
        XCTAssertEqual(turns(body).map { $0["role"]?.string }, ["user", "assistant", "user"])
    }

    func testBlankSystemTextIsLeftOut() {
        XCTAssertNil(makeBody([.user("hi")], system: "  ")["system"])
        XCTAssertNil(makeBody([.user("hi")], system: "")["system"])
        // A whole system list of blank notes is no list at all.
        XCTAssertNil(makeBody([.system(" \n"), .user("hi")], system: "\t")["system"])
    }

    func testConsecutiveSameRoleMessagesMerge() {
        let body = makeBody([.user("one"), .user("two"), .assistant("a"), .assistant("b")])
        XCTAssertEqual(turns(body).count, 3)
        XCTAssertEqual(JSONValue.array(content(body, 0)), json(#"[{"text":"one"},{"text":"two"}]"#))
        XCTAssertEqual(JSONValue.array(content(body, 1)), json(#"[{"text":"a"},{"text":"b"}]"#))
        XCTAssertEqual(role(body, 2), "user") // never end on an assistant turn
        XCTAssertEqual(JSONValue.array(content(body, 2)), json(#"[{"text":"Continue."}]"#))
    }

    func testConversationStartingWithTheAssistantGetsAUserTurnFirst() {
        let body = makeBody([.system("summary"), .assistant("where were we"), .user("go on")])
        XCTAssertEqual(role(body, 0), "user")
        XCTAssertEqual(JSONValue.array(content(body, 0)), json(#"[{"text":"(continuing the conversation)"}]"#))
        XCTAssertEqual(role(body, 1), "assistant")
    }

    func testEmptyAssistantTextIsNeverSent() {
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"x"}"#)
        let body = makeBody([
            .user("go"),
            .assistant("  \n", calls: [call]),
            .toolResult(id: "c1", name: "echo", output: "echoed: x"),
            .assistant(""),
            .user("and?"),
        ], tools: [Self.echo])
        XCTAssertEqual(JSONValue.array(content(body, 1)), json(#"[{"toolUse":{"toolUseId":"c1","name":"echo","input":{"text":"x"}}}]"#))
        XCTAssertEqual(JSONValue.array(content(body, 3)), json(#"[{"text":"(no reply)"}]"#))
    }

    func testAnEmptyTranscriptIsAStubUserTurn() {
        let body = makeBody([])
        XCTAssertEqual(turns(body).count, 1)
        XCTAssertEqual(JSONValue.array(content(body, 0)), json(#"[{"text":"(continuing the conversation)"}]"#))
    }

    func testAnEmptyUserMessageIsNotSentBlank() {
        let body = makeBody([.user("  ")])
        XCTAssertEqual(JSONValue.array(content(body, 0)), json(#"[{"text":"(empty message)"}]"#))
    }

    // MARK: Tools

    func testToolResultsAndCapturedImagesShareOneUserTurn() {
        let body = makeBody([
            .user("look"),
            .assistant("checking", calls: [ToolCall(id: "c1", name: "screenshot", arguments: "{}"),
                                           ToolCall(id: "c2", name: "boom", arguments: "{}")]),
            .toolResult(id: "c1", name: "screenshot", output: "Screenshot 4x4"),
            .toolResult(id: "c2", name: "boom", output: "Error: it broke"),
            LLMMessage(role: .user, content: "[Automatic message: 1 image(s) captured by screenshot.]",
                       attachments: [MessageAttachment(kind: .image, name: "shot.png", data: Self.png)],
                       imageSource: "screenshot"),
        ], model: Self.sonnet45, tools: [Self.echo])

        XCTAssertEqual(turns(body).count, 3)
        let turn = content(body, 2)
        XCTAssertEqual(turn[0], json(#"{"toolResult":{"toolUseId":"c1","content":[{"text":"Screenshot 4x4"}]}}"#))
        XCTAssertEqual(turn[1], json(#"{"toolResult":{"toolUseId":"c2","content":[{"text":"Error: it broke"}],"status":"error"}}"#))
        XCTAssertEqual(turn[2]["text"]?.string, "[Automatic message: 1 image(s) captured by screenshot.]")
        XCTAssertEqual(turn[3]["image"]?["format"]?.string, "png")
        XCTAssertEqual(turn[3]["image"]?["source"]?["bytes"]?.string, Self.png.base64EncodedString())
    }

    func testToolResultStatusIsOnlySentToModelsThatKnowIt() {
        let messages: [LLMMessage] = [
            .user("go"),
            .assistant("", calls: [ToolCall(id: "c1", name: "boom", arguments: "{}")]),
            .toolResult(id: "c1", name: "boom", output: "Permission denied: user declined."),
        ]
        XCTAssertEqual(content(makeBody(messages, model: Self.nova, tools: [Self.echo]), 2)[0]["toolResult"]?["status"]?.string, "error")
        XCTAssertNil(content(makeBody(messages, model: Self.llama, tools: [Self.echo]), 2)[0]["toolResult"]?["status"])
    }

    func testToolCallArgumentsBecomeJsonObjects() {
        let body = makeBody([
            .user("go"),
            .assistant("", calls: [ToolCall(id: "c1", name: "echo", arguments: "not json"),
                                   ToolCall(id: "c2", name: "echo", arguments: "[1,2]")]),
            .toolResult(id: "c1", name: "echo", output: "a"),
            .toolResult(id: "c2", name: "echo", output: ""),
        ], tools: [Self.echo])
        XCTAssertEqual(content(body, 1)[0]["toolUse"]?["input"], json("{}"))
        XCTAssertEqual(content(body, 1)[1]["toolUse"]?["input"], json(#"{"value":[1,2]}"#))
        XCTAssertEqual(content(body, 2)[1]["toolResult"]?["content"], json(#"[{"text":"(no output)"}]"#))
    }

    func testEmptyNullAndScalarArgumentsAlsoBecomeObjects() {
        let body = makeBody([
            .user("go"),
            .assistant("", calls: [ToolCall(id: "c1", name: "a", arguments: ""),
                                   ToolCall(id: "c2", name: "a", arguments: "null"),
                                   ToolCall(id: "c3", name: "a", arguments: "7"),
                                   ToolCall(id: "c4", name: "a", arguments: #""text""#),
                                   ToolCall(id: "c5", name: "a", arguments: #"{"n":1,"s":"é","nested":{"k":[true,null]}}"#)]),
        ], tools: [Self.echo])
        let uses = content(body, 1).map { $0["toolUse"]?["input"] }
        XCTAssertEqual(uses[0], json("{}"))
        XCTAssertEqual(uses[1], json("{}"))
        XCTAssertEqual(uses[2], json(#"{"value":7}"#))
        XCTAssertEqual(uses[3], json(#"{"value":"text"}"#))
        XCTAssertEqual(uses[4], json(#"{"n":1,"s":"é","nested":{"k":[true,null]}}"#))
    }

    func testToolIdsFromOtherProvidersAreMadeValid() {
        let id = "call abc/1:" + String(repeating: "x", count: 80)
        let body = makeBody([.user("go"), .assistant("", calls: [ToolCall(id: id, name: "echo", arguments: "{}")]),
                         .toolResult(id: id, name: "echo", output: "ok")], tools: [Self.echo])
        let useID = content(body, 1)[0]["toolUse"]?["toolUseId"]?.string ?? ""
        XCTAssertTrue(useID.hasPrefix("call_abc_1:xxx"))
        XCTAssertEqual(useID.count, 64)
        XCTAssertEqual(content(body, 2)[0]["toolResult"]?["toolUseId"]?.string, useID)
    }

    func testToolUseIDsKeepTheirAllowedCharactersAndCountUTF16Units() {
        XCTAssertEqual(BedrockConverse.toolUseID("toolu_01A.b:c-d"), "toolu_01A.b:c-d")
        XCTAssertEqual(BedrockConverse.toolUseID(""), "call")
        XCTAssertEqual(BedrockConverse.toolUseID("a b\tc"), "a_b_c")
        // Each UTF-16 unit that isn't allowed becomes one underscore: an emoji is two.
        XCTAssertEqual(BedrockConverse.toolUseID("x😀y"), "x__y")
        XCTAssertEqual(BedrockConverse.toolUseID("é"), "_")
        XCTAssertEqual(BedrockConverse.toolUseID(String(repeating: "a", count: 64)).count, 64)
        XCTAssertEqual(BedrockConverse.toolUseID(String(repeating: "a", count: 65)).count, 64)
    }

    func testToolSpecsCarrySchemasWithAFallback() {
        let body = makeBody([.user("hi")], tools: [Self.echo, ToolSpec(name: "bare", description: "", parameters: "not a schema")])
        XCTAssertEqual(body["toolConfig"]?["tools"], json("""
            [{"toolSpec":{"name":"echo","description":"Echo text back","inputSchema":{"json":{"type":"object","properties":{"text":{"type":"string"}}}}}},
             {"toolSpec":{"name":"bare","inputSchema":{"json":{"type":"object","properties":{}}}}}]
            """))
    }

    func testAScalarSchemaIsReplacedToo() {
        let body = makeBody([.user("hi")], tools: [ToolSpec(name: "t", description: " ", parameters: "[1]")])
        XCTAssertEqual(body["toolConfig"]?["tools"]?[0]?["toolSpec"]?["inputSchema"], json(#"{"json":{"type":"object","properties":{}}}"#))
        XCTAssertNil(body["toolConfig"]?["tools"]?[0]?["toolSpec"]?["description"], "a blank description is left out")
    }

    func testNoToolsNoToolConfig() {
        XCTAssertNil(makeBody([.user("hi")])["toolConfig"])
    }

    func testToolHistoryKeepsAToolConfigEvenWithoutTools() {
        let body = makeBody([
            .user("go"),
            .assistant("", calls: [ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .toolResult(id: "c1", name: "read_file", output: "contents"),
            .assistant("done"),
            .user("summarise"),
        ])
        let tools = body["toolConfig"]?["tools"]?.array ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["toolSpec"]?["name"]?.string, "read_file")
        XCTAssertEqual(tools.first?["toolSpec"]?["description"]?.string, "A tool used earlier in this conversation (no longer offered).")
    }

    func testToolHistoryNamesEachToolOnceInOrder() {
        let calls = [ToolCall(id: "a", name: "grep", arguments: "{}"), ToolCall(id: "b", name: "read_file", arguments: "{}"),
                     ToolCall(id: "c", name: "grep", arguments: "{}")]
        let body = makeBody([
            .user("go"), .assistant("", calls: calls),
            .toolResult(id: "a", name: "grep", output: "1"), .toolResult(id: "b", name: "read_file", output: "2"),
            .toolResult(id: "c", name: "grep", output: "3"),
        ])
        XCTAssertEqual((body["toolConfig"]?["tools"]?.array ?? []).map { $0["toolSpec"]?["name"]?.string }, ["grep", "read_file"])
    }

    func testUnansweredCallsGetStubResultsAndOrphanResultsBecomeText() {
        let body = makeBody([
            .user("go"),
            .assistant("", calls: [ToolCall(id: "c1", name: "echo", arguments: "{}"), ToolCall(id: "c2", name: "echo", arguments: "{}")]),
            .toolResult(id: "c1", name: "echo", output: "one"),
            .user("stop that"),
            .toolResult(id: "zz", name: "grep", output: "late result"),
        ], tools: [Self.echo])
        let turn = content(body, 2)
        XCTAssertEqual(turn[0]["toolResult"]?["toolUseId"]?.string, "c1")
        XCTAssertEqual(turn[1]["toolResult"]?["toolUseId"]?.string, "c2")
        XCTAssertTrue(turn[1]["toolResult"]?["content"]?[0]?["text"]?.string?.hasPrefix("Not run") ?? false)
        XCTAssertEqual(turn[2]["text"]?.string, "stop that")
        XCTAssertEqual(turn[3]["text"]?.string, "[Result of grep]\nlate result")
    }

    func testAnOrphanResultWithoutAnOutputOrNameSaysSo() {
        let body = makeBody([.user("go"), LLMMessage(role: .tool, content: "  ", toolCallID: "zz")])
        XCTAssertEqual(content(body, 0)[1]["text"]?.string, "[Result of a tool]\n(no output)")
    }

    func testCallsStillOpenAtTheEndAreClosedBeforeTheFinalTurn() {
        // The transcript ends with a tool call nobody answered (interrupted run): it gets a stub result
        // and the conversation still ends on a user turn.
        let body = makeBody([.user("go"), .assistant("", calls: [ToolCall(id: "c1", name: "echo", arguments: "{}")])], tools: [Self.echo])
        XCTAssertEqual(turns(body).count, 3)
        XCTAssertEqual(role(body, 2), "user")
        XCTAssertEqual(content(body, 2)[0]["toolResult"]?["toolUseId"]?.string, "c1")
        XCTAssertEqual(content(body, 2)[0]["toolResult"]?["content"]?[0]?["text"]?.string,
                       "Not run — the turn was interrupted before this call executed.")
    }

    func testOnlyEngineFailureWordingCountsAsAToolError() {
        XCTAssertTrue(BedrockConverse.isError("Error: nope"))
        XCTAssertTrue(BedrockConverse.isError("Errors happened"))
        XCTAssertTrue(BedrockConverse.isError("Permission denied: no"))
        XCTAssertFalse(BedrockConverse.isError("error: lowercase is not the engine's wording"))
        XCTAssertFalse(BedrockConverse.isError("No Error here"))
        XCTAssertFalse(BedrockConverse.isError("permission denied"))
        XCTAssertFalse(BedrockConverse.isError(""))
    }

    // MARK: Attachments

    func testAttachmentsBecomeImagesDocumentsOrText() {
        let notes = Data([0xEF, 0xBB, 0xBF]) + Data("# Notes\nÜber".utf8)
        let body = makeBody([.user("see these", attachments: [
            MessageAttachment(kind: .image, name: "photo.JPG", data: Data([1, 2, 3])),
            MessageAttachment(kind: .file, name: "Q3 report (final).pdf", data: Data("%PDF-1.7".utf8)),
            MessageAttachment(kind: .file, name: "notes.md", data: notes),
            MessageAttachment(kind: .file, name: "blob.bin", data: Data([0, 159, 146, 150])),
            MessageAttachment(kind: .image, name: "diagram.bmp", data: Data([0x42, 0x4D, 0, 0])),
        ])], model: Self.sonnet45)
        let content = content(body, 0)
        XCTAssertEqual(content[0]["text"]?.string, "see these")
        XCTAssertEqual(content[1], json(#"{"image":{"format":"jpeg","source":{"bytes":"AQID"}}}"#))
        XCTAssertEqual(content[2], json(#"{"document":{"format":"pdf","name":"Q3 report (final)","source":{"bytes":"JVBERi0xLjc="}}}"#))
        XCTAssertEqual(content[3]["text"]?.string, "[Attached file: notes.md]\n# Notes\nÜber")
        XCTAssertEqual(content[4]["text"]?.string, "[Attached file: blob.bin (4 bytes of binary data, not shown)]")
        XCTAssertTrue(content[5]["text"]?.string?.hasPrefix("[Attached file: diagram.bmp") ?? false)
    }

    func testAllFourImageFormatsAreRecognisedByExtension() {
        let files = ["a.png": "png", "a.jpg": "jpeg", "a.jpeg": "jpeg", "a.gif": "gif", "a.webp": "webp"]
        for (name, format) in files {
            let body = makeBody([.user("", attachments: [MessageAttachment(kind: .image, name: name, data: Data([9]))])], model: Self.sonnet45)
            XCTAssertEqual(content(body, 0)[0]["image"]?["format"]?.string, format, name)
        }
    }

    func testDocumentNamesUseOnlyWhatConverseAllows() {
        func name(_ file: String) -> String? {
            let body = makeBody([.user("read", attachments: [MessageAttachment(kind: .file, name: file, data: Data("%PDF".utf8))])], model: Self.sonnet45)
            return content(body, 0).first { $0["document"] != nil }?["document"]?["name"]?.string
        }
        XCTAssertEqual(name("Q3 report (final).pdf"), "Q3 report (final)")
        XCTAssertEqual(name("a   b\t[1].pdf"), "a b-[1]")
        XCTAssertEqual(name("héllo_wörld.v2.pdf"), "h-llo-w-rld-v2")
        XCTAssertEqual(name("   .pdf"), "document")
        XCTAssertEqual(name(" .pdf"), "document")
        XCTAssertEqual(name("archive.tar.pdf"), "archive-tar", "only the last extension goes")
        XCTAssertEqual(name("dir/sub\\name.pdf"), "name")
        XCTAssertEqual(name("scan📄.pdf"), "scan--", "one hyphen per UTF-16 unit")
        XCTAssertEqual(name("no extension.pdf.PDF"), "no extension-pdf")
    }

    func testAFileWithBadUTF8OrNulBytesIsANote() {
        let bad = makeBody([.user("x", attachments: [MessageAttachment(kind: .file, name: "a.txt", data: Data([0x68, 0xFF, 0x69]))])])
        XCTAssertEqual(content(bad, 0)[1]["text"]?.string, "[Attached file: a.txt (3 bytes of binary data, not shown)]")
        let nul = makeBody([.user("x", attachments: [MessageAttachment(kind: .file, name: "a.txt", data: Data([0x68, 0x00, 0x69]))])])
        XCTAssertEqual(content(nul, 0)[1]["text"]?.string, "[Attached file: a.txt (3 bytes of binary data, not shown)]")
        let empty = makeBody([.user("x", attachments: [MessageAttachment(kind: .file, name: "e.txt", data: Data())])])
        XCTAssertEqual(content(empty, 0)[1]["text"]?.string, "[Attached file: e.txt]\n")
    }

    func testPdfsAreTextNotesForModelsWithoutDocuments() {
        let body = makeBody([.user("read", attachments: [MessageAttachment(kind: .file, name: "a.pdf", data: Data([0xFF, 0xFE, 0x00]))])])
        XCTAssertTrue(content(body, 0)[1]["text"]?.string?.contains("binary data") ?? false)
    }

    func testALoneDocumentTravelsWithText() {
        let body = makeBody([.user("", attachments: [MessageAttachment(kind: .file, name: "a.pdf", data: Data([1]))])], model: Self.nova)
        XCTAssertNotNil(content(body, 0)[0]["document"])
        XCTAssertEqual(content(body, 0)[1]["text"]?.string, "(see the attached document)")
    }

    // MARK: Caching

    func testClaudeGetsCachePointsAfterSystemToolsAndConversation() {
        let body = makeBody([.user("hi")], model: Self.sonnet45, tools: [Self.echo])
        let cache = json(#"{"cachePoint":{"type":"default"}}"#)
        XCTAssertEqual(body["system"]?.array?.last, cache)
        XCTAssertEqual(body["toolConfig"]?["tools"]?.array?.last, cache)
        XCTAssertEqual(content(body, 0).last, cache)
    }

    func testNovaCachesSystemAndConversationButNotTools() {
        let body = makeBody([.user("hi")], model: Self.nova, tools: [Self.echo])
        XCTAssertNotNil(body["system"]?.array?.last?["cachePoint"])
        XCTAssertNil(body["toolConfig"]?["tools"]?.array?.last?["cachePoint"])
        XCTAssertNotNil(content(body, 0).last?["cachePoint"])
    }

    func testOtherModelsGetNoCachePoints() {
        for model in [Self.llama, Self.haiku3] {
            let text = makeBody([.user("hi")], model: model, tools: [Self.echo]).serialized()
            XCTAssertFalse(text.contains("cachePoint"), model)
        }
    }

    func testTheCachePointClosesTheLastTurn() {
        // Two user messages merge into one turn; the cache point closes that turn.
        let body = makeBody([.user("one"), .user("two")], model: Self.sonnet45)
        XCTAssertEqual(turns(body).count, 1)
        XCTAssertEqual(content(body, 0).count, 3)
        XCTAssertNotNil(content(body, 0)[2]["cachePoint"])
    }

    // MARK: Inference settings

    func testMaxTokensComeFromRequestProfileOrTheModel() {
        XCTAssertEqual(maxTokens(makeBody([.user("hi")], model: Self.llama)), 2048)
        XCTAssertEqual(maxTokens(makeBody([.user("hi")], model: Self.sonnet45)), 16_000)
        XCTAssertEqual(maxTokens(makeBody([.user("hi")], model: Self.sonnet45, maxTokens: 1234)), 1234)
        var profile = Self.profile(Self.haiku3)
        profile.maxOutputTokens = 10_000
        // Above the model's ceiling: clamped rather than refused.
        XCTAssertEqual(maxTokens(makeBody([.user("hi")], model: Self.haiku3, profile: profile)), 4096)
        // The request's own limit beats the profile's.
        XCTAssertEqual(maxTokens(makeBody([.user("hi")], model: Self.haiku3, maxTokens: 100, profile: profile)), 100)
    }

    func testTemperatureIsSentWhereSamplingIsAllowed() {
        XCTAssertEqual(temperature(makeBody([.user("hi")], model: Self.llama, temperature: 0.3)), 0.3)
        XCTAssertNil(temperature(makeBody([.user("hi")], model: Self.opus47, temperature: 0.3)))
        // The profile's temperature applies when the request has none.
        var profile = Self.profile(Self.llama)
        profile.temperature = 0.9
        XCTAssertEqual(temperature(makeBody([.user("hi")], model: Self.llama, profile: profile)), 0.9)
        XCTAssertEqual(temperature(makeBody([.user("hi")], model: Self.llama, temperature: 0.1, profile: profile)), 0.1)
    }

    // MARK: Thinking

    func testBudgetThinkingForClaude45() {
        let body = makeBody([.user("hi")], model: Self.sonnet45, thinking: .high, temperature: 0.2)
        XCTAssertEqual(thinking(body), json(#"{"thinking":{"type":"enabled","budget_tokens":16000}}"#))
        XCTAssertEqual(maxTokens(body), 16_000 + BedrockConverse.replyTokens)
        XCTAssertNil(temperature(body), "Claude refuses temperature with thinking")
        XCTAssertNil(body["outputConfig"])
    }

    func testThinkingOffSendsNothingAndAllowsTemperature() {
        let body = makeBody([.user("hi")], model: Self.sonnet45, thinking: .off, temperature: 0.2)
        XCTAssertNil(thinking(body))
        XCTAssertEqual(temperature(body), 0.2)
    }

    func testTheProfileLevelAppliesWhenTheRequestHasNone() {
        var profile = Self.profile(Self.sonnet45)
        profile.thinking = .low
        let body = makeBody([.user("hi")], model: Self.sonnet45, profile: profile)
        XCTAssertEqual(thinking(body)?["thinking"]?["budget_tokens"]?.int, 2048)
        // …and the request's own level beats it.
        let off = self.makeBody([.user("hi")], model: Self.sonnet45, thinking: .off, profile: profile)
        XCTAssertNil(thinking(off))
    }

    func testBudgetStaysBelowTheModelsOutputCeiling() {
        let body = makeBody([.user("hi")], model: Self.opus41, thinking: .max)
        XCTAssertEqual(maxTokens(body), 32_000)
        XCTAssertEqual(thinking(body)?["thinking"]?["budget_tokens"]?.int, 32_000 - BedrockConverse.replyTokens)
    }

    func testTheBudgetAndTheOutputRoomFollowTheLevel() {
        let expected: [(ThinkingLevel, Int)] = [(.low, 2048), (.medium, 8192), (.high, 16_000), (.max, 32_000)]
        for (level, budget) in expected {
            let body = makeBody([.user("hi")], model: Self.sonnet45, thinking: level)
            XCTAssertEqual(thinking(body)?["thinking"]?["budget_tokens"]?.int, budget, level.rawValue)
            // Room for the thinking and the reply, but never below the model's usual output limit.
            XCTAssertEqual(maxTokens(body), max(16_000, budget + BedrockConverse.replyTokens), level.rawValue)
        }
        // Claude 3.7 Sonnet is the first budget model.
        let sonnet37 = makeBody([.user("hi")], model: "anthropic.claude-3-7-sonnet-20250219-v1:0", thinking: .low)
        XCTAssertEqual(thinking(sonnet37)?["thinking"]?["budget_tokens"]?.int, 2048)
        XCTAssertEqual(BedrockConverse.minThinkingBudget, 1024)
    }

    func testNonClaudeModelsIgnoreThinking() {
        let body = makeBody([.user("hi")], model: Self.llama, thinking: .max, temperature: 0.5)
        XCTAssertNil(thinking(body))
        XCTAssertNil(body["outputConfig"])
        XCTAssertEqual(temperature(body), 0.5)
    }

    func testAdaptiveClaudeThinksByEffort() {
        // model, level, additionalModelRequestFields, outputConfig.effort
        let cases: [(String, ThinkingLevel, String?, String?)] = [
            (Self.opus46, .high, #"{"thinking":{"type":"adaptive"}}"#, "high"),
            (Self.opus47, .max, #"{"thinking":{"type":"adaptive","display":"summarized"}}"#, "max"),
            (Self.opus55, .low, #"{"thinking":{"type":"adaptive","display":"summarized"}}"#, "low"),
            (Self.opus47, .off, nil, nil),
            (Self.opus5, .off, #"{"thinking":{"type":"disabled"}}"#, nil),
            (Self.sonnet55, .off, #"{"thinking":{"type":"between_tools"}}"#, nil),
            (Self.opus55, .off, nil, "low"),
        ]
        for (model, level, fields, effort) in cases {
            let body = makeBody([.user("hi")], model: model, thinking: level)
            XCTAssertEqual(thinking(body), fields.map { json($0) }, "\(model) \(level)")
            XCTAssertEqual(body["outputConfig"]?["effort"]?.string, effort, "\(model) \(level)")
        }
    }

    func testEffortWordsPerLevel() {
        XCTAssertEqual([ThinkingLevel.off, .low, .medium, .high, .max].map(BedrockConverse.effort), ["low", "low", "medium", "high", "max"])
        XCTAssertEqual([ThinkingLevel.off, .low, .medium, .high, .max].map(BedrockConverse.thinkingBudget), [0, 2048, 8192, 16_000, 32_000])
    }

    func testAdaptiveThinkingRaisesTheOutputRoom() {
        let body = makeBody([.user("hi")], model: Self.opus47, thinking: .max)
        XCTAssertEqual(maxTokens(body), 32_000 + BedrockConverse.replyTokens)
    }

    func testAdaptiveClaudeWithNoLevelSendsNoThinkingField() {
        // Claude 4.6 – 4.8 don't think unless asked; Claude 5 and later do, so they take no temperature.
        let opus46 = makeBody([.user("hi")], model: Self.opus46, temperature: 0.4)
        XCTAssertNil(thinking(opus46))
        XCTAssertNil(opus46["outputConfig"])
        XCTAssertEqual(temperature(opus46), 0.4)
        let opus5 = makeBody([.user("hi")], model: Self.opus5, temperature: 0.4)
        XCTAssertNil(thinking(opus5))
        XCTAssertNil(temperature(opus5), "a model that thinks by default takes no temperature")
    }

    func testClaude46KeepsTemperatureWhenNotThinking() {
        XCTAssertEqual(temperature(makeBody([.user("hi")], model: Self.opus46, temperature: 0.7)), 0.7)
        XCTAssertNil(temperature(makeBody([.user("hi")], model: Self.opus46, thinking: .low, temperature: 0.7)))
    }

    // MARK: Signed reasoning replay

    private static let call = ToolCall(id: "tooluse_1", name: "echo", arguments: #"{"text":"hi"}"#)

    /// What `ConverseReply` records for a turn that thought, said a word and called a tool.
    private static let state = """
        [{"reasoningContent":{"reasoningText":{"text":"let me think","signature":"sig-1"}}},
         {"text":"Checking."},{"text":"\\n\\n"},
         {"toolUse":{"toolUseId":"tooluse_1","name":"echo","input":{"text":"hi"}}}]
        """

    private func toolTurn(_ state: String?) -> [LLMMessage] {
        [.user("go"),
         assistant("Checking.\n\n", calls: [Self.call], state: state),
         .toolResult(id: "tooluse_1", name: "echo", output: "echoed: hi")]
    }

    func testSignedReasoningIsReplayedInItsOriginalOrder() {
        let body = makeBody(toolTurn(Self.state), model: Self.sonnet45, tools: [Self.echo], thinking: .high)
        XCTAssertEqual(JSONValue.array(content(body, 1)), json("""
            [{"reasoningContent":{"reasoningText":{"text":"let me think","signature":"sig-1"}}},{"text":"Checking."},
             {"toolUse":{"toolUseId":"tooluse_1","name":"echo","input":{"text":"hi"}}}]
            """))
        XCTAssertNotNil(thinking(body))
    }

    func testBudgetThinkingIsLeftOffWhenTheToolTurnLostItsReasoning() {
        // A transcript rebuilt from text: Claude would refuse thinking without the signed block.
        let body = makeBody(toolTurn(nil), model: Self.sonnet45, tools: [Self.echo], thinking: .high, temperature: 0.4)
        XCTAssertNil(thinking(body))
        XCTAssertEqual(temperature(body), 0.4)
        XCTAssertEqual(content(body, 1)[0], json(#"{"text":"Checking.\n\n"}"#))
    }

    func testOnlyTheToolTurnInProgressNeedsItsReasoning() {
        // An older tool turn without state doesn't matter once the conversation moved on.
        var messages = toolTurn(nil)
        messages.append(.assistant("All done."))
        messages.append(.user("thanks, now more"))
        let body = makeBody(messages, model: Self.sonnet45, tools: [Self.echo], thinking: .high)
        XCTAssertNotNil(thinking(body))
    }

    func testAdaptiveThinkingNeedsNoFallback() {
        let body = makeBody(toolTurn(nil), model: Self.opus47, tools: [Self.echo], thinking: .high)
        XCTAssertNotNil(thinking(body))
    }

    func testReasoningIsNotReplayedWhenThinkingIsOffOrRefused() {
        let off = makeBody(toolTurn(Self.state), model: Self.sonnet45, tools: [Self.echo], thinking: .off)
        XCTAssertFalse(off.serialized().contains("reasoningContent"))
        let refused = makeBody(toolTurn(Self.state), model: Self.sonnet45, tools: [Self.echo], thinking: .high, replay: false)
        XCTAssertFalse(refused.serialized().contains("reasoningContent"))
        XCTAssertNil(thinking(refused), "and the budget fallback applies")
    }

    func testReasoningIsNotReplayedToAModelThatIsNotClaude() {
        // Another provider's state (or one left from a model switch) is never sent to a non-Claude model.
        let body = makeBody(toolTurn(Self.state), model: Self.llama, tools: [Self.echo], thinking: .high)
        XCTAssertFalse(body.serialized().contains("reasoningContent"))
        XCTAssertEqual(content(body, 1)[0], json(#"{"text":"Checking.\n\n"}"#))
    }

    func testStateThatNoLongerMatchesTheCallsIsIgnored() {
        var messages = toolTurn(Self.state)
        messages[1].toolCalls = [ToolCall(id: "other", name: Self.call.name, arguments: Self.call.arguments.raw)]
        messages[2] = .toolResult(id: "other", name: "echo", output: "x")
        let body = makeBody(messages, model: Self.sonnet45, tools: [Self.echo], thinking: .high)
        XCTAssertFalse(body.serialized().contains("reasoningContent"))
        XCTAssertEqual(content(body, 1)[1]["toolUse"]?["toolUseId"]?.string, "other")
    }

    func testUnreadableStateIsIgnored() {
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: "{not json")))
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: #"[{"text":"no reasoning"}]"#)))
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: #"[{"video":{}}]"#)))
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: #"{"reasoningContent":{}}"#)), "not an array")
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: #"["text"]"#)), "not blocks")
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x", state: "")))
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("x")))
    }

    func testReplayKeepsRedactedReasoningAndDropsBlankText() {
        let state = #"[{"reasoningContent":{"redactedContent":"AQID"}},{"text":"  "},{"text":"hello"}]"#
        let blocks = BedrockConverse.replayBlocks(assistant("hello", state: state))
        XCTAssertEqual(blocks, [json(#"{"reasoningContent":{"redactedContent":"AQID"}}"#), json(#"{"text":"hello"}"#)])
    }

    func testReplayNeedsTheToolCallsToMatchExactly() {
        let onlyTool = #"[{"reasoningContent":{"reasoningText":{"text":"t","signature":"s"}}},{"toolUse":{"toolUseId":"a","name":"x","input":{}}}]"#
        let two = [ToolCall(id: "a", name: "x", arguments: "{}"), ToolCall(id: "b", name: "x", arguments: "{}")]
        XCTAssertNotNil(BedrockConverse.replayBlocks(assistant("", calls: [ToolCall(id: "a", name: "x", arguments: "{}")], state: onlyTool)))
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("", calls: two, state: onlyTool)), "a call is missing from the state")
        XCTAssertNil(BedrockConverse.replayBlocks(assistant("", state: onlyTool)), "the state has a call the message lacks")
    }
}

// MARK: - The reply reducer on its own

/// The ConverseStream reducer fed decoded frames directly: what it shows while they go by, and the
/// calls, finish word, usage and replay state it settles on at the end.
final class ConverseReplyTests: XCTestCase {
    private struct FrameError: Error, Equatable {
        let type: String
        let message: String
    }

    private func decode(_ frame: [UInt8]) throws -> AWSEventMessage { try AWSEventStream.decode(frame) }

    /// The events shown as the frames go by, and the final `.done`.
    private func run(_ frames: [UInt8]...) throws -> (shown: [String], calls: [ToolCall], finish: String?, usage: LLMUsage?, state: String?) {
        var reply = ConverseReply { type, message in FrameError(type: type, message: message) }
        var shown: [String] = []
        for frame in frames {
            switch try reply.handle(try decode(frame)) {
            case .text(let delta)?: shown.append("text:\(delta)")
            case .reasoning(let delta)?: shown.append("reasoning:\(delta)")
            case .done?: XCTFail("only finish() ends a reply")
            case nil: break
            }
        }
        guard case .done(let calls, let finish, let usage, let state) = try reply.finish() else {
            XCTFail("finish() must end with .done")
            return (shown, [], nil, nil, nil)
        }
        return (shown, calls, finish, usage, state)
    }

    private func json(_ text: String?) -> JSONValue? { text.flatMap { JSONValue(parsing: $0) } }

    func testTextAndReasoningAreShownAsTheyComeAndNothingElseIs() throws {
        let result = try run(EventStreamFrames.messageStart(), EventStreamFrames.reasoning(0, text: "hm"), EventStreamFrames.textDelta(1, "Hi"),
                             EventStreamFrames.toolStart(2, id: "t", name: "x"), EventStreamFrames.toolInput(2, "{}"),
                             EventStreamFrames.blockStop(2), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(result.shown, ["reasoning:hm", "text:Hi"])
    }

    func testEmptyTextIsNotShown() throws {
        let result = try run(EventStreamFrames.textDelta(0, ""), EventStreamFrames.textDelta(0, "x"), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(result.shown, ["text:x"])
    }

    func testTheSignatureArrivesInPiecesAndIsJoined() throws {
        let result = try run(EventStreamFrames.reasoning(0, text: "think"), EventStreamFrames.reasoning(0, signature: "ab"),
                             EventStreamFrames.reasoning(0, signature: "cd"), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(json(result.state), json(#"[{"reasoningContent":{"reasoningText":{"text":"think","signature":"abcd"}}}]"#))
    }

    func testRedactedPiecesAreJoinedBeforeTheyAreEncodedAgain() throws {
        // "AQID" is 01 02 03 and "BAUG" is 04 05 06; a base64 of the two together is not the two strings glued.
        let result = try run(EventStreamFrames.reasoning(0, redacted: "AQID"), EventStreamFrames.reasoning(0, redacted: "BAUG"),
                             EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(json(result.state), json(#"[{"reasoningContent":{"redactedContent":"AQIDBAUG"}}]"#))
        let odd = try run(EventStreamFrames.reasoning(0, redacted: "AQ=="), EventStreamFrames.reasoning(0, redacted: "Ag=="),
                          EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(json(odd.state), json(#"[{"reasoningContent":{"redactedContent":"AQI="}}]"#), "bytes 01 and 02 → 01 02")
    }

    func testAPieceThatIsNotBase64StillLeavesAnEmptyRedactedBlock() throws {
        // Faithful to the Windows client: the list is created before the bytes are decoded.
        let result = try run(EventStreamFrames.reasoning(0, redacted: "***"), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(json(result.state), json(#"[{"reasoningContent":{"redactedContent":""}}]"#))
    }

    func testRedactedContentWinsOverASignatureOnTheSameBlock() throws {
        let result = try run(EventStreamFrames.reasoning(0, text: "t", signature: "s", redacted: "AQID"), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(json(result.state), json(#"[{"reasoningContent":{"redactedContent":"AQID"}}]"#))
    }

    func testUnsignedReasoningIsShownButNeverReplayed() throws {
        let result = try run(EventStreamFrames.reasoning(0, text: "thinking as DeepSeek does"), EventStreamFrames.textDelta(1, "answer"),
                             EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(result.shown, ["reasoning:thinking as DeepSeek does", "text:answer"])
        XCTAssertNil(result.state)
    }

    func testTheStateKeepsEveryBlockInIndexOrderAndDropsBlankText() throws {
        let result = try run(EventStreamFrames.textDelta(2, "after"), EventStreamFrames.textDelta(1, " \n"),
                             EventStreamFrames.toolStart(3, id: "t1", name: "echo"), EventStreamFrames.toolInput(3, #"{"a":1}"#),
                             EventStreamFrames.reasoning(0, text: "why", signature: "sig"), EventStreamFrames.stop("tool_use"))
        XCTAssertEqual(json(result.state), json("""
            [{"reasoningContent":{"reasoningText":{"text":"why","signature":"sig"}}},{"text":"after"},
             {"toolUse":{"toolUseId":"t1","name":"echo","input":{"a":1}}}]
            """))
        XCTAssertEqual(result.calls, [ToolCall(id: "t1", name: "echo", arguments: #"{"a":1}"#)])
    }

    func testAToolCallWithoutAnIdIsNamedByItsPosition() throws {
        let result = try run(EventStreamFrames.toolStart(3, id: "", name: "echo"), EventStreamFrames.toolInput(2, #"{"x":1}"#),
                             EventStreamFrames.stop("tool_use"))
        XCTAssertEqual(result.calls, [ToolCall(id: "call-2", name: "", arguments: #"{"x":1}"#),
                                      ToolCall(id: "call-3", name: "echo", arguments: "{}")])
    }

    func testToolInputThatIsNotAnObjectIsPassedOnRawButReplayedAsEmpty() throws {
        let result = try run(EventStreamFrames.reasoning(0, text: "t", signature: "s"), EventStreamFrames.toolStart(1, id: "t1", name: "echo"),
                             EventStreamFrames.toolInput(1, "[1,2]"), EventStreamFrames.stop("tool_use"))
        XCTAssertEqual(result.calls.map { $0.arguments.raw }, ["[1,2]"])
        XCTAssertEqual(json(result.state)?[1]?["toolUse"]?["input"], json("{}"))
    }

    func testUsageCountsTheCachedShareOfThePromptOnlyWhenTheReplySaysSo() throws {
        let plain = try run(EventStreamFrames.event("metadata", ["usage": ["inputTokens": 7, "outputTokens": 3]]), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(plain.usage, LLMUsage(promptTokens: 7, completionTokens: 3, cachedTokens: nil))
        let nulled = try run(EventStreamFrames.event("metadata", ["usage": ["inputTokens": 7, "outputTokens": 3, "cacheReadInputTokens": .null]]),
                             EventStreamFrames.stop("end_turn"))
        XCTAssertNil(nulled.usage?.cachedTokens)
        let cached = try run(EventStreamFrames.metadata(input: 1, output: 2, cacheRead: 30, cacheWrite: 4), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(cached.usage, LLMUsage(promptTokens: 35, completionTokens: 2, cachedTokens: 30))
        let zero = try run(EventStreamFrames.metadata(input: 5, output: 2), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(zero.usage?.cachedTokens, 0, "a reported zero is a zero, not unknown")
        let none = try run(EventStreamFrames.stop("end_turn"))
        XCTAssertNil(none.usage)
    }

    func testUsageFieldsThatAreNotWholeNumbersCountAsZero() throws {
        let odd = try run(EventStreamFrames.event("metadata", ["usage": ["inputTokens": 1.5, "outputTokens": "9", "cacheReadInputTokens": 8]]),
                          EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(odd.usage, LLMUsage(promptTokens: 8, completionTokens: 0, cachedTokens: 8))
        let huge = try run(EventStreamFrames.event("metadata", ["usage": ["inputTokens": 5_000_000_000]]), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(huge.usage?.promptTokens, 0, "beyond Int32 is not a token count")
    }

    func testTheBlockIndexDefaultsToZero() throws {
        let result = try run(EventStreamFrames.event("contentBlockDelta", ["delta": ["text": "a"]]),
                             EventStreamFrames.textDelta(0, "b"), EventStreamFrames.stop("end_turn"))
        XCTAssertEqual(result.shown, ["text:a", "text:b"])
    }

    func testFinishWordsFollowTheStopReason() throws {
        for (reason, word) in [("end_turn", "stop"), ("stop_sequence", "stop"), ("tool_use", "tool_calls"),
                               ("max_tokens", "length"), ("guardrail_intervened", "guardrail_intervened")] {
            XCTAssertEqual(try run(EventStreamFrames.stop(reason)).finish, word, reason)
        }
        XCTAssertEqual(try run(EventStreamFrames.event("messageStop", [:])).finish, "stop", "no reason is a normal stop")
    }

    func testExceptionAndErrorFramesAreHandedToTheMapper() throws {
        var reply = ConverseReply { type, message in FrameError(type: type, message: message) }
        XCTAssertThrowsError(try reply.handle(decode(EventStreamFrames.exception("throttlingException", "slow down")))) { error in
            XCTAssertEqual(error as? FrameError, FrameError(type: "throttlingException", message: "slow down"))
        }
        let unmodelled = EventStreamFrames.frame([(":error-code", "InternalFailure"), (":error-message", "It broke."), (":message-type", "error")], payload: Data())
        XCTAssertThrowsError(try reply.handle(decode(unmodelled))) { error in
            XCTAssertEqual(error as? FrameError, FrameError(type: "InternalFailure", message: "It broke."))
        }
        // An exception without JSON keeps its raw text as the message.
        let raw = EventStreamFrames.frame([(":exception-type", "modelTimeoutException"), (":message-type", "exception")], payload: Data("plain words".utf8))
        XCTAssertThrowsError(try reply.handle(decode(raw))) { error in
            XCTAssertEqual(error as? FrameError, FrameError(type: "modelTimeoutException", message: "plain words"))
        }
    }

    func testTheMessageOfAnExceptionPayload() {
        XCTAssertEqual(ConverseReply.messageOf(#"{"message":"lower"}"#), "lower")
        XCTAssertEqual(ConverseReply.messageOf(#"{"Message":"upper"}"#), "upper")
        XCTAssertEqual(ConverseReply.messageOf(#"{"other":1}"#), #"{"other":1}"#)
        XCTAssertEqual(ConverseReply.messageOf("plain"), "plain")
        XCTAssertEqual(ConverseReply.messageOf(#"["array"]"#), #"["array"]"#)
    }

    func testAReplyThatNeverStoppedWasCutOff() throws {
        var reply = ConverseReply { type, message in FrameError(type: type, message: message) }
        XCTAssertThrowsError(try reply.finish()) { error in
            guard case LLMError.sse(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "the server closed the connection without replying")
        }
        _ = try reply.handle(decode(EventStreamFrames.textDelta(0, "par")))
        XCTAssertThrowsError(try reply.finish()) { error in
            guard case LLMError.sse(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "the reply was cut off before it finished")
        }
    }

    func testContextWindowExceededIsAnOverflowWithNoLimit() throws {
        XCTAssertThrowsError(try run(EventStreamFrames.textDelta(0, "x"), EventStreamFrames.stop("model_context_window_exceeded"))) { error in
            guard case LLMError.overflow(let limit, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(limit, 0)
            XCTAssertTrue(detail.contains("model_context_window_exceeded"))
        }
    }
}
