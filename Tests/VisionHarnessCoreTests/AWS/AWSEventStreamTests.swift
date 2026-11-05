import XCTest
@testable import VisionHarnessCore

/// The application/vnd.amazon.eventstream decoder: frames from botocore's own decoder, every header
/// type, frames split across reads, and corrupt or cut-off streams.
final class AWSEventStreamTests: XCTestCase {
    /// A contentBlockDelta event, as botocore's EventStreamBuffer decodes it.
    private static let deltaHex =
        "0000009f00000057c37babff0b3a6576656e742d74797065070011636f6e74656e74426c6f636b44656c74610d3a636f6e74656e742d74797065"
        + "0700106170706c69636174696f6e2f6a736f6e0d3a6d6573736167652d747970650700056576656e747b22636f6e74656e74426c6f636b496e"
        + "646578223a302c2264656c7461223a7b2274657874223a224869227d2c2270223a2261626364227df2ace5ff"

    /// A throttlingException frame whose headers use every type (true, false, int8, int16, int32,
    /// int64, bytes, timestamp, uuid) before the two string ones — also decoded by botocore.
    private static let mixedHex =
        "000000ae00000087d9e9e81d0174000166010162027f017303010201690401020304016c050102030405060708017906000378797a01640800"
        + "00019200000000017509000102030405060708090a0b0c0d0e0f0d3a6d6573736167652d74797065070009657863657074696f6e0f3a6578"
        + "63657074696f6e2d747970650700137468726f74746c696e67457863657074696f6e7b226d657373616765223a22736c6f7720646f776e22"
        + "7d82d4ac6b"

    private func parse(_ bytes: [UInt8], chunk: Int) throws -> [AWSEventMessage] {
        var parser = AWSEventStreamParser()
        var messages: [AWSEventMessage] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + chunk, bytes.count)
            messages += try parser.append(bytes[index..<end])
            index = end
        }
        try parser.finish()
        return messages
    }

    func testDecodesAFrameBotocoreDecodes() throws {
        let message = try AWSEventStream.decode(EventStreamFrames.bytes(fromHex: Self.deltaHex))
        XCTAssertEqual(message.messageType, "event")
        XCTAssertEqual(message.eventType, "contentBlockDelta")
        XCTAssertEqual(message.headers[":content-type"], "application/json")
        XCTAssertEqual(message.payloadText, #"{"contentBlockIndex":0,"delta":{"text":"Hi"},"p":"abcd"}"#)
    }

    func testTheTestEncoderProducesBotocoresBytes() {
        let frame = EventStreamFrames.frame(
            [(":event-type", "contentBlockDelta"), (":content-type", "application/json"), (":message-type", "event")],
            payload: Data(#"{"contentBlockIndex":0,"delta":{"text":"Hi"},"p":"abcd"}"#.utf8))
        XCTAssertEqual(EventStreamFrames.hex(frame), Self.deltaHex)
    }

    func testNonStringHeadersAreSkippedBySize() throws {
        let message = try AWSEventStream.decode(EventStreamFrames.bytes(fromHex: Self.mixedHex))
        XCTAssertEqual(message.headers.count, 2)
        XCTAssertEqual(message.messageType, "exception")
        XCTAssertEqual(message.exceptionType, "throttlingException")
        XCTAssertEqual(message.payloadText, #"{"message":"slow down"}"#)
    }

    func testFramesStraddlingReadsAreReassembled() throws {
        let bytes = EventStreamFrames.textDelta(0, "Hel")
            + EventStreamFrames.bytes(fromHex: Self.mixedHex)
            + EventStreamFrames.textDelta(0, "lo — ✓")
        for chunk in [1, 3, 7, 64, 100_000] {
            let messages = try parse(bytes, chunk: chunk)
            XCTAssertEqual(messages.count, 3, "chunk size \(chunk)")
            XCTAssertTrue(messages[0].payloadText.contains("Hel"))
            XCTAssertEqual(messages[1].exceptionType, "throttlingException")
            let text = JSONValue(parsing: messages[2].payload)?["delta"]?["text"]?.string
            XCTAssertEqual(text, "lo — ✓")
        }
    }

    func testEmptyStreamHasNoFrames() throws {
        XCTAssertEqual(try parse([], chunk: 8).count, 0)
    }

    func testPayloadCorruptionFailsTheMessageChecksum() {
        var frame = EventStreamFrames.bytes(fromHex: Self.deltaHex)
        frame[frame.count - 10] ^= 0x01
        XCTAssertThrowsError(try AWSEventStream.decode(frame)) { error in
            XCTAssertTrue(error.localizedDescription.contains("message checksum"), "\(error)")
        }
    }

    func testPreludeCorruptionFailsThePreludeChecksum() {
        var frame = EventStreamFrames.bytes(fromHex: Self.deltaHex)
        frame[5] ^= 0x01 // headers length
        XCTAssertThrowsError(try parse(frame, chunk: 1000)) { error in
            XCTAssertTrue(error.localizedDescription.contains("prelude checksum"), "\(error)")
        }
    }

    func testStreamCutInsideAFrameIsAnError() throws {
        let bytes = EventStreamFrames.textDelta(0, "Hello") + Array(EventStreamFrames.textDelta(0, "again")[..<20])
        var parser = AWSEventStreamParser()
        var messages: [AWSEventMessage] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + 7, bytes.count)
            messages += try parser.append(bytes[index..<end])
            index = end
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertThrowsError(try parser.finish()) { error in
            XCTAssertTrue(error.localizedDescription.contains("ended inside a frame"), "\(error)")
        }
    }

    func testImpossibleLengthsAreRefusedBeforeAnythingIsBuffered() {
        // A prelude with a VALID checksum that claims a 100 MB payload: refused on its lengths alone.
        var prelude: [UInt8] = [0x05, 0xF5, 0xE1, 0x00,   // total = 100,000,000
                                0x00, 0x00, 0x00, 0x00]   // headers = 0
        let crc = CRC32.compute(prelude)
        prelude += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        XCTAssertThrowsError(try parse(prelude, chunk: 12)) { error in
            XCTAssertTrue(error.localizedDescription.contains("impossible lengths"), "\(error)")
        }
    }

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(CRC32.compute(Array("123456789".utf8)), 0xCBF43926)
    }

    func testFramesFromAnAsyncByteSequence() async throws {
        let bytes = EventStreamFrames.textDelta(0, "Hel") + EventStreamFrames.textDelta(0, "lo")
        let source = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        var texts: [String] = []
        for try await message in AWSEventStream.frames(from: source) {
            if let text = JSONValue(parsing: message.payload)?["delta"]?["text"]?.string { texts.append(text) }
        }
        XCTAssertEqual(texts, ["Hel", "lo"])
    }

    func testAnAsyncStreamCutMidFrameThrows() async {
        let bytes = Array(EventStreamFrames.textDelta(0, "Hello").dropLast(3))
        let source = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        do {
            for try await _ in AWSEventStream.frames(from: source) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ended inside a frame"), "\(error)")
        }
    }
}
