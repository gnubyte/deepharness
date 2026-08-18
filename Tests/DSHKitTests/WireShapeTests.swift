import XCTest
@testable import DSHKit

/// Tests over wire shapes captured from a live harness.
///
/// Every fixture here is a real frame or event body, not an invented one —
/// four decoding bugs in this client came from guessing shapes, so the shapes
/// are pinned.
final class WireShapeTests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: raw.data(using: .utf8)!)
    }

    private func frame(_ raw: String) -> Frame {
        let decoded = try! JSONDecoder().decode(ServerRequestFrame.self, from: raw.data(using: .utf8)!)
        return Frame(rpcId: decoded.rpcId, method: decoded.method, payload: decoded.payload)
    }

    // MARK: - Streaming

    func testStreamingChunksAssembleIntoOneMessage() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"step/start","seq":2,"data":{"turn":1,"step":1}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":3,"data":{"turn":1,"step":1,"chunk":{"type":"block-start","index":0,"blockType":"text"}}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":4,"data":{"turn":1,"step":1,"chunk":{"type":"text-delta","index":0,"text":"Hel"}}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":5,"data":{"turn":1,"step":1,"chunk":{"type":"text-delta","index":0,"text":"lo"}}}"#))

        XCTAssertEqual(a.items.count, 1)
        XCTAssertEqual(a.items[0].text, "Hello")
        XCTAssertTrue(a.items[0].streaming)

        a.apply(event: json(#"{"type":"assistant/chunk","seq":6,"data":{"turn":1,"step":1,"chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"Hello"}}}}"#))
        XCTAssertFalse(a.items[0].streaming, "block-end must seal the streaming flag")

        a.apply(event: json(#"{"type":"assistant/chunk","seq":7,"data":{"turn":1,"step":1,"chunk":{"type":"usage","usage":{"inputTokens":4096,"outputTokens":58}}}}"#))
        XCTAssertEqual(a.usage.inputTokens, 4096)
        XCTAssertEqual(a.usage.outputTokens, 58)
    }

    /// `assistant/message` nests the message under `data.message`; reading
    /// `data.content` yields nothing and the reply vanishes.
    func testCommittedAssistantMessageNestsUnderData() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"step/start","seq":2,"data":{"turn":1,"step":1}}"#))
        a.apply(event: json(#"""
        {"type":"assistant/message","seq":55,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"committed"}],"id":"m-1"},"usage":{"inputTokens":10,"outputTokens":3}}}
        """#))
        XCTAssertEqual(a.items.count, 1)
        XCTAssertEqual(a.items[0].text, "committed")
        XCTAssertEqual(a.usage.outputTokens, 3)
    }

    /// The committed message must land where the stream was, not at the tail.
    func testCommittedMessageKeepsStreamingPosition() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"step/start","seq":2,"data":{"turn":1,"step":1}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":10,"data":{"turn":1,"step":1,"chunk":{"type":"block-start","index":0,"blockType":"text"}}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":11,"data":{"turn":1,"step":1,"chunk":{"type":"text-delta","index":0,"text":"hi"}}}"#))
        a.apply(event: json(#"{"type":"tool/call","seq":12,"data":{"turn":1,"step":1,"callId":"c1","name":"write","arguments":"{}"}}"#))
        a.apply(event: json(#"{"type":"assistant/message","seq":99,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"id":"m-1"}}}"#))

        XCTAssertEqual(a.items.map(\.kind.debugLabel), ["assistant", "toolCall"],
                       "the committed message must stay before the tool call it preceded")
    }

    // MARK: - User messages

    /// Only `source.kind == "user"` is a human prompt; the rest are runtime
    /// context injections that are model-visible but were never typed.
    func testRuntimeContextInjectionsAreNotUserTurns() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"user/message","seq":7,"data":{"content":[{"type":"text","text":"real"}],"source":{"kind":"user"},"role":"user","id":"u1"}}"#))
        a.apply(event: json(#"{"type":"user/message","seq":8,"data":{"content":[{"type":"text","text":"<system-reminder>"}],"source":{"kind":"agent-instructions"},"role":"user","id":"u2"}}"#))
        a.apply(event: json(#"{"type":"user/message","seq":9,"data":{"content":[{"type":"text","text":"ctx"}],"source":{"kind":"plugin"},"role":"user","id":"u3"}}"#))
        a.apply(event: json(#"{"type":"user/message","seq":10,"data":{"content":[{"type":"text","text":"skills"}],"source":{"kind":"skill-catalog"},"role":"user","id":"u4"}}"#))

        XCTAssertEqual(a.items.count, 1)
        XCTAssertEqual(a.items[0].text, "real")
    }

    // MARK: - Tools

    /// `tool/call.arguments` is a JSON *string*, and `tool/result` nests under
    /// `data.message.content[]` with no tool name — correlate on callId.
    func testToolResultCorrelatesByCallIdAndSurfacesErrors() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"tool/call","seq":180,"data":{"turn":2,"step":1,"callId":"call_v8","name":"write","arguments":"{\"file_path\":\"/tmp/x\"}"}}"#))
        a.apply(event: json(#"""
        {"type":"tool/result","seq":181,"data":{"turn":2,"step":1,"message":{"source":{"kind":"tool","callId":"call_v8"},"content":[{"type":"tool-result","toolCallId":"call_v8","content":[{"type":"text","text":"Error: invalid escalation"}],"isError":true}],"role":"user","id":"b23"}}}
        """#))

        XCTAssertEqual(a.items.count, 2)
        XCTAssertTrue(a.items[0].text.contains("file_path"), "arguments must be parsed from the JSON string")
        XCTAssertEqual(a.items[1].kind.debugLabel, "notice", "an isError result must render as a notice")
        XCTAssertTrue(a.items[1].text.contains("write"), "the result must name the tool via callId correlation")
        XCTAssertTrue(a.items[1].text.contains("invalid escalation"))
    }

    // MARK: - History

    /// History wraps each event as `{event: …}`; the mux stream does not.
    func testHistoryEntriesAreUnwrapped() {
        var a = TranscriptAssembler()
        a.applyHistoryEntry(json(#"{"event":{"type":"user/message","seq":7,"data":{"content":[{"type":"text","text":"from history"}],"source":{"kind":"user"},"role":"user","id":"u1"}}}"#))
        XCTAssertEqual(a.items.count, 1)
        XCTAssertEqual(a.items[0].text, "from history")
    }

    // MARK: - Answerable frames

    func testApprovalFrameDecodes() {
        let f = frame(#"""
        {"type":"server-request","rpcId":"rpc-approval-1","method":"approval/requested","payload":{"type":"approval/requested","sessionId":"session-1","approvalId":"appr-9","toolName":"bash","callId":"c1","reason":"writes outside the workspace"}}
        """#)
        let approval = PendingApproval(frame: f)
        XCTAssertNotNil(approval)
        XCTAssertEqual(approval?.rpcId.raw, "rpc-approval-1", "the answer must echo this rpcId")
        XCTAssertEqual(approval?.approvalId, "appr-9")
        XCTAssertEqual(approval?.toolName, "bash")
        XCTAssertEqual(approval?.reason, "writes outside the workspace")
    }

    func testQuestionFrameDecodesOptionsAndMultiSelect() {
        let f = frame(#"""
        {"type":"server-request","rpcId":"rpc-q-1","method":"question/requested","payload":{"type":"question/requested","sessionId":"session-1","questions":[{"id":"q1","question":"Which approach?","header":"Approach","detail":"pick one","options":[{"label":"A","description":"first"},{"label":"B"}],"multiSelect":false},{"id":"q2","question":"Which files?","options":[{"label":"x"}],"multiSelect":true}]}}
        """#)
        let pending = PendingQuestions(frame: f)
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.rpcId.raw, "rpc-q-1")
        XCTAssertEqual(pending?.items.count, 2)
        XCTAssertEqual(pending?.items[0].options.map(\.label), ["A", "B"])
        XCTAssertEqual(pending?.items[0].options[0].description, "first")
        XCTAssertEqual(pending?.items[0].multiSelect, false)
        XCTAssertEqual(pending?.items[1].multiSelect, true)
    }

    /// The response envelope must echo the rpcId and never mint a new one.
    func testClientResponseEnvelopeEchoesRpcId() throws {
        let envelope = ClientResponse(
            rpcId: RpcId("rpc-approval-1"),
            result: .init(value: ["sessionId": "s1", "approvalId": "a1", "outcome": "allowed-once"])
        )
        let data = try JSONEncoder().encode(envelope)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(back["type"]?.stringValue, "client-response")
        XCTAssertEqual(back["rpcId"]?.stringValue, "rpc-approval-1")
        XCTAssertEqual(back.path("result", "ok")?.boolValue, true)
        XCTAssertEqual(back.path("result", "value", "outcome")?.stringValue, "allowed-once")
    }

    // MARK: - Queue

    /// The queue snapshot is authoritative and carries placements that render
    /// on different surfaces; `context` items are never shown.
    func testQueueItemPlacements() {
        let raw = json(#"""
        [{"id":"m1","placement":"queued","message":{"content":[{"type":"text","text":"later"}],"role":"user","id":"m1"}},
         {"id":"m2","placement":"steering","message":{"content":[{"type":"text","text":"now"}],"role":"user","id":"m2"}},
         {"id":"m3","placement":"context","message":{"content":[{"type":"text","text":"hidden"}],"role":"user","id":"m3"}}]
        """#)
        let items = (raw.arrayValue ?? []).compactMap(QueuedItem.init)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].placement, .queued)
        XCTAssertEqual(items[0].text, "later")
        XCTAssertEqual(items[1].placement, .steering)
        XCTAssertEqual(items[2].placement, .context)
    }

    // MARK: - Subagents

    func testSubagentCatalogDecodesBothRowKinds() {
        let raw = json(#"""
        [{"kind":"child","id":"s-1","activity":"running","hasChildren":false,"mode":"continuable","label":"Reviewer"},
         {"kind":"child","id":"s-2","activity":"inactive","hasChildren":true,"mode":"one-shot"},
         {"kind":"diagnostic","id":"s-3","reason":"corrupt"}]
        """#)
        let entries = (raw.arrayValue ?? []).compactMap(SubagentEntry.init)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries[0].isContinuable)
        XCTAssertTrue(entries[0].running)
        XCTAssertEqual(entries[0].title, "Reviewer")
        XCTAssertFalse(entries[1].isContinuable)
        XCTAssertEqual(entries[2].title, "Unavailable (corrupt)")
    }

    // MARK: - Workspaces and search

    func testWorkspaceDecodes() {
        let ws = Workspace(json(#"""
        {"workspaceId":"w1","path":"/tmp/proj","title":"Proj","sessionIds":["a","b"],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"}
        """#))
        XCTAssertEqual(ws?.id, "w1")
        XCTAssertEqual(ws?.sessionIds, ["a", "b"])
    }

    func testSearchHitDecodes() {
        let hit = SearchHit(json(#"{"sessionId":"s1","snippet":"hello there"}"#))
        XCTAssertEqual(hit?.sessionId, "s1")
        XCTAssertEqual(hit?.snippet, "hello there")
    }

    // MARK: - Markdown

    func testMarkdownBlockParsing() {
        let blocks = Markdown.parse("""
        # Title

        Some **bold** text.

        ```swift
        let x = 1
        ```

        - one
        - two

        > quoted
        """)
        XCTAssertEqual(blocks.map(\.debugLabel), ["heading", "paragraph", "code", "list", "list", "quote"])
        if case .code(let language, let text) = blocks[2] {
            XCTAssertEqual(language, "swift")
            XCTAssertEqual(text, "let x = 1")
        } else {
            XCTFail("expected a fenced code block")
        }
    }

    /// A response still streaming has an unterminated fence; it should render
    /// as code rather than showing raw backticks.
    func testUnterminatedFenceStillClosesAtEndOfInput() {
        let blocks = Markdown.parse("```json\n{\"a\":1}")
        XCTAssertEqual(blocks.count, 1)
        if case .code(let language, let text) = blocks[0] {
            XCTAssertEqual(language, "json")
            XCTAssertEqual(text, "{\"a\":1}")
        } else {
            XCTFail("expected a fenced code block")
        }
    }

    // MARK: - Errors

    func testBusinessErrorDecodesFromA200Body() throws {
        let data = #"""
        {"type":"server-response","rpcId":"r1","result":{"ok":false,"error":{"code":"attachment-error","message":"Model does not support image input.","details":{"reason":"MODEL_DOES_NOT_SUPPORT_IMAGES"}}}}
        """#.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(ServerResponse.self, from: data)
        XCTAssertThrowsError(try envelope.result.unwrap()) { error in
            let rpc = error as? RpcError
            XCTAssertEqual(rpc?.code, "attachment-error")
            XCTAssertEqual(rpc?.details?["reason"]?.stringValue, "MODEL_DOES_NOT_SUPPORT_IMAGES")
        }
    }
}

// MARK: - Test helpers

private extension TranscriptItem.Kind {
    var debugLabel: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .reasoning: "reasoning"
        case .toolCall: "toolCall"
        case .toolResult: "toolResult"
        case .notice: "notice"
        }
    }
}

private extension MarkdownBlock {
    var debugLabel: String {
        switch self {
        case .paragraph: "paragraph"
        case .heading: "heading"
        case .code: "code"
        case .listItem: "list"
        case .quote: "quote"
        case .rule: "rule"
        }
    }
}
