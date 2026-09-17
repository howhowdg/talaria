import Foundation

/// A composer belongs to a particular connection, profile and durable session.
/// Runtime IDs and ephemeral local ports are never persistence keys.
public struct ComposerScope: Codable, Hashable, Sendable {
    public let connectionID: UUID
    public let profile: String
    public let storedSessionID: StoredSessionID
    public init(connectionID: UUID, profile: String, storedSessionID: StoredSessionID) {
        self.connectionID = connectionID; self.profile = profile; self.storedSessionID = storedSessionID
    }
    public init(owner: SessionOwner, sessionID: StoredSessionID) {
        self.init(connectionID: owner.connectionID, profile: owner.profile, storedSessionID: sessionID)
    }
}

/// Device-local text drafts. Attachments and credentials are deliberately not serialized here.
@MainActor
public final class DraftStore {
    private struct Record: Codable { let scope: ComposerScope; var text: String }
    private struct Selection: Codable { let owner: SessionOwner; var sessionID: StoredSessionID }
    private struct Document: Codable {
        var version = 1
        var drafts: [Record]
        var selections: [Selection]
    }
    private var texts: [ComposerScope: String] = [:]
    private var selections: [SessionOwner: StoredSessionID] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var loadFailed = false
    public private(set) var lastError: String?

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talaria", isDirectory: true)
        fileURL = base.appendingPathComponent("drafts-v1.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw DraftError.unsupportedVersion }
            for row in document.drafts { texts[row.scope] = row.text }
            for row in document.selections { selections[row.owner] = row.sessionID }
        } catch {
            loadFailed = true
            lastError = "Saved drafts could not be read. The original file will be preserved before writing new drafts."
        }
    }

    public func text(for scope: ComposerScope) -> String { texts[scope] ?? "" }
    public func selectedSession(for owner: SessionOwner) -> StoredSessionID? { selections[owner] }

    public func setText(_ text: String, for scope: ComposerScope) {
        guard self.text(for: scope) != text else { return }
        if text.isEmpty { texts.removeValue(forKey: scope) } else { texts[scope] = text }
        scheduleSave()
    }

    public func select(_ sessionID: StoredSessionID, owner: SessionOwner) {
        guard selections[owner] != sessionID else { return }
        selections[owner] = sessionID; scheduleSave()
    }

    public func move(from old: ComposerScope, to new: ComposerScope) {
        guard old != new else { return }
        if let text = texts.removeValue(forKey: old), texts[new] == nil { texts[new] = text }
        let owner = SessionOwner(connectionID: old.connectionID, profile: old.profile)
        if selections[owner] == old.storedSessionID { selections[owner] = new.storedSessionID }
        scheduleSave()
    }

    public func flush() throws {
        saveTask?.cancel(); saveTask = nil
        guard dirty else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if loadFailed {
                let backup = directory.appendingPathComponent("drafts-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: fileURL, to: backup)
                loadFailed = false
            }
            let document = Document(drafts: texts.map { Record(scope: $0.key, text: $0.value) },
                                    selections: selections.map { Selection(owner: $0.key, sessionID: $0.value) })
            let data = try JSONEncoder().encode(document)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            dirty = false; lastError = nil
        } catch {
            lastError = "Talaria could not save the draft on this device."
            throw error
        }
    }

    private func scheduleSave() {
        dirty = true; saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            try? self?.flush()
        }
    }
    private enum DraftError: Error { case unsupportedVersion }
}
