import Foundation
import HermesProtocol

/// Bridges the gateway's separate image queue and prompt submission without replaying
/// a mutation after a lost acknowledgement. Journal records contain host paths, never bytes or tokens.
public actor AttachmentSender {
    public typealias Request = @Sendable (String, JSONValue, TimeInterval) async throws -> JSONValue

    private struct ImageAttempt: Codable, Sendable {
        let requestedPath: String
        var canonicalPath: String?
    }
    private struct Pending: Codable, Sendable {
        var scope: ComposerScope
        let runtimeID: String
        var attempts: [ImageAttempt]
        var submitted: Bool
        var aliases: [ComposerScope] = []

        init(scope: ComposerScope, runtimeID: String, attempts: [ImageAttempt] = [], submitted: Bool = false) {
            self.scope = scope; self.runtimeID = runtimeID; self.attempts = attempts; self.submitted = submitted
        }
        private enum CodingKeys: String, CodingKey { case scope, runtimeID, attempts, submitted, imagePaths, aliases }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            scope = try values.decode(ComposerScope.self, forKey: .scope)
            runtimeID = try values.decode(String.self, forKey: .runtimeID)
            submitted = try values.decode(Bool.self, forKey: .submitted)
            aliases = try values.decodeIfPresent([ComposerScope].self, forKey: .aliases) ?? []
            if let attempts = try values.decodeIfPresent([ImageAttempt].self, forKey: .attempts) {
                self.attempts = attempts
            } else {
                // Upgrade the first preview's journal conservatively: none of these
                // paths was confirmed canonical by that client.
                attempts = try values.decode([String].self, forKey: .imagePaths).map {
                    ImageAttempt(requestedPath: $0)
                }
            }
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(scope, forKey: .scope)
            try values.encode(runtimeID, forKey: .runtimeID)
            try values.encode(attempts, forKey: .attempts)
            try values.encode(submitted, forKey: .submitted)
            try values.encode(aliases, forKey: .aliases)
        }
    }

    private struct InvalidAcknowledgement: Error {}

    private let fileURL: URL
    private var pending: [ComposerScope: Pending] = [:]
    private var inProgress = Set<ComposerScope>()
    private var unreadable = false

    public init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talaria", isDirectory: true)
        fileURL = directory.appendingPathComponent("pending-sends-v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                for entry in try JSONDecoder().decode([Pending].self, from: Data(contentsOf: fileURL)) {
                    guard pending[entry.scope] == nil else { throw AttachmentSendError.unreadableJournal }
                    pending[entry.scope] = entry
                }
            } catch { unreadable = true }
        }
    }

    public func hasPending(_ scope: ComposerScope) -> Bool {
        unreadable || pending.values.contains { $0.scope == scope || $0.aliases.contains(scope) }
    }

    /// Stored IDs can rotate during a turn. The connection/profile and live runtime
    /// also identify the journal, so that rotation cannot unlock a send in progress.
    public func hasPending(_ scope: ComposerScope, runtimeID: RuntimeSessionID) -> Bool {
        observeAlias(scope, runtimeID: runtimeID.rawValue)
        return unreadable || !matchingKeys(scope, runtimeID: runtimeID.rawValue).isEmpty
    }

    public func submit(text: String, attachments: [UploadedAttachment], scope: ComposerScope,
                       runtimeID: RuntimeSessionID, request: @escaping Request) async throws -> JSONValue {
        guard !unreadable else { throw AttachmentSendError.unreadableJournal }
        guard matchingKeys(scope, runtimeID: runtimeID.rawValue).isEmpty,
              inProgress.insert(scope).inserted else { throw AttachmentSendError.reconciliationRequired }
        defer { inProgress.remove(scope) }
        let prompt = try AttachmentPrompt.compose(text: text, attachments: attachments, scope: scope)
        let paths = attachments.filter { $0.kind == .image }.map(\.hostPath)
        guard paths.allSatisfy(Self.validHostPath) else {
            throw AttachmentSendError.preparationFailed("An uploaded image has an invalid host path. Choose it again.")
        }
        pending[scope] = Pending(scope: scope, runtimeID: runtimeID.rawValue)
        do { try save() } catch {
            pending.removeValue(forKey: scope)
            throw AttachmentSendError.preparationFailed("Talaria could not save the send state on this device.")
        }
        do {
            for path in paths {
                try Task.checkCancellation()
                // Record only an attempted RPC, before sending it. A lost ACK must
                // never erase the possibility that this path reached the queue.
                pending[scope]?.attempts.append(ImageAttempt(requestedPath: path))
                try save()
                let result = try await request("image.attach", params(scope, runtimeID.rawValue, path: path), 60)
                if result["attached"]?.boolValue == true,
                   let canonical = result["path"]?.stringValue, Self.validHostPath(canonical) {
                    let index = (pending[scope]?.attempts.count ?? 1) - 1
                    pending[scope]?.attempts[index].canonicalPath = canonical
                    try save()
                } else { throw InvalidAcknowledgement() }
                // No list RPC exists. A count mismatch detects another client's
                // queued images or consumption; remove only our own known paths.
                guard result["count"]?.intValue == pending[scope]?.attempts.count else {
                    throw InvalidAcknowledgement()
                }
            }
            try Task.checkCancellation()
        } catch {
            do { try await clearImages(for: scope, request: request) }
            catch { throw AttachmentSendError.reconciliationRequired }
            throw AttachmentSendError.preparationFailed("The images could not be prepared. The prompt was not sent.")
        }
        pending[scope]?.submitted = true
        do { try save() } catch { throw AttachmentSendError.reconciliationRequired }
        var submitParams: [String: JSONValue] = [
            "session_id": .string(runtimeID.rawValue), "profile": .string(scope.profile), "text": .string(prompt)
        ]
        // Document references need the new-turn preprocessor too. On a busy
        // session they must not become an unexpanded steer/redirect instruction.
        if !attachments.isEmpty { submitParams["queued"] = .bool(true) }
        let result: JSONValue
        do { result = try await request("prompt.submit", .object(submitParams), 1_800) }
        catch { throw AttachmentSendError.uncertain }

        if result["voice_stopped"]?.boolValue == true,
           result["status"] == nil || result["status"] == .null {
            // The typed stop-phrase branch returns before queue consumption.
            do { try await clearImages(for: scope, request: request) }
            catch { throw AttachmentSendError.reconciliationRequired }
            return result
        }
        guard result["voice_stopped"]?.boolValue != true,
              let status = result["status"]?.stringValue,
              ["streaming", "queued", "steered", "redirected"].contains(status),
              attachments.isEmpty || status == "streaming" || status == "queued" else {
            throw AttachmentSendError.uncertain
        }
        // Queued ACKs claim images synchronously into the queued turn. Streaming
        // ACKs precede agent startup/admission and can leave images behind if that
        // startup fails or is interrupted: retain them until authoritative idle.
        if status == "queued" || paths.isEmpty { try removePending(scope) }
        return result
    }

    public func reconcile(_ scope: ComposerScope, isIdle: Bool, request: @escaping Request) async throws {
        let keys = pending.values.filter { $0.scope == scope || $0.aliases.contains(scope) }.map(\.scope)
        try await reconcileKeys(keys, isIdle: isIdle, request: request)
    }

    /// Hydrate first; idle means neither running nor queued. A resumed runtime can
    /// differ from the journal's runtime, so cleanup targets the recorded one.
    public func reconcile(_ scope: ComposerScope, runtimeID: RuntimeSessionID,
                          isIdle: Bool, request: @escaping Request) async throws {
        observeAlias(scope, runtimeID: runtimeID.rawValue)
        try await reconcileKeys(matchingKeys(scope, runtimeID: runtimeID.rawValue), isIdle: isIdle, request: request)
    }

    private func reconcileKeys(_ keys: [ComposerScope], isIdle: Bool, request: Request) async throws {
        guard !unreadable else { throw AttachmentSendError.unreadableJournal }
        guard !keys.isEmpty else { return }
        guard isIdle, keys.allSatisfy({ !inProgress.contains($0) }) else {
            throw AttachmentSendError.reconciliationRequired
        }
        inProgress.formUnion(keys)
        defer { inProgress.subtract(keys) }
        for key in keys { try await clearImages(for: key, request: request) }
    }

    private func matchingKeys(_ scope: ComposerScope, runtimeID: String) -> [ComposerScope] {
        pending.values.filter {
            $0.scope.connectionID == scope.connectionID && $0.scope.profile == scope.profile &&
            ($0.scope == scope || $0.aliases.contains(scope) || $0.runtimeID == runtimeID)
        }.map(\.scope)
    }

    private func observeAlias(_ scope: ComposerScope, runtimeID: String) {
        guard !unreadable else { return }
        var changed = false
        for key in matchingKeys(scope, runtimeID: runtimeID) {
            guard pending[key]?.scope != scope, pending[key]?.aliases.contains(scope) == false else { continue }
            // Keep the dictionary key stable while submit is suspended in an RPC.
            // This alias also survives a process restart that assigns a new runtime.
            pending[key]?.aliases.append(scope)
            changed = true
        }
        if changed {
            do { try save() }
            catch { unreadable = true } // Fail closed rather than forget an observed rotation.
        }
    }

    private func clearImages(for scope: ComposerScope, request: Request) async throws {
        guard let entry = pending[scope] else { return }
        for attempt in entry.attempts {
            let path = attempt.canonicalPath ?? attempt.requestedPath
            do {
                let result = try await request("image.detach", params(scope, entry.runtimeID, path: path), 30)
                guard let detached = result["detached"]?.boolValue,
                      let count = result["count"]?.intValue, count >= 0 else {
                    throw AttachmentSendError.reconciliationRequired
                }
                // With a lost attach ACK, raw HTTP upload paths may differ from
                // the server's canonical path (e.g. a symlinked HERMES_HOME).
                // False alone does not prove removal. Empty queue does; otherwise
                // preserve the journal and require the old runtime to be reset.
                guard attempt.canonicalPath != nil || detached || count == 0 else {
                    throw AttachmentSendError.reconciliationRequired
                }
            } catch let error as JSONRPCError where error.code == 4001 {
                // This runtime no longer exists, therefore its image queue is gone.
                break
            }
        }
        try removePending(scope)
    }

    private func removePending(_ scope: ComposerScope) throws {
        guard let old = pending.removeValue(forKey: scope) else { return }
        do { try save() } catch {
            pending[scope] = old
            throw AttachmentSendError.reconciliationRequired
        }
    }
    private func params(_ scope: ComposerScope, _ runtime: String, path: String) -> JSONValue {
        .object(["session_id": .string(runtime), "profile": .string(scope.profile), "path": .string(path)])
    }
    private static func validHostPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return false }
        let chars = Array(path)
        return path.hasPrefix("/") || path.hasPrefix("\\\\") ||
            (chars.count > 2 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "/" || chars[2] == "\\"))
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Array(pending.values)).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public enum AttachmentSendError: Error, LocalizedError, Sendable, Equatable {
    case preparationFailed(String), reconciliationRequired, uncertain, unreadableJournal
    public var errorDescription: String? {
        switch self {
        case .preparationFailed(let message): message
        case .reconciliationRequired: "Reconnect to check the previous send and clear unused image attachments. If cleanup cannot be confirmed, restart the Hermes runtime."
        case .uncertain: "The send could not be confirmed. Reconnect to check its outcome; Talaria will not send it again automatically."
        case .unreadableJournal: "Saved send state could not be read. Talaria cannot safely reuse this session's image queue."
        }
    }
}
