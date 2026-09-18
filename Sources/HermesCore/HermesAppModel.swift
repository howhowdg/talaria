import Foundation
import Observation
import HermesProtocol
import HermesTransport

@MainActor @Observable
public final class HermesAppModel {
    public private(set) var endpoint: GatewayEndpoint?
    public private(set) var isConnected = false
    public private(set) var isConnecting = false
    public private(set) var isLoadingSession = false
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var conversations: [StoredSessionID: ConversationState] = [:]
    public private(set) var selectedID: StoredSessionID?
    public var banner: String?
    public var showConnection = false
    public var showSessionSettings = false
    public var searchText = ""
    public var draft = "" {
        didSet { if let composerScope { draftStore.setText(draft, for: composerScope) } }
    }
    public private(set) var settingsSnapshot: GatewaySettingsSnapshot?
    public private(set) var isLoadingSettings = false
    public private(set) var isApplyingSettings = false
    public private(set) var settingsError: String?
    public private(set) var attachmentDrafts: [ComposerScope: [AttachmentItem]] = [:]
    public private(set) var submittingScopes = Set<ComposerScope>()
    public private(set) var savedEndpoint: GatewayEndpoint?
    public private(set) var mobileActivity = MobileActivitySnapshot()
    public private(set) var isLoadingMobileActivity = false
    public private(set) var mobileActivityError: String?
    public private(set) var mobilePendingInputs: [MobilePendingInput] = []
    private var seenMobileRunIDs = Set<String>()
    @ObservationIgnored private let mobileActivityLoader: MobileActivityLoader?
    @ObservationIgnored private var mobileActivityTask: Task<MobileActivitySnapshot, Error>?
    @ObservationIgnored private var mobileActivityRevision = 0
    @ObservationIgnored private var client: GatewayClient
    @ObservationIgnored private let clientFactory: @MainActor () -> GatewayClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let draftStore: DraftStore
    @ObservationIgnored private let sender: AttachmentSender
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var uploadedAttachments: [UUID: UploadedAttachment] = [:]
    @ObservationIgnored private var attachmentWorkspaces: [UUID: String] = [:]
    @ObservationIgnored private var backgroundHydrations = Set<StoredSessionID>()
    @ObservationIgnored private var composerAliases: [ComposerScope: ComposerScope] = [:]
    @ObservationIgnored private var attachmentTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var importingScopes = Set<ComposerScope>()
    @ObservationIgnored private var settingsRevision = 0
    @ObservationIgnored private var listRevision = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRequests: [RPCID: GatewayServerRequest] = [:]
    private struct SnapshotWaiter {
        let runtimeID: String
        let after: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    @ObservationIgnored private var snapshotVersion = 0
    @ObservationIgnored private var appliedSnapshots: [String: Int] = [:]
    @ObservationIgnored private var snapshotWaiters: [SnapshotWaiter] = []

    public init(defaults: UserDefaults = .standard, draftStore: DraftStore? = nil,
                sender: AttachmentSender = AttachmentSender(),
                mobileActivityLoader: MobileActivityLoader? = nil,
                clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() }) {
        self.defaults = defaults; self.draftStore = draftStore ?? DraftStore(); self.sender = sender
        self.clientFactory = clientFactory; client = clientFactory()
        self.mobileActivityLoader = mobileActivityLoader
        if let data = defaults.data(forKey: "gateway.endpoint") {
            savedEndpoint = try? JSONDecoder().decode(GatewayEndpoint.self, from: data)
        }
    }

    public var conversation: ConversationState? { selectedID.flatMap { conversations[$0] } }
    public var unreadMobileRunCount: Int {
        mobileActivity.runs.filter { !$0.isActive && !seenMobileRunIDs.contains($0.id) }.count
    }

    public func refreshMobileActivity() async {
        guard isConnected, !isLoadingMobileActivity, let endpoint, let token else { return }
        let stamp = generation
        mobileActivityRevision += 1; let revision = mobileActivityRevision
        let client = client; let loader = mobileActivityLoader
        isLoadingMobileActivity = true; mobileActivityError = nil
        let task = Task {
            if let loader { return try await loader(client, endpoint, token) }
            return try await MobileActivityService(client: client,
                reader: GatewayReader(endpoint: endpoint, token: token)).load(profile: endpoint.profile)
        }
        mobileActivityTask = task
        defer {
            if generation == stamp, mobileActivityRevision == revision {
                isLoadingMobileActivity = false; mobileActivityTask = nil
            }
        }
        do {
            let snapshot = try await task.value
            guard generation == stamp, mobileActivityRevision == revision, isConnected else { return }
            mobileActivity = snapshot
        } catch {
            guard generation == stamp, mobileActivityRevision == revision, !(error is CancellationError) else { return }
            mobileActivityError = safeDescription(error)
        }
    }

    public func markMobileRunsSeen() {
        guard isConnected, let endpoint else { return }
        let current = mobileActivity.runs.filter { !$0.isActive }.map(\.id)
        let retained = current + seenMobileRunIDs.sorted().filter { !current.contains($0) }
        seenMobileRunIDs = Set(retained.prefix(2_000))
        defaults.set(seenMobileRunIDs.sorted(), forKey: mobileSeenKey(endpoint))
    }

    private func mobileSeenKey(_ endpoint: GatewayEndpoint) -> String {
        let parts = [endpoint.id.uuidString, endpoint.baseURL.absoluteString, endpoint.profile]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "mobile.activity.seen." + data.base64EncodedString()
    }

    private func resetMobileActivity(for endpoint: GatewayEndpoint? = nil) {
        mobileActivityTask?.cancel(); mobileActivityTask = nil; mobileActivityRevision += 1
        mobileActivity = MobileActivitySnapshot(); mobileActivityError = nil
        isLoadingMobileActivity = false; mobilePendingInputs = []
        seenMobileRunIDs = endpoint.map { Set((defaults.stringArray(forKey: mobileSeenKey($0)) ?? []).prefix(2_000)) } ?? []
    }
    public var composerScope: ComposerScope? {
        guard let endpoint, let selectedID else { return nil }
        return ComposerScope(connectionID: endpoint.id, profile: endpoint.profile, storedSessionID: selectedID)
    }
    public var attachments: [AttachmentItem] { composerScope.flatMap { attachmentDrafts[$0] } ?? [] }
    public var isSubmitting: Bool { composerScope.map { submittingScopes.contains($0) } ?? false }
    public var isTransferringAttachments: Bool {
        attachments.contains { $0.state == .reading || $0.state == .uploading }
    }
    public var canAttach: Bool {
        isConnected && conversation != nil && !isLoadingSession && !isSubmitting && !isTransferringAttachments
            && conversation?.isRunning != true && conversation?.requiresHydration != true
            && conversation?.hasQueuedPrompt != true
            && attachments.count < AttachmentLoader.maximumCount
    }
    public var filteredSessions: [SessionSummary] {
        searchText.isEmpty ? sessions : sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText) || $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }
    public var canSend: Bool {
        isConnected && !isLoadingSession && conversation != nil && conversation?.isRunning != true
            && conversation?.requiresHydration != true
            && conversation?.hasQueuedPrompt != true
            && !isSubmitting && !isApplyingSettings && attachments.allSatisfy { $0.state == .ready }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public func connect(to endpoint: GatewayEndpoint, token suppliedToken: String?, remember: Bool = false) async {
        guard !isConnecting, !isApplyingSettings else { return }
        let sameHost = self.endpoint?.id == endpoint.id && self.endpoint?.baseURL == endpoint.baseURL
        let sameConnection = self.endpoint?.id == endpoint.id
            && self.endpoint?.baseURL == endpoint.baseURL && self.endpoint?.profile == endpoint.profile
        let owner = SessionOwner(connectionID: endpoint.id, profile: endpoint.profile)
        let previous = sameConnection ? selectedID : draftStore.selectedSession(for: owner)
        let previousToken = sameHost ? token : nil
        let stamp = UUID(); generation = stamp
        resetMobileActivity(for: endpoint)
        releaseSnapshotWaiters()
        appliedSnapshots = [:]
        receiver?.cancel(); refreshTask?.cancel()
        cancelAttachmentTransfers()
        isConnecting = true; isConnected = false; banner = nil
        let oldClient = client
        let client = clientFactory(); self.client = client
        await oldClient.disconnect()
        guard generation == stamp else { return }
        selectedID = nil
        self.endpoint = endpoint
        // Runtime IDs and replay cursors belong to a socket attachment. Rehydrate on every reconnect.
        conversations = [:]; selectedID = nil; draft = ""; isLoadingSession = false
        pendingRequests = [:]
        settingsSnapshot = nil; settingsError = nil; isLoadingSettings = false
        backgroundHydrations = []
        sessions = []
        do {
            let selectedToken: String?
            if let suppliedToken, !suppliedToken.isEmpty { selectedToken = suppliedToken }
            else if let previousToken { selectedToken = previousToken }
            else { selectedToken = try credentials.read(account: endpoint.id.uuidString) }
            token = selectedToken
            let updates = await client.updates()
            receiver = Task { [weak self] in
                for await update in updates {
                    guard let self, !Task.isCancelled, self.generation == stamp else { return }
                    await self.handle(update, generation: stamp)
                }
            }
            try await client.connect(to: endpoint, token: selectedToken)
            guard generation == stamp else { return }
            isConnected = true; isConnecting = false; showConnection = false
            if remember {
                do {
                    try credentials.save(selectedToken ?? "", account: endpoint.id.uuidString)
                    defaults.set(try JSONEncoder().encode(endpoint), forKey: "gateway.endpoint")
                    savedEndpoint = endpoint
                } catch { banner = "Connected, but the connection could not be saved to Keychain." }
            }
            await refreshSessions()
            if let previous { await openSession(previous, force: true) }
        } catch {
            guard generation == stamp else { return }
            isConnecting = false; isConnected = false
            banner = safeDescription(error)
        }
    }

    public func reconnect() async {
        if let endpoint { await connect(to: endpoint, token: token) }
        else { showConnection = true }
    }

    public func persistDrafts() {
        do { try draftStore.flush() } catch { banner = draftStore.lastError }
    }

    public func disconnect() async {
        generation = UUID(); receiver?.cancel(); refreshTask?.cancel()
        resetMobileActivity()
        releaseSnapshotWaiters()
        cancelAttachmentTransfers()
        do { try draftStore.flush() } catch { banner = draftStore.lastError }
        let client = client
        await client.disconnect()
        isConnected = false; isConnecting = false; isLoadingSession = false
        isApplyingSettings = false; isLoadingSettings = false
        pendingRequests = [:]
        for id in conversations.keys { conversations[id]?.pendingInputs = [] }
    }

    public func refreshSessions() async {
        guard isConnected, let endpoint else { return }
        let client = client
        let stamp = generation
        listRevision += 1; let revision = listRevision
        do {
            let result = try await client.request("session.list", params: .object([
                "profile": .string(endpoint.profile), "limit": .number(100)
            ]))
            guard generation == stamp, revision == listRevision else { return }
            sessions = (result["sessions"]?.arrayValue ?? []).map(SessionSummary.init).filter { !$0.id.rawValue.isEmpty }
        } catch { if generation == stamp { banner = safeDescription(error) } }
    }

    public func newConversation() async {
        guard isConnected, !isLoadingSession, let endpoint else { return }
        let client = client
        let stamp = generation; isLoadingSession = true
        let beforeSnapshot = snapshotVersion
        defer { if generation == stamp { isLoadingSession = false } }
        do {
            // Until native preview/terminal bridges exist, do not enable desktop_ui tools.
            let result = try await client.request("session.create", params: .object([
                "profile": .string(endpoint.profile), "source": .string("native")
            ]), timeout: 90)
            await waitForSnapshot(result, after: beforeSnapshot, generation: stamp)
            if generation == stamp { await refreshSessions() }
        } catch { if generation == stamp { banner = safeDescription(error) } }
    }

    public func openSession(_ id: StoredSessionID, force: Bool = false) async {
        guard isConnected, !isLoadingSession, let endpoint else { return }
        let client = client
        if !force, let cached = conversations[id], !cached.requiresHydration { select(id); return }
        let stamp = generation; isLoadingSession = true
        let beforeSnapshot = snapshotVersion
        defer { if generation == stamp { isLoadingSession = false } }
        do {
            let result = try await client.request("session.resume", params: .object([
                "session_id": .string(id.rawValue), "profile": .string(endpoint.profile),
                "source": .string("native")
            ]), timeout: 90)
            await waitForSnapshot(result, after: beforeSnapshot, generation: stamp)
        } catch { if generation == stamp { banner = safeDescription(error) } }
    }

    public func send() async {
        guard canSend, let id = selectedID, let state = conversations[id], let scope = composerScope else { return }
        let client = client
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = attachmentDrafts[scope] ?? []
        let uploaded = items.compactMap { uploadedAttachments[$0.id] }
        guard uploaded.count == items.count else { return }
        invalidateAttachments(for: state)
        guard canSend else { return }
        let stamp = generation
        submittingScopes.insert(scope)
        defer {
            let current = resolvedScope(scope)
            submittingScopes = submittingScopes.filter { resolvedScope($0) != current }
        }
        let displayText = ([text] + uploaded.map { "Attached: \($0.filename)" }).filter { !$0.isEmpty }.joined(separator: "\n")
        draft = ""
        let optimisticID = conversations[id]?.beginSubmission(text: displayText)
        do {
            let result = try await sender.submit(text: text, attachments: uploaded, scope: scope, runtimeID: state.runtimeID,
                request: { method, params, timeout in try await client.request(method, params: params, timeout: timeout) })
            if result["voice_stopped"]?.boolValue == true {
                restoreUnsent(text, scope: scope, optimisticID: optimisticID, generation: stamp)
                if generation == stamp { banner = "The host stopped voice capture. This message was not submitted." }
                return
            }
            for item in items {
                uploadedAttachments.removeValue(forKey: item.id)
                attachmentWorkspaces.removeValue(forKey: item.id)
            }
            attachmentDrafts[resolvedScope(scope)] = []
            if generation == stamp, let current = conversations.values.first(where: { $0.runtimeID == state.runtimeID }) {
                await recoverAttachments(after: current, generation: stamp)
            }
        } catch {
            if case AttachmentSendError.preparationFailed = error {
                restoreUnsent(text, scope: scope, optimisticID: optimisticID, generation: stamp)
                if generation == stamp { banner = safeDescription(error) }
                return
            }
            for item in items {
                updateAttachment(resolvedScope(scope), item: AttachmentItem(id: item.id, filename: item.filename,
                    kind: item.kind, byteCount: item.byteCount,
                    state: .failed("Check the previous send in history, then remove or attach this file again.")))
            }
            guard generation == stamp else { return }
            banner = safeDescription(error)
            conversations[resolvedScope(scope).storedSessionID]?.requiresHydration = true
        }
    }

    private func restoreUnsent(_ text: String, scope: ComposerScope, optimisticID: String?, generation stamp: UUID) {
        let scope = resolvedScope(scope)
        // Preserve anything typed while the request was pending, including in another profile.
        let current = draftStore.text(for: scope)
        let restored = current.isEmpty ? text : text + "\n" + current
        draftStore.setText(restored, for: scope)
        if composerScope == scope { draft = restored }
        if generation == stamp, let optimisticID {
            conversations[scope.storedSessionID]?.cancelUnsentSubmission(optimisticID)
        }
    }

    public func stop() async {
        guard isConnected, let id = selectedID, let state = conversations[id] else { return }
        let client = client
        let stamp = generation
        do {
            _ = try await client.request("session.interrupt", params: .object([
                "session_id": .string(state.runtimeID.rawValue), "profile": .string(state.owner.profile)
            ]))
            if generation == stamp { conversations[id]?.markStopping() }
        } catch { if generation == stamp { banner = safeDescription(error) } }
    }

    public func answer(_ input: PendingInput, result: JSONValue) async -> Bool {
        guard isConnected else { return false }
        let client = client
        let stamp = generation
        do {
            try await client.respond(to: input.id, result: result)
            guard generation == stamp else { return false }
            pendingRequests.removeValue(forKey: input.id)
            for id in conversations.keys { conversations[id]?.removeRequest(input.id) }
            updateMobilePendingInputs()
            return true
        } catch {
            if generation == stamp { banner = safeDescription(error) }
            return false
        }
    }

    public func loadSettings(refresh: Bool = false) async {
        guard isConnected, let endpoint else { return }
        let client = client; let stamp = generation; let selected = selectedID
        settingsRevision += 1; let revision = settingsRevision
        isLoadingSettings = true; settingsError = nil
        defer { if generation == stamp, settingsRevision == revision { isLoadingSettings = false } }
        do {
            let result = try await GatewaySettingsService(client: client).load(profile: endpoint.profile,
                sessionID: conversation?.runtimeID.rawValue, refresh: refresh)
            guard generation == stamp, selectedID == selected, settingsRevision == revision else { return }
            settingsSnapshot = result
        } catch {
            if generation == stamp, selectedID == selected, settingsRevision == revision { settingsError = safeDescription(error) }
        }
    }

    public func selectModel(_ selection: GatewayModelSelection, confirmed: Bool) async -> GatewaySettingChange? {
        guard isConnected, !isApplyingSettings, !isSubmitting, let state = conversation,
              !state.isRunning, !state.requiresHydration, !state.hasQueuedPrompt, state.pendingInputs.isEmpty else {
            settingsError = "Wait for the current turn to finish before changing its model."
            return nil
        }
        let client = client; let stamp = generation; let selected = selectedID
        isApplyingSettings = true; settingsError = nil
        defer { if generation == stamp { isApplyingSettings = false } }
        do {
            let change = try await GatewaySettingsService(client: client).selectModel(selection,
                profile: state.owner.profile, sessionID: state.runtimeID.rawValue, confirmed: confirmed)
            guard generation == stamp, selectedID == selected else { return nil }
            if !change.requiresConfirmation && !change.deferred { await loadSettings() }
            return change
        } catch {
            if generation == stamp { settingsError = safeDescription(error) }
            return nil
        }
    }

    public func selectProfile(_ profile: String) async -> Bool {
        guard isConnected, !isConnecting, !isApplyingSettings, !isSubmitting, var target = endpoint,
              settingsSnapshot?.profiles.contains(where: { $0.name == profile }) == true else { return false }
        if target.profile == profile { return true }
        guard !conversations.values.contains(where: { $0.isRunning || !$0.pendingInputs.isEmpty }),
              submittingScopes.isEmpty else {
            settingsError = "Finish or stop the current work before switching profiles."
            return false
        }
        target.profile = profile
        let remember = savedEndpoint?.id == target.id && savedEndpoint?.baseURL == target.baseURL
        await connect(to: target, token: token, remember: remember)
        if isConnected, endpoint?.profile == profile { await loadSettings(); return true }
        settingsError = banner ?? "The profile could not be connected."
        return false
    }

    public func addAttachments(_ urls: [URL], to scope: ComposerScope) async {
        guard canAttach, composerScope == scope, let endpoint, let token, let state = conversation,
              importingScopes.insert(scope).inserted else { return }
        defer { importingScopes.remove(scope) }
        let count = attachmentDrafts[scope]?.count ?? 0
        guard !urls.isEmpty, count + urls.count <= AttachmentLoader.maximumCount else {
            banner = AttachmentError.tooManyFiles.localizedDescription; return
        }
        let stamp = generation; let workspace = state.cwd
        let entries = urls.map { (UUID(), $0) }
        for (id, url) in entries {
            attachmentDrafts[scope, default: []].append(AttachmentItem(id: id, filename: url.lastPathComponent, state: .reading))
        }
        for (id, url) in entries {
            guard generation == stamp, isConnected,
                  attachmentDrafts[scope]?.contains(where: { $0.id == id && $0.state == .reading }) == true else { continue }
            let task = Task { [weak self] in
                do {
                    let staged = try await AttachmentLoader.read(url: url, scope: scope)
                    guard let self, self.generation == stamp, !Task.isCancelled,
                          self.attachmentDrafts[scope]?.contains(where: { $0.id == id }) == true else { return }
                    let bytes = (self.attachmentDrafts[scope] ?? []).compactMap(\.byteCount).reduce(0, +)
                    guard bytes + staged.byteCount <= AttachmentLoader.maximumBatchBytes else { throw AttachmentError.tooManyFiles }
                    self.updateAttachment(scope, item: AttachmentItem(id: id, filename: staged.filename,
                        kind: staged.kind, byteCount: staged.byteCount, state: .uploading, destination: endpoint.name))
                    let result = try await AttachmentTransferService().upload(staged, workspace: workspace, endpoint: endpoint, token: token)
                    guard self.generation == stamp, !Task.isCancelled,
                          self.attachmentDrafts[scope]?.contains(where: { $0.id == id }) == true else { return }
                    guard self.conversations[scope.storedSessionID]?.cwd == workspace else {
                        throw AttachmentError.workspaceUnavailable
                    }
                    self.uploadedAttachments[id] = result
                    self.attachmentWorkspaces[id] = workspace
                    self.updateAttachment(scope, item: AttachmentItem(id: id, filename: result.filename,
                        kind: result.kind, byteCount: result.byteCount, state: .ready, destination: result.hostPath))
                } catch {
                    guard let self, self.generation == stamp,
                          self.attachmentDrafts[scope]?.contains(where: { $0.id == id }) == true else { return }
                    let message = error is CancellationError ? "Upload cancelled. Remove this file to try again." : self.safeDescription(error)
                    self.updateAttachment(scope, item: AttachmentItem(id: id, filename: url.lastPathComponent, state: .failed(message)))
                }
            }
            attachmentTasks[id] = task
            await task.value
            attachmentTasks.removeValue(forKey: id)
        }
    }

    public func removeAttachment(_ id: UUID) {
        guard let scope = composerScope, !submittingScopes.contains(scope) else { return }
        attachmentTasks.removeValue(forKey: id)?.cancel()
        uploadedAttachments.removeValue(forKey: id)
        attachmentWorkspaces.removeValue(forKey: id)
        attachmentDrafts[scope]?.removeAll { $0.id == id }
    }

    private func invalidateAttachments(for state: ConversationState) {
        let scope = ComposerScope(owner: state.owner, sessionID: state.storedID)
        for item in attachmentDrafts[scope] ?? [] where item.state == .ready {
            guard uploadedAttachments[item.id]?.kind == .file,
                  attachmentWorkspaces[item.id] != state.cwd else { continue }
            uploadedAttachments.removeValue(forKey: item.id)
            attachmentWorkspaces.removeValue(forKey: item.id)
            updateAttachment(scope, item: AttachmentItem(id: item.id, filename: item.filename, kind: item.kind,
                byteCount: item.byteCount, state: .failed("The conversation's workspace changed. Attach this file again.")))
        }
    }

    private func updateAttachment(_ scope: ComposerScope, item: AttachmentItem) {
        guard let index = attachmentDrafts[scope]?.firstIndex(where: { $0.id == item.id }) else { return }
        attachmentDrafts[scope]?[index] = item
    }

    private func cancelAttachmentTransfers() {
        for task in attachmentTasks.values { task.cancel() }
        attachmentTasks.removeAll()
        for scope in attachmentDrafts.keys {
            attachmentDrafts[scope] = attachmentDrafts[scope]?.map { item in
                guard item.state == .reading || item.state == .uploading else { return item }
                return AttachmentItem(id: item.id, filename: item.filename, kind: item.kind, byteCount: item.byteCount,
                    state: .failed("Connection changed. Remove this file and attach it again."))
            }
        }
    }

    private func moveComposer(from old: ComposerScope, to new: ComposerScope) {
        composerAliases[old] = new
        if submittingScopes.contains(old) { submittingScopes.insert(new) }
        draftStore.move(from: old, to: new)
        if let items = attachmentDrafts.removeValue(forKey: old) {
            attachmentDrafts[new] = items.map { item in
                if let uploaded = uploadedAttachments[item.id] {
                    uploadedAttachments[item.id] = UploadedAttachment(id: uploaded.id, scope: new, filename: uploaded.filename,
                        kind: uploaded.kind, mimeType: uploaded.mimeType, byteCount: uploaded.byteCount,
                        hostPath: uploaded.hostPath, relativePath: uploaded.relativePath)
                    return item
                }
                attachmentTasks.removeValue(forKey: item.id)?.cancel()
                return AttachmentItem(id: item.id, filename: item.filename, state: .failed("Conversation changed. Attach this file again."))
            }
        }
    }

    private func resolvedScope(_ scope: ComposerScope) -> ComposerScope {
        var current = scope
        var visited = Set<ComposerScope>()
        while visited.insert(current).inserted, let next = composerAliases[current] { current = next }
        return current
    }

    /// A wire ACK publishes a snapshot before completing the RPC, but its UI
    /// reducer can still be suspended on the send journal. Keep restoration busy
    /// until that ordered snapshot has actually been applied.
    private func waitForSnapshot(_ result: JSONValue, after version: Int, generation stamp: UUID) async {
        guard generation == stamp, isConnected, let runtime = result["session_id"]?.stringValue,
              !runtime.isEmpty, (appliedSnapshots[runtime] ?? -1) <= version else { return }
        await withCheckedContinuation { continuation in
            snapshotWaiters.append(SnapshotWaiter(runtimeID: runtime, after: version, continuation: continuation))
        }
    }

    private func finishSnapshot(_ result: JSONValue) {
        guard let runtime = result["session_id"]?.stringValue else { return }
        snapshotVersion += 1
        appliedSnapshots[runtime] = snapshotVersion
        let finished = snapshotWaiters.filter { $0.runtimeID == runtime && $0.after < snapshotVersion }
        snapshotWaiters.removeAll { $0.runtimeID == runtime && $0.after < snapshotVersion }
        for waiter in finished { waiter.continuation.resume() }
    }

    private func releaseSnapshotWaiters() {
        let waiting = snapshotWaiters
        snapshotWaiters = []
        for waiter in waiting { waiter.continuation.resume() }
    }

    private func select(_ id: StoredSessionID) {
        if selectedID != id {
            selectedID = id
            if let scope = composerScope {
                draft = draftStore.text(for: scope)
                draftStore.select(id, owner: SessionOwner(connectionID: scope.connectionID, profile: scope.profile))
            }
            settingsSnapshot = nil
        }
    }

    private func recoverAttachments(after state: ConversationState, generation stamp: UUID) async {
        let scope = ComposerScope(owner: state.owner, sessionID: state.storedID)
        let pending = await sender.hasPending(scope, runtimeID: state.runtimeID)
        guard pending || state.hasQueuedPrompt, generation == stamp, isConnected else { return }
        conversations[state.storedID]?.requiresHydration = true
        guard !state.isRunning,
              backgroundHydrations.insert(state.storedID).inserted else { return }
        let client = client
        Task { [weak self] in
            do {
                _ = try await client.request("session.resume", params: .object([
                    "session_id": .string(state.storedID.rawValue), "profile": .string(state.owner.profile),
                    "source": .string("native")
                ]), timeout: 90)
            } catch {
                guard let self, self.generation == stamp else { return }
                self.backgroundHydrations.remove(state.storedID)
                self.banner = self.safeDescription(error)
            }
        }
    }

    private func handle(_ update: GatewayUpdate, generation stamp: UUID) async {
        guard generation == stamp, let endpoint else { return }
        let client = client
        switch update {
        case .connected: isConnected = true
        case .disconnected(let reason):
            isConnected = false
            resetMobileActivity()
            releaseSnapshotWaiters()
            cancelAttachmentTransfers()
            pendingRequests = [:]
            if let reason { banner = reason + " Reconnect to restore the conversation." }
            for id in conversations.keys { conversations[id]?.pendingInputs = [] }
        case .snapshot(_, let result):
            defer { if generation == stamp { finishSnapshot(result) } }
            do {
                var state = try ConversationState(snapshot: result,
                    owner: SessionOwner(connectionID: endpoint.id, profile: endpoint.profile))
                let scope = ComposerScope(owner: state.owner, sessionID: state.storedID)
                let background = backgroundHydrations.remove(state.storedID) != nil
                if await sender.hasPending(scope, runtimeID: state.runtimeID) {
                    // Do not block receive order while reconciling the queue. The session stays locked.
                    state.requiresHydration = true
                    let idle = !state.isRunning && !state.hasQueuedPrompt
                    let runtime = state.runtimeID
                    if idle { Task { [weak self] in
                        do {
                            try await self?.sender.reconcile(scope, runtimeID: runtime, isIdle: idle,
                                request: { method, params, timeout in try await client.request(method, params: params, timeout: timeout) })
                            guard let self, self.generation == stamp else { return }
                            self.conversations[scope.storedSessionID]?.requiresHydration = false
                        } catch {
                            guard let self, self.generation == stamp else { return }
                            // Completion may precede the submit ACK. The submit continuation
                            // requests another snapshot once the journal is no longer in flight.
                            if error as? AttachmentSendError == .reconciliationRequired,
                               self.submittingScopes.contains(self.resolvedScope(scope)) { return }
                            self.banner = self.safeDescription(error)
                        }
                    } }
                }
                guard generation == stamp else { return }
                conversations[state.storedID] = state
                invalidateAttachments(for: state)
                attachPendingRequests()
                if !background { select(state.storedID) }
            } catch { banner = safeDescription(error) }
        case .event(let event):
            if event.type == "request.cancel", let raw = event.payload["id"]?.stringValue {
                pendingRequests.removeValue(forKey: .string(raw))
            }
            for id in Array(conversations.keys) {
                conversations[id]?.apply(event)
                if let state = conversations[id], state.storedID != id {
                    conversations.removeValue(forKey: id); conversations[state.storedID] = state
                    moveComposer(from: ComposerScope(owner: state.owner, sessionID: id),
                                 to: ComposerScope(owner: state.owner, sessionID: state.storedID))
                    if selectedID == id { selectedID = state.storedID }
                    _ = await sender.hasPending(ComposerScope(owner: state.owner, sessionID: state.storedID), runtimeID: state.runtimeID)
                    guard generation == stamp else { return }
                }
            }
            updateMobilePendingInputs()
            for state in conversations.values {
                invalidateAttachments(for: state)
                if event.type == "message.complete", event.sessionID == state.runtimeID.rawValue || event.sessionID == state.storedID.rawValue {
                    await recoverAttachments(after: state, generation: stamp)
                }
            }
            if event.type == "session.reclaimed" {
                let reclaimed = [event.payload["session_id"]?.stringValue, event.payload["stored_session_id"]?.stringValue].compactMap { $0 }
                for id in conversations.keys {
                    if let state = conversations[id], reclaimed.contains(state.runtimeID.rawValue) || reclaimed.contains(state.storedID.rawValue) {
                        conversations[id]?.requiresHydration = true
                        conversations[id]?.status = "Reconnect required"
                        if selectedID == id { banner = "Hermes reclaimed this live session. Reconnect to restore it from history." }
                    }
                }
            }
            if ["sessions.changed", "session.title", "message.complete"].contains(event.type) {
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await self?.refreshSessions()
                }
            }
        case .request(let request):
            let supported = ["approval", "clarify", "secret", "sudo", "vault.code", "vault.unlock_prompt", "vault.save_login"]
            guard supported.contains(request.method) else {
                try? await client.reject(request.id, code: -32601, message: "This native client does not support \(request.method) yet.")
                return
            }
            guard pendingRequests.count < 256 || pendingRequests[request.id] != nil else {
                banner = "Too many pending questions. Reconnect to refresh the session."
                await disconnect()
                return
            }
            pendingRequests[request.id] = request
            attachPendingRequests()
        }
    }

    private func attachPendingRequests() {
        for request in pendingRequests.values {
            let ids = [request.params["session_id"]?.stringValue, request.params["gateway_session_id"]?.stringValue].compactMap { $0 }
            for id in conversations.keys {
                if let state = conversations[id], ids.contains(state.runtimeID.rawValue) || ids.contains(state.storedID.rawValue) {
                    conversations[id]?.receive(request)
                }
            }
        }
        updateMobilePendingInputs()
    }

    private func updateMobilePendingInputs() {
        guard let endpoint, isConnected else { mobilePendingInputs = []; return }
        let owner = SessionOwner(connectionID: endpoint.id, profile: endpoint.profile)
        mobilePendingInputs = pendingRequests.values.map { request in
            let ids = [request.params["session_id"]?.stringValue,
                       request.params["gateway_session_id"]?.stringValue].compactMap { $0 }
            let state = conversations.values.first {
                $0.owner == owner && (ids.contains($0.runtimeID.rawValue) || ids.contains($0.storedID.rawValue))
            }
            return MobilePendingInput(input: PendingInput(request), state: state)
        }.sorted { $0.id < $1.id }
    }

    private func safeDescription(_ error: Error) -> String {
        var text = error.localizedDescription
        if let token, !token.isEmpty { text = text.replacingOccurrences(of: token, with: "[redacted]") }
        return text
    }
}
