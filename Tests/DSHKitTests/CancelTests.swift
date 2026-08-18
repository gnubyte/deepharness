import XCTest
@testable import DSHKit

/// Cancellation semantics, pinned against shapes captured from a live harness.
///
/// A stop that silently does nothing is the worst failure mode here, so these
/// cover both the wire contract and the transcript's reading of the outcome.
final class CancelTests: XCTestCase {

    private func json(_ raw: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: raw.data(using: .utf8)!)
    }

    /// A cancelled turn ends with `aborted`, distinct from a completed one.
    /// The transcript must not report it as an error the user has to act on.
    func testAbortedTurnIsNotAnError() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        XCTAssertTrue(a.running)

        a.apply(event: json(#"{"type":"turn/end","seq":2,"data":{"turn":1,"reason":{"kind":"aborted"}}}"#))
        XCTAssertFalse(a.running, "an aborted turn must clear the running flag")
        XCTAssertNil(a.lastError, "a user-requested stop is not a failure")
        XCTAssertFalse(
            a.items.contains { if case .notice = $0.kind { return true } else { return false } },
            "stopping must not leave an error notice in the transcript"
        )
    }

    /// A turn that genuinely failed still surfaces, so a stop and a crash are
    /// not confused for one another.
    func testErroredTurnStillSurfaces() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json("""
        {"type":"turn/end","seq":2,"data":{"turn":1,"reason":{"kind":"error","error":{"message":"No API key for provider: ollama-local","code":"PI_AI_ERROR"}}}}
        """))
        XCTAssertFalse(a.running)
        XCTAssertEqual(a.lastError, "No API key for provider: ollama-local")
    }

    /// Streaming blocks left open when a stop lands must be sealed, or the UI
    /// keeps a spinner on a message that will never receive another delta.
    func testStopSealsAnOpenStreamingBlock() {
        var a = TranscriptAssembler()
        a.apply(event: json(#"{"type":"turn/start","seq":1,"data":{"turn":1}}"#))
        a.apply(event: json(#"{"type":"step/start","seq":2,"data":{"turn":1,"step":1}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":3,"data":{"turn":1,"step":1,"chunk":{"type":"block-start","index":0,"blockType":"text"}}}"#))
        a.apply(event: json(#"{"type":"assistant/chunk","seq":4,"data":{"turn":1,"step":1,"chunk":{"type":"text-delta","index":0,"text":"half a sen"}}}"#))
        XCTAssertTrue(a.items.contains { $0.streaming })

        // No block-end arrives — the turn is aborted mid-stream.
        a.apply(event: json(#"{"type":"turn/end","seq":5,"data":{"turn":1,"reason":{"kind":"aborted"}}}"#))

        XCTAssertFalse(
            a.items.contains { $0.streaming },
            "an aborted turn must seal open blocks so no spinner is left running"
        )
        XCTAssertEqual(a.items.first?.text, "half a sen", "partial text is kept, not discarded")
    }

    /// The cancel reply is a plain acceptance; the stop is confirmed later by
    /// the status flip, not by this response.
    func testCancelResponseIsAnAcceptance() throws {
        let data = #"{"type":"server-response","rpcId":"c1","result":{"ok":true,"value":{"accepted":true}}}"#
            .data(using: .utf8)!
        let envelope = try JSONDecoder().decode(ServerResponse.self, from: data)
        let value = try envelope.result.unwrap()
        XCTAssertEqual(value["accepted"]?.boolValue, true)
    }

    /// A subagent session refuses cancel with `agent-busy`, which must reach
    /// the caller rather than being swallowed.
    func testCancelRefusalSurfacesAsAnError() throws {
        let data = """
        {"type":"server-response","rpcId":"c2","result":{"ok":false,"error":{"code":"agent-busy","message":"session-backed subagents cannot be cancelled directly","details":{"reason":"subagent"}}}}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(ServerResponse.self, from: data)
        XCTAssertThrowsError(try envelope.result.unwrap()) { error in
            XCTAssertEqual((error as? RpcError)?.code, "agent-busy")
        }
    }

    /// `host/session-status` is the authoritative end of a stop.
    func testStatusFrameCarriesTheRunningFlag() {
        let raw = """
        {"type":"server-request","rpcId":"r1","method":"host/session-status","payload":{"type":"host/session-status","sessionId":"session-1","running":false}}
        """
        let decoded = try! JSONDecoder().decode(ServerRequestFrame.self, from: raw.data(using: .utf8)!)
        let frame = Frame(rpcId: decoded.rpcId, method: decoded.method, payload: decoded.payload)
        XCTAssertEqual(frame.type, "host/session-status")
        XCTAssertEqual(frame.sessionId, "session-1")
        XCTAssertEqual(frame.payload["running"]?.boolValue, false)
    }
}
