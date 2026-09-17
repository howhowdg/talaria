import Foundation

/// Lossless JSON structure for open gateway payloads and future contract extensions.
/// Numbers use the gateway clients' IEEE 754 representation; RPC identifiers are
/// decoded separately as `RPCID` so their integer identity is not rounded.
public enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(_ key: String) -> JSONValue? { objectValue?[key] }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

/// A nullable field whose absence and explicit null have different wire meanings.
/// Use the keyed container helpers when encoding: `.absent` emits no key.
public enum JSONField<Value: Codable & Sendable & Equatable>: Sendable, Equatable {
    case absent
    case null
    case value(Value)

    public var value: Value? { if case .value(let value) = self { value } else { nil } }
}

extension KeyedDecodingContainer {
    public func decodeField<Value>(_ type: Value.Type, forKey key: Key) throws -> JSONField<Value>
    where Value: Codable & Sendable & Equatable {
        guard contains(key) else { return .absent }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(type, forKey: key))
    }

    /// Omission is permitted; explicit null is rejected for a non-nullable field.
    public func decodeOmittable<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        contains(key) ? try decode(type, forKey: key) : nil
    }
}

extension KeyedEncodingContainer {
    public mutating func encodeField<Value>(_ field: JSONField<Value>, forKey key: Key) throws
    where Value: Codable & Sendable & Equatable {
        switch field {
        case .absent: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}
