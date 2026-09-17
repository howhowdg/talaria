import Foundation

public enum RPCID: Sendable, Codable, Hashable {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .number(try container.decode(Int.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public struct JSONRPCError: Error, Sendable, Equatable, Codable, LocalizedError {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    private enum CodingKeys: String, CodingKey { case code, message, data }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        // JSONValue.null is meaningful; decodeIfPresent would collapse it.
        data = try container.decodeOmittable(JSONValue.self, forKey: .data)
    }
}

public struct GatewayServerRequest: Sendable, Equatable, Codable {
    public let id: RPCID
    public let method: String
    public let params: JSONValue

    public init(id: RPCID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// The `params` object of a `method: "event"` notification, or a replay event.
/// Payload fields are nested under `payload`, never merged with the envelope.
public struct GatewayEvent: Sendable, Equatable, Codable {
    public let type: String
    public let sessionID: String?
    public let sequence: Int?
    public let payload: JSONValue

    public init(type: String, sessionID: String? = nil, sequence: Int? = nil, payload: JSONValue = .object([:])) {
        self.type = type
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
    }

    public init(params: JSONValue) throws {
        guard let object = params.objectValue,
              let type = object["type"]?.stringValue, !type.isEmpty else {
            throw JSONRPCError(code: -32600, message: "Gateway event requires an object with a nonempty type")
        }
        if let sequence = object["seq"], sequence != .null, sequence.intValue == nil {
            throw JSONRPCError(code: -32600, message: "Gateway event sequence must be an integer")
        }
        if let sessionID = object["session_id"], sessionID != .null, sessionID.stringValue == nil {
            throw JSONRPCError(code: -32600, message: "Gateway event session_id must be a string")
        }
        self.init(type: type, sessionID: object["session_id"]?.stringValue,
                  sequence: object["seq"]?.intValue, payload: object["payload"] ?? .object([:]))
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload
        case sessionID = "session_id"
        case sequence = "seq"
    }

    public init(from decoder: any Decoder) throws {
        try self.init(params: JSONValue(from: decoder))
    }
}
