import Foundation

/// A dynamic JSON value.
///
/// The `/api` contract spans 36 domains whose payloads are heterogeneous and
/// still moving (the repo warns of compatibility-breaking changes). Decoding
/// every domain into a static Swift type would make this client break on any
/// upstream field addition, so the transport layer stays dynamic and each
/// feature reaches for exactly the fields it renders.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: - Accessors

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    public var doubleValue: Double? {
        guard case .number(let n) = self else { return nil }
        return n
    }

    public var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        return Int(n)
    }

    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let o) = self else { return nil }
        return o
    }

    /// Follow a dotted key path, e.g. `data.chunk.text`.
    public func path(_ keys: String...) -> JSONValue? {
        var node: JSONValue? = self
        for k in keys { node = node?[k] }
        return node
    }
}

// MARK: - Ergonomic literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryElements elements: [(String, JSONValue)]) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
