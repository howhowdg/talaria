import Foundation
import HermesProtocol
import HermesTransport

public typealias TelegramTopicsLoader = @Sendable (GatewayEndpoint, String) async throws -> JSONValue

/// The enclosing classification store supplies the connection/profile owner.
/// A routing key also distinguishes per-user conversations in one group topic.
public struct TelegramTopicIdentity: Hashable, Codable, Sendable {
    public let chatID: String
    public let threadID: String
    public let sessionKey: String
    public init(chatID: String, threadID: String, sessionKey: String) {
        self.chatID = chatID; self.threadID = threadID; self.sessionKey = sessionKey
    }
}

public struct TelegramTopic: Identifiable, Equatable, Sendable {
    public let id: TelegramTopicIdentity
    public let currentSessionID: StoredSessionID
    public let chatType: String
    public let chatName: String?
    public let topicName: String?
    public var displayLabel: String { topicName ?? "Topic \(id.threadID)" }
    public var groupName: String { chatName ?? "Telegram chat \(id.chatID)" }

    public init(id: TelegramTopicIdentity, currentSessionID: StoredSessionID, chatType: String,
                chatName: String? = nil, topicName: String? = nil) {
        self.id = id; self.currentSessionID = currentSessionID; self.chatType = chatType
        self.chatName = chatName; self.topicName = topicName
    }
}

public enum TelegramTopicsError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse, unsupportedSchema, profileMismatch, duplicateBinding
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Hermes returned incomplete Telegram topic information. Refresh to try again."
        case .unsupportedSchema: "This version of the Telegram topic extension is not supported."
        case .profileMismatch: "The Telegram topic response belongs to a different profile. No topics were imported."
        case .duplicateBinding: "Hermes returned conflicting Telegram topic bindings. No topics were imported."
        }
    }
}

/// Only the authenticated extension's explicit routing records establish topic identity.
/// A malformed or ambiguous snapshot is rejected as a whole, never partially imported.
public struct TelegramTopicsSnapshot: Equatable, Sendable {
    public let profile: String
    public let topics: [TelegramTopic]

    public init(json: JSONValue, expectedProfile: String) throws {
        guard json["schema_version"]?.intValue == 1 else { throw TelegramTopicsError.unsupportedSchema }
        guard let profile = json["profile"]?.stringValue, profile == expectedProfile else {
            throw TelegramTopicsError.profileMismatch
        }
        guard let rows = json["topics"]?.arrayValue, rows.count <= 2_000 else { throw TelegramTopicsError.invalidResponse }
        var topics: [TelegramTopic] = []
        var identities = Set<TelegramTopicIdentity>()
        var routingKeys = Set<String>()
        var sessionIDs = Set<StoredSessionID>()
        for row in rows {
            guard row["binding_source"]?.stringValue == "gateway_routing" else { throw TelegramTopicsError.invalidResponse }
            let chatID = try Self.requiredString(row["chat_id"])
            let threadID = try Self.requiredString(row["thread_id"])
            guard chatID.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil,
                  threadID.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else {
                throw TelegramTopicsError.invalidResponse
            }
            let identity = TelegramTopicIdentity(chatID: chatID, threadID: threadID,
                                                sessionKey: try Self.requiredString(row["session_key"]))
            let sessionID = StoredSessionID(rawValue: try Self.requiredString(row["current_session_id"]))
            guard identities.insert(identity).inserted, routingKeys.insert(identity.sessionKey).inserted,
                  sessionIDs.insert(sessionID).inserted else { throw TelegramTopicsError.duplicateBinding }
            topics.append(TelegramTopic(id: identity, currentSessionID: sessionID,
                chatType: try Self.requiredString(row["chat_type"]),
                chatName: try Self.optionalLabel(row["chat_name"]),
                topicName: try Self.optionalLabel(row["topic_name"])))
        }
        self.profile = profile; self.topics = topics
    }

    private static func requiredString(_ value: JSONValue?) throws -> String {
        guard let text = value?.stringValue, !text.isEmpty, text.utf8.count <= 512,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TelegramTopicsError.invalidResponse
        }
        return text
    }

    private static func optionalLabel(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, text.utf8.count <= 1_024,
              // Format scalars include the joiners in ordinary emoji topic names.
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else {
            throw TelegramTopicsError.invalidResponse
        }
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}

public enum TelegramTopicDestination: Equatable, Codable, Sendable {
    case home
    case workspace(UUID)
}

public struct TelegramTopicAssignment: Equatable, Codable, Sendable {
    public let identity: TelegramTopicIdentity
    public var destination: TelegramTopicDestination
    public var lastKnownSessionID: StoredSessionID
    /// Nil fields identify older imports. Only their exact numbered placeholder
    /// is eligible for migration; a user's own workspace name is never replaced.
    public var importedWorkspaceName: String?
    public var followsTopicName: Bool?
    public init(identity: TelegramTopicIdentity, destination: TelegramTopicDestination, lastKnownSessionID: StoredSessionID,
                importedWorkspaceName: String? = nil, followsTopicName: Bool? = nil) {
        self.identity = identity; self.destination = destination; self.lastKnownSessionID = lastKnownSessionID
        self.importedWorkspaceName = importedWorkspaceName; self.followsTopicName = followsTopicName
    }
}

extension HierarchyClassification {
    /// Apply a user's explicit topic selection. No topic name, source or recency
    /// can choose Home. Verified labels can update imported defaults; custom
    /// workspace names and archive choices belong to the user.
    public mutating func importTelegramTopics(_ topics: [TelegramTopic], home: TelegramTopicIdentity?,
                                             asWorkspaces selected: Set<TelegramTopicIdentity>) {
        reconcileTelegramTopics(topics)
        if let home, let topic = topics.first(where: { $0.id == home }) {
            telegramTopicAssignments.removeAll { $0.destination == .home || $0.identity == home }
            if homeSessionID != topic.currentSessionID { cachedHomeMessages = [] }
            homeSessionID = topic.currentSessionID
            archivedSessionIDs.remove(topic.currentSessionID)
            for index in workspaces.indices { workspaces[index].sessionIDs.removeAll { $0 == topic.currentSessionID } }
            telegramTopicAssignments.append(.init(identity: home, destination: .home, lastKnownSessionID: topic.currentSessionID))
        }
        for topic in topics where selected.contains(topic.id) && topic.id != home && topic.currentSessionID != homeSessionID {
            if telegramTopicAssignments.contains(where: { $0.identity == topic.id }) { continue }
            let workspaceID: UUID
            let followsName: Bool
            if let existing = workspaces.first(where: { $0.sessionIDs.contains(topic.currentSessionID) }) {
                workspaceID = existing.id
                followsName = false
            } else {
                let workspace = TalariaWorkspace(name: topic.displayLabel, sessionIDs: [topic.currentSessionID])
                workspaceID = workspace.id; workspaces.append(workspace)
                followsName = true
            }
            telegramTopicAssignments.append(.init(identity: topic.id, destination: .workspace(workspaceID),
                                                  lastKnownSessionID: topic.currentSessionID,
                                                  importedWorkspaceName: followsName ? topic.displayLabel : nil,
                                                  followsTopicName: followsName))
        }
    }

    /// Follow explicit host bindings across reset/compression, preserving every
    /// unrelated local choice. Missing routes retain their last known assignment.
    public mutating func reconcileTelegramTopics(_ topics: [TelegramTopic]) {
        let byID = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var retained: [TelegramTopicAssignment] = []
        for var assignment in telegramTopicAssignments {
            switch assignment.destination {
            case .home:
                // A later manual choice revokes this import's authority over Home.
                guard homeSessionID == assignment.lastKnownSessionID else { continue }
                if let topic = byID[assignment.identity], topic.currentSessionID != assignment.lastKnownSessionID {
                    homeSessionID = topic.currentSessionID; cachedHomeMessages = []
                    archivedSessionIDs.remove(topic.currentSessionID)
                    for index in workspaces.indices { workspaces[index].sessionIDs.removeAll { $0 == topic.currentSessionID } }
                    assignment.lastKnownSessionID = topic.currentSessionID
                }
            case .workspace(let id):
                // Removed/reassigned conversations also revoke automatic following.
                guard let index = workspaces.firstIndex(where: { $0.id == id }),
                      workspaces[index].sessionIDs.contains(assignment.lastKnownSessionID) else { continue }
                if let topic = byID[assignment.identity] {
                    let expected = assignment.importedWorkspaceName ?? "Topic \(assignment.identity.threadID)"
                    let follows = assignment.followsTopicName ?? (workspaces[index].name == expected)
                    if follows && workspaces[index].name == expected {
                        assignment.followsTopicName = true
                        // An incomplete response must not replace a known name with a number.
                        if let name = topic.topicName {
                            workspaces[index].name = name
                            assignment.importedWorkspaceName = name
                        }
                    } else { assignment.followsTopicName = false }
                }
                if let topic = byID[assignment.identity], topic.currentSessionID != assignment.lastKnownSessionID {
                    guard topic.currentSessionID != homeSessionID,
                          !workspaces.contains(where: { $0.id != id && $0.sessionIDs.contains(topic.currentSessionID) }) else { continue }
                    workspaces[index].sessionIDs.removeAll { $0 == assignment.lastKnownSessionID }
                    if !workspaces[index].sessionIDs.contains(topic.currentSessionID) { workspaces[index].sessionIDs.append(topic.currentSessionID) }
                    assignment.lastKnownSessionID = topic.currentSessionID
                }
            }
            retained.append(assignment)
        }
        telegramTopicAssignments = retained
    }
}
