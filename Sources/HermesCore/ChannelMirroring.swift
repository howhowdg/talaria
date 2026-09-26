import Foundation
import HermesProtocol

public enum ChannelSource {
    public static let known = ["telegram", "discord", "slack", "mattermost", "matrix", "signal", "whatsapp", "bluebubbles", "photon", "homeassistant", "email", "sms", "webhook", "api_server", "weixin", "wecom", "qqbot", "yuanbao", "dingtalk", "feishu"]
    private static let local = Set(["native", "local", "cli", "desktop", "tui", "gateway", "codex", "cron", "kanban", "oneshot", "subagent", "tool", "bot_room", "unknown"])
    public static func normalized(_ source: String?) -> String { source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
    public static func isChannel(_ source: String?) -> Bool {
        let value = normalized(source)
        return !value.isEmpty && !local.contains(value)
    }
    public static func label(_ source: String?) -> String {
        let value = normalized(source)
        let labels = ["api_server": "API", "bluebubbles": "iMessage", "photon": "Photon", "homeassistant": "Home Assistant", "sms": "SMS", "qqbot": "QQ", "weixin": "WeChat", "wecom": "WeCom", "whatsapp": "WhatsApp", "dingtalk": "DingTalk"]
        return labels[value] ?? (value.isEmpty ? "Other" : value.replacingOccurrences(of: "_", with: " ").capitalized)
    }
    public static func symbol(_ source: String?) -> String {
        switch normalized(source) {
        case "telegram": "paperplane"
        case "email": "envelope"
        case "api_server", "webhook": "network"
        case "homeassistant": "house"
        default: "bubble.left.and.bubble.right"
        }
    }
}

public struct ChannelGroup: Identifiable, Equatable, Sendable {
    public var id: String { source }
    public let source: String
    public let label: String
    public let symbol: String
    public let sessions: [SessionSummary]
    public let hasMore: Bool
    public init(source: String, sessions: [SessionSummary], hasMore: Bool) {
        self.source = source; self.sessions = sessions; self.hasMore = hasMore
        label = ChannelSource.label(source); symbol = ChannelSource.symbol(source)
    }
}

public enum ChannelMirroringError: Error, LocalizedError {
    case invalidResponse, profileMismatch, storageUnavailable, missingMessageIdentity
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Hermes returned invalid channel history."
        case .profileMismatch: "Hermes returned history for a different profile."
        case .storageUnavailable: "Hermes could not read this profile's conversation storage."
        case .missingMessageIdentity: "Hermes history lacks stable message identifiers."
        }
    }
}

public struct ChannelSessionPage: Sendable {
    public let sessions: [SessionSummary]
    public let total: Int?
    public let rawCount: Int
    public init(response: JSONValue, profile: String, source: String?) throws {
        try validateOwner(response, profile: profile)
        if response["storage"]?[profile]?.stringValue == "corrupt" { throw ChannelMirroringError.storageUnavailable }
        if let errors = response["errors"]?.arrayValue, errors.contains(where: { $0["profile"]?.stringValue == profile }) {
            throw ChannelMirroringError.storageUnavailable
        }
        guard let rows = response["sessions"]?.arrayValue else { throw ChannelMirroringError.invalidResponse }
        if let value = response["total"] {
            guard let count = value.intValue, count >= 0 else { throw ChannelMirroringError.invalidResponse }
        }
        total = response["total"]?.intValue; rawCount = rows.count
        var seen = Set<StoredSessionID>()
        var result: [SessionSummary] = []
        for row in rows {
            try validateOwner(row, profile: profile)
            guard let id = row["id"]?.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChannelMirroringError.invalidResponse }
            let summary = SessionSummary(json: row)
            guard ChannelSource.isChannel(summary.source), source == nil || ChannelSource.normalized(summary.source) == ChannelSource.normalized(source) else { continue }
            if seen.insert(summary.id).inserted { result.append(summary) }
        }
        sessions = result
    }
    public func hasMore(offset: Int, limit: Int) -> Bool {
        guard offset >= 0, limit > 0, rawCount >= limit else { return false }
        // The host appends pinned rows outside the SQL page; they do not consume offset slots.
        return total.map { offset < $0 && limit < $0 - offset } ?? true
    }
}

public struct ChannelMessagePage: Sendable {
    public let messages: [ChatMessage]
    public let returned: Int
    public let resolvedID: StoredSessionID
    public let offset: Int
    public let limit: Int
    public init(response: JSONValue, profile: String, requestedID: StoredSessionID) throws {
        try validateOwner(response, profile: profile)
        guard !requestedID.rawValue.isEmpty, let rows = response["messages"]?.arrayValue,
              let sessionID = response["session_id"]?.stringValue, !sessionID.isEmpty,
              let offset = response["pagination"]?["offset"]?.intValue, offset >= 0,
              let limit = response["pagination"]?["limit"]?.intValue, limit > 0,
              let returned = response["pagination"]?["returned"]?.intValue, returned == rows.count, returned <= limit else {
            throw ChannelMirroringError.invalidResponse
        }
        self.offset = offset; self.limit = limit; self.returned = returned
        resolvedID = StoredSessionID(rawValue: sessionID)
        var result: [ChatMessage] = []
        var seen = Set<String>()
        for row in rows {
            try validateOwner(row, profile: profile)
            let rawID = row["id"]?.stringValue ?? row["id"]?.intValue.flatMap { $0 > 0 && $0 <= 9_007_199_254_740_991 ? String($0) : nil }
            guard let rawID, !rawID.isEmpty else { throw ChannelMirroringError.missingMessageIdentity }
            let origin = row["session_id"]?.stringValue ?? requestedID.rawValue
            let id = "history-\(origin.utf8.count):\(origin):\(rawID)"
            guard seen.insert(id).inserted else { throw ChannelMirroringError.invalidResponse }
            guard row["display_kind"]?.stringValue != "hidden" else { continue }
            let role = MessageRole(rawValue: row["role"]?.stringValue ?? "") ?? .system
            let content = row["display_content"] ?? row["content"] ?? row["text"] ?? .null
            let text = Self.text(content)
            let reasoning = row["reasoning"]?.stringValue ?? row["reasoning_content"]?.stringValue ?? ""
            let calls = row["tool_calls"]?.arrayValue ?? []
            let timestamp: Date?
            if case .number(let seconds) = row["timestamp"], seconds.isFinite, seconds > 0, seconds < 253_402_300_800 { timestamp = Date(timeIntervalSince1970: seconds) } else { timestamp = nil }
            if role != .assistant || !text.isEmpty || !reasoning.isEmpty {
                result.append(ChatMessage(id: id, role: role, text: text, reasoning: reasoning,
                    toolName: row["tool_name"]?.stringValue ?? row["name"]?.stringValue,
                    toolSummary: role == .tool ? text : nil, timestamp: timestamp))
            }
            for (index, call) in calls.enumerated() {
                let function = call["function"] ?? call
                let arguments = function["arguments"] ?? function["args"]
                let input = arguments?.stringValue ?? arguments.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                result.append(ChatMessage(id: "\(id):call:\(index)", role: .tool, text: "",
                    toolName: function["name"]?.stringValue ?? "Tool", toolInput: input, timestamp: timestamp))
            }
        }
        messages = result
    }
    private static func text(_ content: JSONValue) -> String {
        if let string = content.stringValue { return string }
        return content.arrayValue?.compactMap { block in
            if let string = block.stringValue { return string }
            return block["text"]?.stringValue
        }.joined(separator: "\n") ?? ""
    }
}

private func validateOwner(_ value: JSONValue, profile: String) throws {
    if let owner = value["profile"], owner.stringValue != profile { throw ChannelMirroringError.profileMismatch }
}
