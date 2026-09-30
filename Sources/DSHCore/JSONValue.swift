import Foundation

/// A parsed JSON document that is `Sendable` and `Equatable`, for code that
/// builds or reads JSON without `[String: Any]` (which Swift 6 will not let
/// cross an isolation boundary): the Bedrock request/response mapping and the
/// output of the AWS CLI.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Parsing

    /// Parse JSON text; nil when it isn't valid JSON.
    public init?(parsing text: String) {
        guard let data = text.data(using: .utf8) else { return nil }
        self.init(parsing: data)
    }

    /// Parse JSON data (a fragment, such as a bare string or number, is accepted).
    public init?(parsing data: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(any: any)
    }

    /// Convert a `JSONSerialization` result.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber also carries Bool; CFBoolean is the only one that is truly boolean.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let text as String:
            self = .string(text)
        case let items as [Any]:
            self = .array(items.map { JSONValue(any: $0) })
        case let fields as [String: Any]:
            self = .object(fields.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    // MARK: Building

    /// `Any` for `JSONSerialization` (whole numbers stay integers).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9e15 { return Int64(value) }
            return value
        case .string(let value): return value
        case .array(let items): return items.map(\.anyValue)
        case .object(let fields): return fields.mapValues(\.anyValue)
        }
    }

    /// Compact JSON text with sorted keys (stable, so it can be compared and signed).
    public func serialized(pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: options) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public func serializedData() -> Data { Data(serialized().utf8) }

    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var double: Double? { if case .number(let value) = self { return value } else { return nil } }
    public var int: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 9e15 else { return nil }
        return Int(value)
    }
    public var array: [JSONValue]? { if case .array(let items) = self { return items } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let fields) = self { return fields } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                     ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
