import Foundation
import HermesProtocol

public struct StoredSessionID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct RuntimeSessionID: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct SessionOwner: Hashable, Sendable, Codable {
    public let connectionID: UUID
    public let profile: String
    public init(connectionID: UUID, profile: String) {
        self.connectionID = connectionID
        self.profile = profile
    }
}
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public let id: StoredSessionID
    public var title: String
    public var preview: String
    public var messageCount: Int
    /// The stored conversation's start time, not its latest activity. The pinned
    /// session.list contract exposes started_at as Unix seconds and uses 0 when absent.
    public var startedAt: Date?
    public init(json: JSONValue) {
        id = StoredSessionID(rawValue: json["id"]?.stringValue ?? "")
        title = json["title"]?.stringValue ?? ""
        preview = json["preview"]?.stringValue ?? ""
        messageCount = json["message_count"]?.intValue ?? 0
        startedAt = Self.startDate(json["started_at"])
    }
    public var displayTitle: String { title.isEmpty ? "Untitled conversation" : title }

    private static func startDate(_ value: JSONValue?) -> Date? {
        guard let value, case .number(let seconds) = value, seconds.isFinite,
              seconds > 0, seconds < 253_402_300_800 else { return nil }
        // Keep calendar dates before year 10000; reject malformed/out-of-range
        // values rather than guessing milliseconds or manufacturing a recent date.
        return Date(timeIntervalSince1970: seconds)
    }
}
public enum MessageRole: String, Sendable, Codable { case user, assistant, tool, system }
public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public var role: MessageRole
    public var text: String
    public var reasoning: String
    public var toolName: String?
    public var toolInput: String?
    public var toolSummary: String?
    public var isStreaming: Bool
    public var isError: Bool
    public init(id: String = UUID().uuidString, role: MessageRole, text: String,
                reasoning: String = "", toolName: String? = nil, toolInput: String? = nil,
                toolSummary: String? = nil, isStreaming: Bool = false, isError: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.reasoning = reasoning
        self.toolName = toolName; self.toolInput = toolInput
        self.toolSummary = toolSummary
        self.isStreaming = isStreaming; self.isError = isError
    }
}
public struct PendingInput: Identifiable, Equatable, Sendable {
    public let request: GatewayServerRequest
    public var id: RPCID { request.id }
    public var method: String { request.method }
    public var params: JSONValue { request.params }
    public init(_ request: GatewayServerRequest) { self.request = request }
}

public struct ConversationState: Equatable, Sendable {
    public let owner: SessionOwner
    public var storedID: StoredSessionID
    public var runtimeID: RuntimeSessionID
    public var title: String
    public var model: String
    public var cwd: String
    public var hasQueuedPrompt: Bool
    public var messages: [ChatMessage]
    public var pendingInputs: [PendingInput]
    public var isRunning: Bool
    public var status: String
    public var lastSequence: Int?
    public var requiresHydration = false
    private var assistantID: String?

    public init(snapshot: JSONValue, owner: SessionOwner) throws {
        guard let runtime = snapshot["session_id"]?.stringValue, !runtime.isEmpty else {
            throw ConversationError.invalidSnapshot
        }
        self.owner = owner
        runtimeID = RuntimeSessionID(rawValue: runtime)
        let info = snapshot["info"]
        let stored = [snapshot["stored_session_id"]?.stringValue, info?["stored_session_id"]?.stringValue,
                      snapshot["session_key"]?.stringValue, snapshot["resumed"]?.stringValue]
            .compactMap { $0 }.first { !$0.isEmpty } ?? runtime
        storedID = StoredSessionID(rawValue: stored)
        let snapshotTitle = info?["title"]?.stringValue ?? ""
        title = snapshotTitle.isEmpty ? "New conversation" : snapshotTitle
        model = info?["model"]?.stringValue ?? ""
        cwd = info?["cwd"]?.stringValue ?? ""
        hasQueuedPrompt = snapshot["queued"]?.objectValue != nil
        messages = (snapshot["messages"]?.arrayValue ?? []).enumerated().compactMap { index, row in
            guard row["display_kind"]?.stringValue != "hidden" else { return nil }
            let role = MessageRole(rawValue: row["role"]?.stringValue ?? "") ?? .system
            return ChatMessage(
                id: row["row_id"]?.intValue.map { "row-\($0)" } ?? "history-\(index)",
                role: role, text: row["text"]?.stringValue ?? "",
                reasoning: row["reasoning"]?.stringValue ?? "",
                toolName: row["name"]?.stringValue,
                toolInput: row["args"].map(Self.describe), toolSummary: row["context"]?.stringValue)
        }
        pendingInputs = []
        isRunning = snapshot["running"]?.boolValue ?? info?["running"]?.boolValue ?? false
        status = isRunning ? "Working…" : "Ready"
        lastSequence = nil
        assistantID = nil
        if let inflight = snapshot["inflight"], inflight.objectValue != nil {
            let user = inflight["user"]?.stringValue ?? ""
            if inflight["display_kind"]?.stringValue != "hidden", !user.isEmpty,
               messages.last(where: { $0.role == .user })?.text != user {
                messages.append(ChatMessage(role: .user, text: user))
            }
            let text = inflight["assistant"]?.stringValue ?? ""
            let last = messages.last
            if !text.isEmpty && last?.role == .assistant && last?.text == text {
                assistantID = last?.id
                messages[messages.count - 1].isStreaming = isRunning
            } else if !text.isEmpty || isRunning {
                let message = ChatMessage(role: .assistant, text: text, isStreaming: isRunning)
                assistantID = message.id
                messages.append(message)
            }
            if let error = inflight["error"]?.stringValue, !error.isEmpty {
                messages.append(ChatMessage(role: .system, text: error, isError: true))
                status = "Needs attention"
            }
        }
    }

    @discardableResult
    public mutating func beginSubmission(text: String) -> String {
        let message = ChatMessage(role: .user, text: text)
        messages.append(message)
        isRunning = true
        status = "Sending…"
        assistantID = nil
        return message.id
    }

    public mutating func cancelUnsentSubmission(_ messageID: String) {
        messages.removeAll { $0.id == messageID }
        isRunning = false
        status = "Ready"
    }

    /// Apply in receive-stream order, after the corresponding snapshot marker.
    public mutating func apply(_ event: GatewayEvent) {
        guard event.sessionID == runtimeID.rawValue || event.sessionID == storedID.rawValue else { return }
        if let sequence = event.sequence {
            if let lastSequence, sequence <= lastSequence { return }
            lastSequence = sequence
        }
        let p = event.payload
        switch event.type {
        case "message.start":
            isRunning = true; status = "Thinking…"
        case "message.delta":
            appendAssistant(text: p["text"]?.stringValue ?? "", reasoning: "")
            status = "Writing…"
        case "reasoning.delta", "thinking.delta":
            appendAssistant(text: "", reasoning: p["text"]?.stringValue ?? "")
            status = "Thinking…"
        case "reasoning.available":
            if let text = p["text"]?.stringValue {
                ensureAssistant()
                if let i = assistantIndex { messages[i].reasoning = text }
            }
        case "message.interim":
            if p["already_streamed"]?.boolValue != true {
                let text = p["text"]?.stringValue ?? ""
                if let i = assistantIndex, !messages[i].text.isEmpty, text.hasPrefix(messages[i].text) {
                    messages[i].text = text
                } else { appendAssistant(text: text, reasoning: "") }
            }
            sealAssistant()
        case "tool.start":
            sealAssistant()
            let tool = p["tool_id"]?.stringValue ?? UUID().uuidString
            let id = "tool-\(tool)"
            if !messages.contains(where: { $0.id == id }) {
                messages.append(ChatMessage(id: id, role: .tool,
                    text: p["context"]?.stringValue ?? p["preview"]?.stringValue ?? "",
                    toolName: p["name"]?.stringValue ?? "Tool",
                    toolInput: p["args"].map(Self.describe), isStreaming: true))
            }
            status = "Using \(p["name"]?.stringValue ?? "a tool")…"
        case "tool.complete":
            let id = "tool-\(p["tool_id"]?.stringValue ?? "")"
            let result = p["result_text"]?.stringValue ?? p["result"].map(Self.describe)
                ?? p["summary"]?.stringValue ?? ""
            if let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i].text = result; messages[i].isStreaming = false
                messages[i].toolSummary = p["summary"]?.stringValue
            } else {
                messages.append(ChatMessage(id: id, role: .tool, text: result,
                    toolName: p["name"]?.stringValue ?? "Tool", toolSummary: p["summary"]?.stringValue))
            }
        case "message.complete":
            let final = p["text"]?.stringValue ?? ""
            if !final.isEmpty {
                if assistantIndex == nil, p["response_previewed"]?.boolValue == true,
                   let index = messages.indices.last(where: { messages[$0].role == .assistant }),
                   !messages[index].text.isEmpty, final.hasPrefix(messages[index].text) {
                    assistantID = messages[index].id
                }
                ensureAssistant()
                if let i = assistantIndex { messages[i].text = final }
            }
            if let reasoning = p["reasoning"]?.stringValue, !reasoning.isEmpty, let i = assistantIndex {
                messages[i].reasoning = reasoning
            }
            sealAssistant()
            for i in messages.indices { messages[i].isStreaming = false }
            isRunning = false
            status = p["status"]?.stringValue == "interrupted" ? "Stopped" : "Ready"
            if p["status"]?.stringValue == "error" || p["error"]?.stringValue != nil {
                let error = p["error"]?.stringValue ?? p["failure_reason"]?.stringValue ?? "The turn failed."
                messages.append(ChatMessage(role: .system, text: error, isError: true))
                status = "Needs attention"
            }
        case "status.update": status = p["text"]?.stringValue ?? status
        case "session.info":
            if let updated = p["title"]?.stringValue, !updated.isEmpty { title = updated }
            model = p["model"]?.stringValue ?? model
            cwd = p["cwd"]?.stringValue ?? cwd
            if let stored = p["stored_session_id"]?.stringValue, !stored.isEmpty {
                storedID = StoredSessionID(rawValue: stored)
            }
        case "session.title": title = p["title"]?.stringValue ?? title
        case "request.cancel":
            if let id = p["id"]?.stringValue {
                pendingInputs.removeAll { $0.id == .string(id) }
            }
        case "error":
            messages.append(ChatMessage(role: .system,
                text: p["message"]?.stringValue ?? "Hermes reported an error.", isError: true))
            isRunning = false; sealAssistant(); status = "Needs attention"
        default: break
        }
    }

    public mutating func receive(_ request: GatewayServerRequest) {
        if let i = pendingInputs.firstIndex(where: { $0.id == request.id }) {
            pendingInputs[i] = PendingInput(request)
        } else {
            pendingInputs.append(PendingInput(request))
        }
        status = "Waiting for you"
    }

    public mutating func removeRequest(_ id: RPCID) {
        pendingInputs.removeAll { $0.id == id }
        if pendingInputs.isEmpty { status = isRunning ? "Working…" : "Ready" }
    }

    public mutating func markStopped() {
        isRunning = false; sealAssistant(); status = "Stopped"
        pendingInputs.removeAll()
    }

    public mutating func markStopping() {
        // Interrupt ACK acknowledges intent; only terminal events prove the worker has stopped.
        if isRunning { status = "Stopping…" }
    }

    private var assistantIndex: Int? { messages.firstIndex { $0.id == assistantID } }
    private mutating func ensureAssistant() {
        if assistantIndex == nil {
            let row = ChatMessage(role: .assistant, text: "", isStreaming: true)
            assistantID = row.id; messages.append(row)
        }
    }
    private mutating func appendAssistant(text: String, reasoning: String) {
        ensureAssistant()
        if let i = assistantIndex {
            messages[i].text += text; messages[i].reasoning += reasoning
        }
    }
    private mutating func sealAssistant() {
        if let i = assistantIndex { messages[i].isStreaming = false }
        assistantID = nil
    }
    public static func describe(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
public enum ConversationError: Error, LocalizedError {
    case invalidSnapshot
    public var errorDescription: String? { "Hermes returned an invalid session snapshot." }
}
