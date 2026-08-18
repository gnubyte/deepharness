import XCTest
@testable import DSHKit

final class TelemetryTests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: raw.data(using: .utf8)!)
    }

    // MARK: - Context

    func testContextPressureFromLiveProjection() {
        let p = ContextPressure(json(#"{"pressureTokens":4096,"projectedTokens":4182,"contextWindow":32768}"#))
        XCTAssertEqual(p?.contextWindow, 32768)
        XCTAssertEqual(p?.remainingTokens, 28672)
        XCTAssertEqual(p?.usedFraction ?? 0, 0.125, accuracy: 0.001)
        XCTAssertEqual(p?.level, .comfortable)
    }

    /// A zero or missing window would make every fraction meaningless, so the
    /// projection is rejected rather than rendered as a divide-by-zero gauge.
    func testContextPressureRejectsUnusableWindow() {
        XCTAssertNil(ContextPressure(json(#"{"pressureTokens":10,"contextWindow":0}"#)))
        XCTAssertNil(ContextPressure(json(#"{"pressureTokens":10}"#)))
        XCTAssertNil(ContextPressure(nil))
    }

    func testContextLevelsEscalate() {
        func level(_ used: Int, _ window: Int) -> ContextPressure.Level? {
            ContextPressure(json(#"{"pressureTokens":\#(used),"projectedTokens":\#(used),"contextWindow":\#(window)}"#))?.level
        }
        XCTAssertEqual(level(1_000, 10_000), .comfortable)
        XCTAssertEqual(level(7_500, 10_000), .tight)
        XCTAssertEqual(level(9_500, 10_000), .critical)
    }

    /// Fractions clamp so a projection that overshoots the window cannot draw
    /// an arc past full.
    func testFractionsClamp() {
        let p = ContextPressure(json(#"{"pressureTokens":50000,"projectedTokens":60000,"contextWindow":32768}"#))
        XCTAssertEqual(p?.usedFraction, 1)
        XCTAssertEqual(p?.projectedFraction, 1)
        XCTAssertEqual(p?.remainingTokens, 0)
    }

    func testContextBreakdownTotals() {
        let b = ContextBreakdown(json(#"{"systemTokens":1517,"toolsTokens":6376,"messageTokens":12259}"#))
        XCTAssertEqual(b?.total, 20152)
    }

    func testTokenUsageCountsCachedInput() {
        let u = TokenUsage(json(#"{"uncachedInputTokens":12288,"outputTokens":150,"cacheReadTokens":2048,"cacheWriteTokens":512}"#))
        XCTAssertEqual(u?.totalInput, 14336)
        XCTAssertEqual(u?.outputTokens, 150)
    }

    func testDecodeSpeedNeedsBothSignals() {
        let good = SessionStats(json(#"{"turns":1,"decodeMs":1000,"decodeTokens":50}"#))
        XCTAssertEqual(good?.tokensPerSecond ?? 0, 50, accuracy: 0.001)
        let noTime = SessionStats(json(#"{"turns":1,"decodeMs":0,"decodeTokens":50}"#))
        XCTAssertNil(noTime?.tokensPerSecond)
    }

    // MARK: - Permissions

    func testPermissionStateFromLiveProjection() {
        let p = PermissionState(json("""
        {"options":[{"value":"read-only","name":"read-only"},{"value":"workspace-write","name":"workspace-write"},{"value":"danger-full-access","name":"danger-full-access"}],"currentValue":"workspace-write"}
        """))
        XCTAssertEqual(p?.options.count, 3)
        XCTAssertEqual(p?.displayName, "Workspace Write")
        XCTAssertEqual(p?.options.map(\.displayName), ["Read Only", "Workspace Write", "Danger Full Access"])
        XCTAssertEqual(p?.isFullAccess, false)
    }

    func testFullAccessIsRecognised() {
        let p = PermissionState(json(#"{"options":[],"currentValue":"danger-full-access"}"#))
        XCTAssertEqual(p?.isFullAccess, true)
    }

    // MARK: - Formatting

    func testTokenFormatting() {
        XCTAssertEqual(formatTokens(0), "0")
        XCTAssertEqual(formatTokens(999), "999")
        XCTAssertEqual(formatTokens(4096), "4.1k")
        XCTAssertEqual(formatTokens(32768), "32k")
        XCTAssertEqual(formatTokens(1_500_000), "1.5M")
    }
}

/// Produced-file detection, which drives the files shown to the user.
final class ProducedFilesTests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: raw.data(using: .utf8)!)
    }

    /// The real diff-card intent captured from a live write call.
    private let diffIntent = """
    {"for":"call","view":{"card":"diff","title":"Write /p/notes.md","diffs":[{"path":"/p/notes.md","oldText":null,"newText":""}],"locations":[{"path":"/p/notes.md"}]}}
    """

    func testDiffCardIsAMutation() {
        XCTAssertEqual(TranscriptAssembler.mutatedPaths(json(diffIntent)), ["/p/notes.md"])
    }

    func testGenericEditCardIsAMutation() {
        let intent = json(#"{"for":"call","view":{"card":"generic","kind":"edit","title":"Insert","locations":[{"path":"/p/a.txt"}]}}"#)
        XCTAssertEqual(TranscriptAssembler.mutatedPaths(intent), ["/p/a.txt"])
    }

    /// Reads carry `locations` too — they must not count as produced files.
    func testReadCardIsNotAMutation() {
        let intent = json(#"{"for":"call","view":{"card":"generic","kind":"read","title":"Read","locations":[{"path":"/p/a.txt"}]}}"#)
        XCTAssertTrue(TranscriptAssembler.mutatedPaths(intent).isEmpty)
    }

    func testResultIntentIsNotACall() {
        let intent = json(#"{"for":"result","view":{"card":"diff","diffs":[{"path":"/p/a.txt"}]}}"#)
        XCTAssertTrue(TranscriptAssembler.mutatedPaths(intent).isEmpty)
    }

    /// A file only counts once the call actually succeeds.
    func testFailedMutationProducesNothing() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"tool/call","seq":2,"data":{"turn":1,"step":1,"callId":"c1","name":"write","arguments":"{}"}}"#), view: json(diffIntent))
        a.apply(event: json("""
        {"type":"tool/result","seq":3,"data":{"turn":1,"step":1,"message":{"source":{"kind":"tool","callId":"c1"},"content":[{"type":"tool-result","toolCallId":"c1","content":[{"type":"text","text":"Error: denied"}],"isError":true}],"role":"user","id":"r1"}}}
        """))
        XCTAssertTrue(a.producedFiles(turn: 1).isEmpty)
    }

    func testSuccessfulMutationProducesTheFile() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"tool/call","seq":2,"data":{"turn":1,"step":1,"callId":"c1","name":"write","arguments":"{}"}}"#), view: json(diffIntent))
        a.apply(event: json("""
        {"type":"tool/result","seq":3,"data":{"turn":1,"step":1,"message":{"source":{"kind":"tool","callId":"c1"},"content":[{"type":"tool-result","toolCallId":"c1","content":[{"type":"text","text":"Created file"}]}],"role":"user","id":"r1"}}}
        """))
        XCTAssertEqual(a.producedFiles(turn: 1), ["/p/notes.md"])
    }

    /// A path appears once per turn, in first-seen order.
    func testDuplicatePathsCollapsePerTurn() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        for (index, callId) in ["c1", "c2"].enumerated() {
            a.apply(
                event: json(#"{"type":"tool/call","seq":\#(2 + index * 2),"data":{"turn":1,"step":1,"callId":"\#(callId)","name":"write","arguments":"{}"}}"#),
                view: json(diffIntent)
            )
            a.apply(event: json("""
            {"type":"tool/result","seq":\(3 + index * 2),"data":{"turn":1,"step":1,"message":{"source":{"kind":"tool","callId":"\(callId)"},"content":[{"type":"tool-result","toolCallId":"\(callId)","content":[{"type":"text","text":"ok"}]}],"role":"user","id":"r"}}}
            """))
        }
        XCTAssertEqual(a.producedFiles(turn: 1), ["/p/notes.md"])
    }

    /// Turns keep separate lists so one turn's row cannot spill into the next.
    func testTurnsAreSeparate() {
        var a = TranscriptAssembler()
        for turn in 1...2 {
            a.apply(event: json(#"{"type":"turn/start","seq":\#(turn * 10),"data":{"turn":\#(turn)}}"#))
            let intent = """
            {"for":"call","view":{"card":"diff","title":"Write","diffs":[{"path":"/p/turn\(turn).txt","oldText":null,"newText":""}]}}
            """
            a.apply(
                event: json(#"{"type":"tool/call","seq":\#(turn * 10 + 1),"data":{"turn":\#(turn),"step":1,"callId":"c\#(turn)","name":"write","arguments":"{}"}}"#),
                view: json(intent)
            )
            a.apply(event: json("""
            {"type":"tool/result","seq":\(turn * 10 + 2),"data":{"turn":\(turn),"step":1,"message":{"source":{"kind":"tool","callId":"c\(turn)"},"content":[{"type":"tool-result","toolCallId":"c\(turn)","content":[{"type":"text","text":"ok"}]}],"role":"user","id":"r"}}}
            """))
        }
        XCTAssertEqual(a.producedFiles(turn: 1), ["/p/turn1.txt"])
        XCTAssertEqual(a.producedFiles(turn: 2), ["/p/turn2.txt"])
    }
}
