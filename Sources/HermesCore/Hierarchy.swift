import Foundation
import Observation
import HermesProtocol
import HermesTransport

public enum HierarchyDestination: Hashable, Codable, Sendable {
    case home, activity, workspaces, workspace(UUID), automations, automation(String), run(String)
    case conversation(StoredSessionID), otherConversations
}

public enum HomeAvailability: Equatable, Sendable {
    case unselected, loading, available, unavailable, failed(String)
}

/// These capabilities need verified backend support. Existing native input requests
/// remain available regardless of flags; a flag must never hide a pending decision.
public struct HierarchyFeatureFlags: Equatable, Sendable {
    public var telegramBindings = false
    public var delegatedTasks = false
    public var automationEditing = false
    public var homeContinuity = false
    public var canonicalResultReferences = false
    public init() {}
}

public struct TalariaWorkspace: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var purpose: String
    public var swatch: String
    public var sessionIDs: [StoredSessionID]
    public var isArchived: Bool
    public let createdAt: Date
    public init(id: UUID = UUID(), name: String, purpose: String = "", swatch: String = "#4F6AF2",
                sessionIDs: [StoredSessionID] = [], isArchived: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.purpose = purpose; self.swatch = swatch
        self.sessionIDs = sessionIDs; self.isArchived = isArchived; self.createdAt = createdAt
    }
}

public enum SessionLineageKind: String, Codable, Sendable { case delegated, branch, reset, compression }
public struct SessionLineage: Identifiable, Codable, Equatable, Sendable {
    public let childSessionID: StoredSessionID
    public let parentSessionID: StoredSessionID
    public let kind: SessionLineageKind
    public let createdAt: Date
    public var id: StoredSessionID { childSessionID }
    public init(childSessionID: StoredSessionID, parentSessionID: StoredSessionID, kind: SessionLineageKind, createdAt: Date = Date()) {
        self.childSessionID = childSessionID; self.parentSessionID = parentSessionID
        self.kind = kind; self.createdAt = createdAt
    }
}

public struct SessionPlace: Codable, Equatable, Sendable {
    /// A stable transcript row ID, rather than an offset that shifts as text reflows.
    public var visibleMessageID: String?
    public init(visibleMessageID: String? = nil) { self.visibleMessageID = visibleMessageID }
}

public struct HierarchyClassification: Codable, Equatable, Sendable {
    public var homeSessionID: StoredSessionID?
    public var workspaces: [TalariaWorkspace] = []
    public var lineage: [SessionLineage] = []
    public var readRunIDs: Set<String> = []
    public var archivedSessionIDs: Set<StoredSessionID> = []
    /// Legacy positions; use the store's place/rememberPlace methods for current values.
    public var places: [String: SessionPlace] = [:]
    public var cachedHomeMessages: [ChatMessage] = []
    public var telegramTopicAssignments: [TelegramTopicAssignment] = []
    public var pinnedChannelIDs: Set<StoredSessionID> = []
    public var collapsedChannelSources: Set<String> = []
    public var channelReadDates: [String: Date] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey { case homeSessionID, workspaces, lineage, readRunIDs, archivedSessionIDs, places, cachedHomeMessages, telegramTopicAssignments, pinnedChannelIDs, collapsedChannelSources, channelReadDates }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        homeSessionID = try container.decodeIfPresent(StoredSessionID.self, forKey: .homeSessionID)
        workspaces = try container.decodeIfPresent([TalariaWorkspace].self, forKey: .workspaces) ?? []
        lineage = try container.decodeIfPresent([SessionLineage].self, forKey: .lineage) ?? []
        readRunIDs = try container.decodeIfPresent(Set<String>.self, forKey: .readRunIDs) ?? []
        archivedSessionIDs = try container.decodeIfPresent(Set<StoredSessionID>.self, forKey: .archivedSessionIDs) ?? []
        places = try container.decodeIfPresent([String: SessionPlace].self, forKey: .places) ?? [:]
        cachedHomeMessages = try container.decodeIfPresent([ChatMessage].self, forKey: .cachedHomeMessages) ?? []
        telegramTopicAssignments = try container.decodeIfPresent([TelegramTopicAssignment].self, forKey: .telegramTopicAssignments) ?? []
        pinnedChannelIDs = try container.decodeIfPresent(Set<StoredSessionID>.self, forKey: .pinnedChannelIDs) ?? []
        collapsedChannelSources = try container.decodeIfPresent(Set<String>.self, forKey: .collapsedChannelSources) ?? []
        channelReadDates = try container.decodeIfPresent([String: Date].self, forKey: .channelReadDates) ?? [:]
    }
}

/// Organisation is local to a connection + profile. There is deliberately no
/// fallback from titles, recency, source, parent IDs, or the host's project table.
@MainActor @Observable
public final class HierarchyClassificationStore {
    public private(set) var revision = 0
    public private(set) var error: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cache: [SessionOwner: HierarchyClassification] = [:]
    @ObservationIgnored private var unreadableOwners = Set<SessionOwner>()
    public let syncDescription = "Stored on this device"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func place(for sessionID: StoredSessionID, owner: SessionOwner) -> SessionPlace {
        if let saved = defaults.string(forKey: placeKey(sessionID, owner: owner)) {
            return SessionPlace(visibleMessageID: saved.isEmpty ? nil : saved)
        }
        // Read existing positions until this session gets its first separate save.
        return classification(for: owner).places[sessionID.rawValue] ?? SessionPlace()
    }

    public func rememberPlace(_ messageID: String?, for sessionID: StoredSessionID, owner: SessionOwner) {
        let key = placeKey(sessionID, owner: owner)
        let value = messageID ?? ""
        guard defaults.string(forKey: key) != value else { return }
        // Scrolling must not encode cached messages or invalidate organisation views.
        // An empty string overrides a legacy position when returning to the tail.
        defaults.set(value, forKey: key)
    }

    private func placeKey(_ sessionID: StoredSessionID, owner: SessionOwner) -> String {
        let session = Data(sessionID.rawValue.utf8).base64EncodedString()
        return key(owner) + ".place." + session
    }

    public func classification(for owner: SessionOwner) -> HierarchyClassification {
        _ = revision
        if let saved = cache[owner] { return saved }
        guard let data = defaults.data(forKey: key(owner)) else { return HierarchyClassification() }
        do {
            let value = try JSONDecoder().decode(HierarchyClassification.self, from: data)
            cache[owner] = value; return value
        } catch {
            unreadableOwners.insert(owner)
            self.error = "Saved organisation could not be read. It has not been replaced."
            return HierarchyClassification()
        }
    }
    public func update(for owner: SessionOwner, _ change: (inout HierarchyClassification) -> Void) {
        var value = classification(for: owner)
        guard !unreadableOwners.contains(owner) else { return }
        let previous = value
        change(&value)
        guard value != previous else { return }
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= 2 * 1_024 * 1_024 else {
                error = "Saved organisation is full. No changes were discarded."; return
            }
            defaults.set(data, forKey: key(owner)); cache[owner] = value; error = nil; revision += 1
        } catch { self.error = "Organisation could not be saved on this device." }
    }
    private func key(_ owner: SessionOwner) -> String {
        let encoded = (try? JSONEncoder().encode([owner.connectionID.uuidString, owner.profile])) ?? Data()
        return "talaria.hierarchy.v1." + encoded.base64EncodedString()
    }
}

public enum AutomationRunStatus: String, Equatable, Sendable {
    case working = "Working", completed = "Completed", failed = "Failed"
    case waitingForInput = "Waiting for input", noOutput = "No output", unavailable = "Unavailable"
    public var isTerminal: Bool { self == .completed || self == .failed || self == .noOutput }
}

public struct AutomationRunDetail: Equatable, Sendable {
    public let runID: String
    public let result: String
    public let messages: [ChatMessage]
    public let status: AutomationRunStatus
    public let executionAvailable: Bool
    public let isHistoryTruncated: Bool
    public var toolCallCount: Int { messages.filter { $0.role == .tool }.count }
    public init(runID: String, result: String, messages: [ChatMessage], status: AutomationRunStatus,
                executionAvailable: Bool = true, isHistoryTruncated: Bool = false) {
        self.runID = runID; self.result = result; self.messages = messages; self.status = status
        self.executionAvailable = executionAvailable; self.isHistoryTruncated = isHistoryTruncated
    }
}

public enum HomeResolution {
    /// RPC 4007 is the pinned Hermes session-not-found error. Network failures,
    /// permission failures, and missing rows on a bounded list are not deletion.
    public static func isConfirmedMissing(_ error: Error) -> Bool {
        if let rpc = error as? JSONRPCError { return rpc.code == 4007 }
        return error as? GatewayTransportError == .httpStatus(404)
    }
}

public enum AutomationRunResult {
    public static func parse(_ run: MobileRun, response: JSONValue) -> AutomationRunDetail {
        let rows = response["messages"]?.arrayValue ?? []
        let messages: [ChatMessage] = rows.enumerated().compactMap { index, row in
            guard row["display_kind"]?.stringValue != "hidden" else { return nil }
            let text: String
            if let projected = row["display_content"] { text = projected.stringValue ?? "" }
            else { text = row["content"]?.stringValue ?? row["text"]?.stringValue ?? "" }
            let role = MessageRole(rawValue: row["role"]?.stringValue ?? "") ?? .system
            // Empty display projections are explicit suppression, never raw fallback.
            if role == .assistant && text.isEmpty && row["tool_calls"]?.arrayValue?.isEmpty != false { return nil }
            return ChatMessage(id: row["id"]?.intValue.map { "row-\($0)" } ?? "run-\(index)", role: role,
                text: String(text.prefix(64_000)), toolName: row["name"]?.stringValue,
                toolInput: row["args"].flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) },
                displayKind: row["display_kind"]?.stringValue)
        }
        // The last meaningful row must be the assistant's answer. Looking backwards
        // for any assistant message would misrepresent interim prose as a result
        // after a later unanswered prompt, failed tool call, or incomplete turn.
        let last = messages.last(where: { $0.role != .system })
        let output = last?.role == .assistant ? last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        let lastPhysicalAssistant = rows.last(where: { row in
            guard row["display_kind"]?.stringValue != "hidden" else { return false }
            if let content = row["display_content"], content.stringValue?.isEmpty != false { return false }
            return row["role"]?.stringValue != "system"
        })
        let hasPendingTools = lastPhysicalAssistant?["tool_calls"]?.arrayValue?.isEmpty == false
        let result = output == "[SILENT]" || hasPendingTools ? "" : output
        let status = Self.status(for: run, result: result)
        let limit = response["pagination"]?["limit"]?.intValue ?? 40
        return AutomationRunDetail(runID: run.id, result: result, messages: messages, status: status,
            isHistoryTruncated: rows.count >= limit)
    }

    public static func status(for run: AutomationRun, result: String) -> AutomationRunStatus {
        if run.isActive { return .working }
        if ["error", "failed", "cron_failed"].contains(run.endReason ?? "") { return .failed }
        if run.endReason == "cron_incomplete_no_output" { return .noOutput }
        if run.endedAt != nil || run.endReason == "cron_complete" { return result.isEmpty ? .noOutput : .completed }
        return .unavailable
    }
}

public typealias TalariaAutomation = MobileSchedule
public typealias AutomationRun = MobileRun

public struct WorkspaceFileReference: Identifiable, Equatable, Sendable {
    public let path: String
    public let sessionID: StoredSessionID
    public let toolName: String
    public var id: String { sessionID.rawValue + "\u{1f}" + path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// File references come only from explicit file-tool arguments/results. Paths
/// outside the session's working directory and shell-output guesses are omitted.
public enum WorkspaceFileReferences {
    public static func collect(sessionID: StoredSessionID, cwd: String, messages: [ChatMessage]) -> [WorkspaceFileReference] {
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { return [] }
        let root = (cwd as NSString).standardizingPath
        var byPath: [String: WorkspaceFileReference] = [:]
        for message in messages where message.role == .tool && !message.isError && !message.isStreaming {
            let name = message.toolName?.lowercased() ?? ""
            guard ["read_file", "write_file", "patch"].contains(name) else { continue }
            let args = message.toolInput.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let result = message.text.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            guard result?["success"]?.boolValue != false, result?["error"]?.stringValue?.isEmpty != false else { continue }
            let candidates = [result?["resolved_path"]?.stringValue ?? args?["path"]?.stringValue].compactMap { $0 }
                + (result?["files_modified"]?.arrayValue ?? []).compactMap(\.stringValue)
            for candidate in candidates where !candidate.isEmpty && !candidate.contains("\0") && !candidate.hasPrefix("~") {
                let path = ((candidate.hasPrefix("/") ? candidate : root + "/" + candidate) as NSString).standardizingPath
                guard path.hasPrefix(root == "/" ? "/" : root + "/"), path != root else { continue }
                byPath[path] = WorkspaceFileReference(path: path, sessionID: sessionID, toolName: name)
                if byPath.count >= 100 { break }
            }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }
}

public typealias AutomationRunDetailLoader = @Sendable (GatewayEndpoint, GatewaySession, AutomationRun) async throws -> JSONValue

/// Ephemeral confirmation of a response written to the gateway. Never stores a
/// question, command, answer text, or secret. The owning composer scope is kept
/// by HermesAppModel rather than deriving it from the current selection.
public struct RequestReceipt: Identifiable, Equatable, Sendable {
    public let id: RPCID
    public let method: String
    public let summary: String
    public let createdAt: Date
    init(id: RPCID, method: String, result: JSONValue, createdAt: Date = Date()) {
        self.id = id; self.method = method; self.createdAt = createdAt
        if method == "approval", let choice = result["choice"]?.stringValue,
           ["once", "session", "always", "deny"].contains(choice) {
            summary = "You chose \(choice)"
        } else if method == "clarify" { summary = "You answered" }
        else if ["secret", "sudo", "vault.code", "vault.unlock_prompt", "vault.save_login"].contains(method) {
            summary = "You responded securely"
        } else { summary = "You responded" }
    }
}
public typealias AutomationRunsLoader = @Sendable (GatewayEndpoint, GatewaySession, String) async throws -> JSONValue
