import Foundation
@testable import DSHCore

/// Builds application/vnd.amazon.eventstream frames and Bedrock ConverseStream events. The encoder
/// (and its bit-by-bit CRC) is independent of the decoder under test; `AWSEventStreamTests` checks
/// it against a frame botocore decoded.
enum EventStreamFrames {
    static func frame(_ headers: [(String, String)], payload: Data) -> [UInt8] {
        var head: [UInt8] = []
        for (name, value) in headers {
            let n = Array(name.utf8), v = Array(value.utf8)
            head.append(UInt8(n.count))
            head += n
            head.append(7)
            head.append(UInt8(v.count >> 8))
            head.append(UInt8(v.count & 0xFF))
            head += v
        }
        let total = 12 + head.count + payload.count + 4
        var frame = [UInt8](repeating: 0, count: total)
        put(&frame, at: 0, UInt32(total))
        put(&frame, at: 4, UInt32(head.count))
        put(&frame, at: 8, crc(frame[0..<8]))
        frame.replaceSubrange(12..<(12 + head.count), with: head)
        frame.replaceSubrange((12 + head.count)..<(12 + head.count + payload.count), with: payload)
        put(&frame, at: total - 4, crc(frame[0..<(total - 4)]))
        return frame
    }

    private static func put(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }

    /// CRC-32/IEEE, one bit at a time.
    private static func crc(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return ~crc
    }

    static func event(_ eventType: String, _ payload: JSONValue) -> [UInt8] {
        frame([(":event-type", eventType), (":content-type", "application/json"), (":message-type", "event")],
              payload: payload.serializedData())
    }

    static func exception(_ exceptionType: String, _ message: String) -> [UInt8] {
        frame([(":exception-type", exceptionType), (":content-type", "application/json"), (":message-type", "exception")],
              payload: JSONValue.object(["message": .string(message)]).serializedData())
    }

    // MARK: ConverseStream events

    static func messageStart() -> [UInt8] { event("messageStart", ["role": "assistant", "p": "abc"]) }

    static func textDelta(_ index: Int, _ text: String) -> [UInt8] {
        event("contentBlockDelta", ["contentBlockIndex": .number(Double(index)),
                                    "delta": ["text": .string(text)], "p": "abcdef"])
    }

    static func toolStart(_ index: Int, id: String, name: String) -> [UInt8] {
        event("contentBlockStart", ["contentBlockIndex": .number(Double(index)),
                                    "start": ["toolUse": ["toolUseId": .string(id), "name": .string(name)]]])
    }

    static func toolInput(_ index: Int, _ input: String) -> [UInt8] {
        event("contentBlockDelta", ["contentBlockIndex": .number(Double(index)),
                                    "delta": ["toolUse": ["input": .string(input)]]])
    }

    static func reasoning(_ index: Int, text: String? = nil, signature: String? = nil, redacted: String? = nil) -> [UInt8] {
        var fields: [String: JSONValue] = [:]
        if let text { fields["text"] = .string(text) }
        if let signature { fields["signature"] = .string(signature) }
        if let redacted { fields["redactedContent"] = .string(redacted) }
        return event("contentBlockDelta", ["contentBlockIndex": .number(Double(index)),
                                           "delta": ["reasoningContent": .object(fields)]])
    }

    static func blockStop(_ index: Int) -> [UInt8] {
        event("contentBlockStop", ["contentBlockIndex": .number(Double(index))])
    }

    static func stop(_ reason: String) -> [UInt8] { event("messageStop", ["stopReason": .string(reason)]) }

    static func metadata(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) -> [UInt8] {
        event("metadata", [
            "usage": ["inputTokens": .number(Double(input)), "outputTokens": .number(Double(output)),
                      "totalTokens": .number(Double(input + output)),
                      "cacheReadInputTokens": .number(Double(cacheRead)),
                      "cacheWriteInputTokens": .number(Double(cacheWrite))],
            "metrics": ["latencyMs": 123],
        ])
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(fromHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
