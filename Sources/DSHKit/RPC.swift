import Foundation

/// Message correlation id. The initiator mints it; a response echoes it.
public struct RpcId: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func mint() -> RpcId { RpcId(UUID().uuidString) }
    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    public var description: String { raw }
}

/// A business-layer failure carried inside a 200 response.
///
/// HTTP status describes only the carrier (404 unknown path / 415 media type /
/// 400 bad body / 500 crash); every business error arrives as 200 + this.
public struct RpcError: Error, Codable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public let details: JSONValue?

    public var errorDescription: String? { "\(code): \(message)" }
}

/// Carrier-level failures — the transport itself could not deliver a business result.
public enum TransportError: Error, LocalizedError {
    case badStatus(Int, body: String)
    case malformedResponse(String)
    case notConnected
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badStatus(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        case .malformedResponse(let d): return "malformed response: \(d)"
        case .notConnected: return "not connected to a harness"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - Wire envelopes (the four-quadrant model)

/// Call initiated by the client. Wire carrier: `POST /api/<method>` body.
struct ClientRequest: Encodable {
    let type = "client-request"
    let rpcId: RpcId
    let method: String
    let payload: JSONValue
}

/// Response to a ClientRequest. Wire carrier: that POST's response body.
struct ServerResponse: Decodable {
    let type: String
    let rpcId: RpcId
    let result: RpcResult
}

/// Message initiated by the server. Wire carrier: a downstream stream frame.
struct ServerRequestFrame: Decodable {
    let type: String
    let rpcId: RpcId
    let method: String
    let payload: JSONValue
}

/// Answer to a ServerRequest. Wire carrier: `POST /api/respond` body.
///
/// The rpcId echoes the request's and is never minted anew — that echo is the
/// entire correlation, which is why answerable frames expose their rpcId.
struct ClientResponse: Encodable {
    let type = "client-response"
    let rpcId: RpcId
    let result: OkResult

    struct OkResult: Encodable {
        let ok = true
        let value: JSONValue
    }
}

/// Carrier receipt for a client-response — not an RpcMessage.
///
/// A late or duplicate answer yields `not-pending` rather than an error, so a
/// double-click on Allow is a no-op instead of a failure.
public struct RpcReceipt: Decodable, Sendable {
    public let accepted: Bool
    public let reason: String?
}

/// `{ok:true, value}` / `{ok:false, error}` — decoded on the `ok` discriminant.
struct RpcResult: Decodable {
    let ok: Bool
    let value: JSONValue?
    let error: RpcError?

    enum CodingKeys: String, CodingKey { case ok, value, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        error = try c.decodeIfPresent(RpcError.self, forKey: .error)
    }

    /// Unwrap to the success value or throw the business error.
    func unwrap() throws -> JSONValue {
        if ok { return value ?? .object([:]) }
        throw error ?? RpcError(code: "unknown", message: "unspecified failure", details: nil)
    }
}
