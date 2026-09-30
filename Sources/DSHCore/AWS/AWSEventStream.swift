import Foundation

// MARK: - AWS event stream (application/vnd.amazon.eventstream)
//
// Bedrock's ConverseStream answers with binary frames rather than SSE. Each frame:
//
//   total length (u32) | headers length (u32) | prelude CRC (u32, over the first 8 bytes)
//   headers: name length (u8), name, type (u8), value (size depends on the type)
//   payload (total - headers - 16 bytes; JSON for Bedrock)
//   message CRC (u32, over everything before it)
//
// All integers are big-endian and the CRCs are CRC-32/IEEE. The :message-type header says whether
// a frame is an event (its :event-type names the ConverseStreamOutput member), an exception
// (modelled: :exception-type, e.g. throttlingException) or an error (unmodelled: :error-code,
// :error-message).

/// One decoded event-stream frame: its string-valued headers and raw payload.
public struct AWSEventMessage: Sendable, Equatable {
    public let headers: [String: String]
    public let payload: Data

    public init(headers: [String: String], payload: Data) {
        self.headers = headers
        self.payload = payload
    }

    /// "event", "exception" or "error".
    public var messageType: String? { headers[":message-type"] }
    public var eventType: String? { headers[":event-type"] }
    public var exceptionType: String? { headers[":exception-type"] }
    public var payloadText: String { String(decoding: payload, as: UTF8.self) }
}

/// A frame that fails its checks, or a stream that ends inside one.
public struct AWSEventStreamError: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Incremental decoder: feed it whatever bytes arrive (a frame may straddle any
/// number of reads) and it hands back each frame as soon as it is whole.
public struct AWSEventStreamParser: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0
    /// The current frame's total length once its prelude has been read and checked.
    private var expectedTotal: Int?

    public init() {}

    /// Bytes received that do not yet make up a whole frame.
    public var pendingBytes: Int { buffer.count - head }

    /// Append bytes; every frame that is now complete comes back, in order.
    public mutating func append<S: Sequence>(_ bytes: S) throws -> [AWSEventMessage] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var frames: [AWSEventMessage] = []
        while let frame = try nextFrame() { frames.append(frame) }
        compact()
        return frames
    }

    /// Call when the stream ends: a stream that ends inside a frame is an error.
    public func finish() throws {
        if pendingBytes > 0 { throw AWSEventStreamError("The event stream ended inside a frame.") }
    }

    private mutating func nextFrame() throws -> AWSEventMessage? {
        if expectedTotal == nil {
            guard pendingBytes >= AWSEventStream.preludeLength else { return nil }
            let prelude = Array(buffer[head..<(head + AWSEventStream.preludeLength)])
            expectedTotal = try AWSEventStream.checkPrelude(prelude)
        }
        guard let total = expectedTotal, pendingBytes >= total else { return nil }
        let frame = Array(buffer[head..<(head + total)])
        head += total
        expectedTotal = nil
        return try AWSEventStream.decode(frame)
    }

    private mutating func compact() {
        // Drop consumed bytes once they outweigh what is left, so a long stream
        // doesn't grow the buffer without bound or copy it on every frame.
        if head > 0, head >= buffer.count / 2 {
            buffer.removeFirst(head)
            head = 0
        }
    }
}

public enum AWSEventStream {
    static let preludeLength = 12
    /// botocore's limits; anything larger is a corrupt length, not a real frame.
    static let maxHeadersLength = 128 * 1024
    static let maxPayloadLength = 24 * 1024 * 1024

    /// Frames from a byte stream as they arrive. Ends quietly when the stream
    /// ends between frames; a stream that ends inside a frame, or a frame that
    /// fails its checks, throws `AWSEventStreamError`.
    public static func frames<S: AsyncSequence & Sendable>(from bytes: S) -> AsyncThrowingStream<AWSEventMessage, Error>
    where S.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var parser = AWSEventStreamParser()
                do {
                    for try await byte in bytes {
                        for frame in try parser.append(CollectionOfOne(byte)) { continuation.yield(frame) }
                    }
                    try parser.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode exactly one whole frame.
    public static func decode(_ frame: [UInt8]) throws -> AWSEventMessage {
        guard frame.count >= preludeLength else { throw AWSEventStreamError("Event-stream frame too short.") }
        let total = try checkPrelude(Array(frame[0..<preludeLength]))
        guard frame.count == total else {
            throw AWSEventStreamError("Event-stream frame is \(frame.count) bytes, its prelude says \(total).")
        }
        let expected = readUInt32(frame, at: total - 4)
        let actual = CRC32.compute(frame[0..<(total - 4)])
        guard expected == actual else {
            throw AWSEventStreamError("Event-stream message checksum mismatch (expected 0x\(hex32(expected)), got 0x\(hex32(actual))).")
        }
        let headersLength = Int(readUInt32(frame, at: 4))
        let headers = try parseHeaders(Array(frame[preludeLength..<(preludeLength + headersLength)]))
        let payload = Data(frame[(preludeLength + headersLength)..<(total - 4)])
        return AWSEventMessage(headers: headers, payload: payload)
    }

    public static func decode(_ frame: Data) throws -> AWSEventMessage { try decode([UInt8](frame)) }

    /// Validate a prelude; the frame's total length.
    static func checkPrelude(_ prelude: [UInt8]) throws -> Int {
        let total = readUInt32(prelude, at: 0)
        let headersLength = readUInt32(prelude, at: 4)
        let expected = readUInt32(prelude, at: 8)
        let actual = CRC32.compute(prelude[0..<8])
        guard expected == actual else {
            throw AWSEventStreamError("Event-stream prelude checksum mismatch (expected 0x\(hex32(expected)), got 0x\(hex32(actual))).")
        }
        let overhead = UInt64(preludeLength) + 4 + UInt64(headersLength)
        guard headersLength <= UInt32(maxHeadersLength), UInt64(total) >= overhead,
              UInt64(total) - overhead <= UInt64(maxPayloadLength) else {
            throw AWSEventStreamError("Event-stream frame has impossible lengths (total \(total), headers \(headersLength)).")
        }
        return Int(total)
    }

    /// The string headers (type 7). Every other type is skipped by its size:
    /// 0/1 booleans (no value), 2 int8, 3 int16, 4 int32, 5 int64, 6 bytes
    /// (u16 length), 8 timestamp (int64), 9 UUID.
    private static func parseHeaders(_ data: [UInt8]) throws -> [String: String] {
        var headers: [String: String] = [:]
        var at = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard at + count <= data.count else { throw AWSEventStreamError("Event-stream headers are truncated.") }
            defer { at += count }
            return data[at..<(at + count)]
        }
        while at < data.count {
            let nameLength = Int(try take(1).first!)
            let name = String(decoding: try take(nameLength), as: UTF8.self)
            let type = try take(1).first!
            switch type {
            case 0, 1: break
            case 2: _ = try take(1)
            case 3: _ = try take(2)
            case 4: _ = try take(4)
            case 5, 8: _ = try take(8)
            case 9: _ = try take(16)
            case 6, 7:
                let lengthBytes = try take(2)
                let length = Int(lengthBytes[lengthBytes.startIndex]) << 8 | Int(lengthBytes[lengthBytes.startIndex + 1])
                let value = try take(length)
                if type == 7 { headers[name] = String(decoding: value, as: UTF8.self) }
            default:
                throw AWSEventStreamError("Event-stream header '\(name)' has unknown type \(type).")
            }
        }
        return headers
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func hex32(_ value: UInt32) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }
}

/// CRC-32/IEEE (the zip/PNG polynomial, reflected), table-driven.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func compute<S: Sequence>(_ data: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}
