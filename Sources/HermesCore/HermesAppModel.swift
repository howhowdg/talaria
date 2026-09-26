import Foundation
import Observation
import HermesProtocol
import HermesTransport

@MainActor @Observable
public final class HermesAppModel {
    public private(set) var endpoint: GatewayEndpoint?
    public private(set) var isConnected = false
    public private(set) var isConnecting = false
    public private(set) var desiredConnection = false
    public private(set) var remembersSignIn = false
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
    public private(set) var hierarchyDestination: HierarchyDestination = .home
    public private(set) var homeAvailability: HomeAvailability = .unselected
    public private(set) var runDetails: [String: AutomationRunDetail] = [:]
    public private(set) var loadingRunIDs = Set<String>()
    public private(set) var loadingAutomationRunIDs = Set<String>()
    public private(set) var automationActionIDs = Set<String>()
    public private(set) var hierarchyError: String?
    public private(set) var activityRequestFocusID: RPCID?
    public var hierarchyFeatures = HierarchyFeatureFlags()
    public private(set) var telegramTopics: [TelegramTopic] = []
    public private(set) var isLoadingTelegramTopics = false
    public private(set) var telegramTopicsError: String?
    @ObservationIgnored private var hasLoadedTelegramTopics = false
    @ObservationIgnored private var telegramTopicsRevision = 0
    @ObservationIgnored private let telegramTopicsLoader: TelegramTopicsLoader?
    public let classificationStore: HierarchyClassificationStore
    private var seenMobileRunIDs = Set<String>()
    private var requestReceiptStore: [ComposerScope: [RequestReceipt]] = [:]
    @ObservationIgnored private let mobileActivityLoader: MobileActivityLoader?
    @ObservationIgnored private let runDetailLoader: AutomationRunDetailLoader?
    @ObservationIgnored private let automationRunsLoader: AutomationRunsLoader?
    @ObservationIgnored private var automationRefreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var mobileActivityTask: Task<MobileActivitySnapshot, Error>?
    @ObservationIgnored private var mobileActivityRevision = 0
    @ObservationIgnored private var client: GatewayClient
    @ObservationIgnored private let clientFactory: @MainActor () -> GatewayClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let draftStore: DraftStore
    @ObservationIgnored private let sender: AttachmentSender
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private var session: GatewaySession?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var hierarchyNavigationRevision = 0
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var activeEndpoint: GatewayEndpoint?
    @ObservationIgnored private var sshReconnectHandler: (@MainActor () async throws -> (GatewayEndpoint, String?))?
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
                credentials: CredentialStore = CredentialStore(),
                mobileActivityLoader: MobileActivityLoader? = nil,
                runDetailLoader: AutomationRunDetailLoader? = nil,
                automationRunsLoader: AutomationRunsLoader? = nil,
                telegramTopicsLoader: TelegramTopicsLoader? = nil,
                clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() }) {
        self.credentials = credentials
        self.classificationStore = HierarchyClassificationStore(defaults: defaults)
        self.defaults = defaults; self.draftStore = draftStore ?? DraftStore(); self.sender = sender
        self.clientFactory = clientFactory; client = clientFactory()
        self.mobileActivityLoader = mobileActivityLoader
        self.runDetailLoader = runDetailLoader
        self.automationRunsLoader = automationRunsLoader
        self.telegramTopicsLoader = telegramTopicsLoader
        if let data = defaults.data(forKey: "gateway.endpoint") {
            savedEndpoint = try? JSONDecoder().decode(GatewayEndpoint.self, from: data)
            remembersSignIn = defaults.object(forKey: "gateway.remember") as? Bool ?? (savedEndpoint != nil)
        }
    }

    public var conversation: ConversationState? { selectedID.flatMap { conversations[$0] } }
    public var unreadMobileRunCount: Int {
        mobileActivity.runs.filter { isRunUnread($0) }.count
    }

    public func refreshMobileActivity() async {
        guard isConnected, !isLoadingMobileActivity, loadingAutomationRunIDs.isEmpty, let endpoint, let session else { return }
        let stamp = generation
        mobileActivityRevision += 1; let revision = mobileActivityRevision
        let client = client; let loader = mobileActivityLoader
        isLoadingMobileActivity = true; mobileActivityError = nil
        let task = Task {
            if let loader { return try await loader(client, endpoint, session) }
            return try await MobileActivityService(client: client,
                reader: GatewayReader(session: session)).load(profile: endpoint.profile)
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
            let previousRuns = Dictionary(uniqueKeysWithValues: mobileActivity.runs.map { ($0.id, $0) })
            let changed = Set(snapshot.runs.compactMap { run -> String? in
                guard let previous = previousRuns[run.id] else { return nil }
                return previous != run ? run.id : nil
            })
            for id in changed { runDetails.removeValue(forKey: id) }
            mobileActivity = snapshot
            if case .run(let id) = hierarchyDestination, changed.contains(id) { await loadRunDetail(id) }
        } catch {
            guard generation == stamp, mobileActivityRevision == revision, !(error is CancellationError) else { return }
            mobileActivityError = safeDescription(error)
        }
    }

    public func markMobileRunsSeen() {
        guard isConnected, let endpoint else { return }
        let current = mobileActivity.runs.filter { !$0.isActive && $0.status.isTerminal }.map(\.id)
        let retained = current + seenMobileRunIDs.sorted().filter { !current.contains($0) }
        seenMobileRunIDs = Set(retained.prefix(2_000))
        defaults.set(seenMobileRunIDs.sorted(), forKey: mobileSeenKey(endpoint))
    }

    private func mobileSeenKey(_ endpoint: GatewayEndpoint) -> String {
        let parts = [endpoint.id.uuidString, endpoint.baseURL.absoluteString, endpoint.profile]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "mobile.activity.seen." + data.base64EncodedString()
    }

    private func resetMobileActivity(for endpoint: GatewayEndpoint? = nil, preserveLoaded: Bool = false) {
        for task in automationRefreshTasks.values { task.cancel() }
        automationRefreshTasks = [:]; loadingAutomationRunIDs = []
        mobileActivityTask?.cancel(); mobileActivityTask = nil; mobileActivityRevision += 1
        if !preserveLoaded { mobileActivity = MobileActivitySnapshot() }
        mobileActivityError = nil
        isLoadingMobileActivity = false; mobilePendingInputs = []
        if let endpoint {
            seenMobileRunIDs = Set((defaults.stringArray(forKey: mobileSeenKey(endpoint)) ?? []).prefix(2_000))
        } else if !preserveLoaded { seenMobileRunIDs = [] }
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
        isConnected && telegramDestinationIsReady && conversation != nil && !isLoadingSession && !isSubmitting && !isTransferringAttachments
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
        isConnected && telegramDestinationIsReady && !isLoadingSession && conversation != nil && conversation?.isRunning != true
            && conversation?.requiresHydration != true
            && conversation?.hasQueuedPrompt != true
            && !isSubmitting && !isApplyingSettings && attachments.allSatisfy { $0.state == .ready }
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    public func connect(to endpoint: GatewayEndpoint, token: String?, remember: Bool = false) async {
        await connect(to: endpoint, configuredEndpoint: endpoint, token: token, username: nil, password: nil, remember: remember)
    }

    public func connect(to endpoint: GatewayEndpoint, username: String, password: String, remember: Bool) async {
        await connect(to: endpoint, configuredEndpoint: endpoint, token: nil, username: username, password: password, remember: remember)
    }

    public func connect(to activeEndpoint: GatewayEndpoint, configuredEndpoint: GatewayEndpoint,
                        token: String?, remember: Bool = false) async {
        await connect(to: activeEndpoint, configuredEndpoint: configuredEndpoint, token: token,
                      username: nil, password: nil, remember: remember)
    }

    public func connect(to activeEndpoint: GatewayEndpoint, configuredEndpoint: GatewayEndpoint,
                        username: String, password: String, remember: Bool) async {
        await connect(to: activeEndpoint, configuredEndpoint: configuredEndpoint, token: nil,
                      username: username, password: password, remember: remember)
    }

    public func setSSHReconnectHandler(_ handler: (@MainActor () async throws -> (GatewayEndpoint, String?))?) {
        sshReconnectHandler = handler
    }

    private func connect(to active: GatewayEndpoint, configuredEndpoint endpoint: GatewayEndpoint,
                         token suppliedToken: String?, username: String?, password: String?, remember: Bool) async {
        guard !isConnecting, !isApplyingSettings else { return }
        guard active.id == endpoint.id, active.profile == endpoint.profile,
              active.authentication == endpoint.authentication,
              (endpoint.ssh == nil || active.baseURL.host == "127.0.0.1" || active.baseURL.host == "localhost") else {
            banner = GatewayTransportError.invalidEndpoint.localizedDescription; return
        }
        let sameHost = self.endpoint?.id == endpoint.id && self.endpoint?.baseURL == endpoint.baseURL
            && self.endpoint?.authentication == endpoint.authentication && self.endpoint?.ssh == endpoint.ssh
        let sameConnection = self.endpoint?.id == endpoint.id
            && self.endpoint?.baseURL == endpoint.baseURL && self.endpoint?.profile == endpoint.profile
            && self.endpoint?.ssh == endpoint.ssh
        let owner = SessionOwner(connectionID: endpoint.id, profile: endpoint.profile)
        let previous = sameConnection ? selectedID : draftStore.selectedSession(for: owner)
        let previousToken = sameHost ? token : nil
        let previousSession = sameHost ? session : nil
        let oldSession = session
        desiredConnection = true; remembersSignIn = remember
        defaults.set(remember, forKey: "gateway.remember")
        let stamp = UUID(); generation = stamp
        resetMobileActivity(for: endpoint, preserveLoaded: sameConnection)
        releaseSnapshotWaiters()
        appliedSnapshots = [:]
        receiver?.cancel(); refreshTask?.cancel()
        cancelAttachmentTransfers()
        isConnecting = true; isConnected = false; banner = nil
        let oldClient = client
        let client = clientFactory(); self.client = client
        await oldClient.disconnect()
        let restoredInMemory = await previousSession?.snapshot()
        await oldSession?.clear()
        guard generation == stamp else { return }
        session = nil
        selectedID = nil
        self.endpoint = endpoint
        self.activeEndpoint = active
        telegramTopics = []; telegramTopicsError = nil; hasLoadedTelegramTopics = false
        isLoadingTelegramTopics = false; hierarchyFeatures.telegramBindings = false
        hierarchyDestination = .home
        if !sameConnection { runDetails = [:] }
        loadingRunIDs = []; automationActionIDs = []; hierarchyError = nil
        homeAvailability = homeSessionID == nil ? .unselected : .available
        // Runtime IDs and replay cursors belong to a socket attachment. Rehydrate on every reconnect.
        conversations = [:]; selectedID = nil; draft = ""; isLoadingSession = false
        pendingRequests = [:]
        settingsSnapshot = nil; settingsError = nil; isLoadingSettings = false
        backgroundHydrations = []
        if !sameConnection { sessions = [] }
        do {
            let connectionSession: GatewaySession
            if endpoint.authentication == .basic {
                let restored = try restoredInMemory ?? credentials.readSession(for: endpoint)
                if !remember {
                    try credentials.deleteSession(for: endpoint)
                    try credentials.deleteToken(for: endpoint)
                }
                let onChange: @Sendable (GatewaySessionSnapshot?) async -> Void = { [weak self] snapshot in
                    await self?.persistSession(snapshot, endpoint: endpoint, generation: stamp)
                }
                if endpoint.ssh != nil {
                    connectionSession = try GatewaySession(endpoint: active, credentialEndpoint: endpoint,
                                                           restored: restored, onChange: onChange)
                } else {
                    connectionSession = try await client.makeSession(to: active, restored: restored, onChange: onChange)
                }
                guard generation == stamp else { await connectionSession.clear(); return }
                session = connectionSession; token = nil
                if let password, !password.isEmpty {
                    try await connectionSession.login(username: username ?? "", password: password)
                } else {
                    try await connectionSession.validate()
                }
            } else {
                let selectedToken: String?
                if let suppliedToken, !suppliedToken.isEmpty { selectedToken = suppliedToken }
                else if let previousToken { selectedToken = previousToken }
                else { selectedToken = try credentials.readToken(for: endpoint, legacyEndpoint: savedEndpoint) }
                token = selectedToken
                if !remember {
                    try credentials.deleteToken(for: endpoint)
                    try credentials.deleteSession(for: endpoint)
                }
                connectionSession = try await client.makeSession(to: active, token: selectedToken ?? "")
                guard generation == stamp else { await connectionSession.clear(); return }
                session = connectionSession
            }
            guard generation == stamp else { await connectionSession.clear(); return }
            let updates = await client.updates()
            receiver = Task { [weak self] in
                for await update in updates {
                    guard let self, !Task.isCancelled, self.generation == stamp else { return }
                    await self.handle(update, generation: stamp)
                }
            }
            try await client.connect(to: active, session: connectionSession)
            guard generation == stamp else { return }
            isConnected = true; isConnecting = false; showConnection = false
            if remember {
                do {
                    if endpoint.authentication == .basic {
                        let snapshot = await connectionSession.snapshot()
                        guard generation == stamp else { return }
                        if let snapshot { try credentials.saveSession(snapshot, for: endpoint) }
                    } else { try credentials.saveToken(token ?? "", for: endpoint) }
                    defaults.set(try JSONEncoder().encode(endpoint), forKey: "gateway.endpoint")
                    savedEndpoint = endpoint
                } catch { banner = "Connected, but the connection could not be saved to Keychain." }
            }
            await refreshSessions()
            await refreshTelegramTopics()
            guard generation == stamp, isConnected else { return }
            if homeSessionID != nil { await navigate(to: .home) }
            else if let previous {
                await openSession(previous, force: true)
                guard generation == stamp else { return }
                hierarchyDestination = .conversation(previous)
            }
        } catch {
            guard generation == stamp else { return }
            isConnecting = false; isConnected = false
            banner = safeDescription(error)
        }
    }

    public func reconnect() async {
        guard let endpoint else { showConnection = true; return }
        if endpoint.ssh != nil {
            guard let sshReconnectHandler else { showConnection = true; return }
            do {
                let (active, freshToken) = try await sshReconnectHandler()
                await connect(to: active, configuredEndpoint: endpoint, token: freshToken ?? token, remember: remembersSignIn)
            } catch { banner = safeDescription(error) }
        } else { await connect(to: endpoint, token: token, remember: remembersSignIn) }
    }

    public func persistDrafts() {
        do { try draftStore.flush() } catch { banner = draftStore.lastError }
    }

    public func sshTunnelExited() async {
        guard endpoint?.ssh != nil, desiredConnection else { return }
        generation = UUID(); receiver?.cancel(); refreshTask?.cancel()
        isConnected = false; isConnecting = false
        resetMobileActivity(preserveLoaded: true)
        releaseSnapshotWaiters(); cancelAttachmentTransfers()
        pendingRequests = [:]
        for id in conversations.keys { conversations[id]?.pendingInputs = [] }
        banner = "SSH connection closed. Reconnect to restore the session."
        await session?.suspend()
        await client.disconnect()
    }

    public func disconnect() async {
        desiredConnection = false
        isConnected = false; isConnecting = false
        let oldSession = session; session = nil; token = nil; activeEndpoint = nil
        let stamp = UUID(); generation = stamp; receiver?.cancel(); refreshTask?.cancel()
        resetMobileActivity(preserveLoaded: true)
        releaseSnapshotWaiters()
        cancelAttachmentTransfers()
        do { try draftStore.flush() } catch { banner = draftStore.lastError }
        let client = client
        await client.disconnect()
        await oldSession?.clear()
        guard generation == stamp else { return }
        isConnected = false; isConnecting = false; isLoadingSession = false
        isApplyingSettings = false; isLoadingSettings = false
        pendingRequests = [:]
        for id in conversations.keys { conversations[id]?.pendingInputs = [] }
    }

    public func signOut() async {
        let signedOutEndpoint = endpoint
        let oldSession = session
        // Invalidate callbacks before logout so its clearing response cannot save again.
        remembersSignIn = false; desiredConnection = false; isConnected = false; isConnecting = false
        generation = UUID(); receiver?.cancel()
        let signedOutGeneration = generation
        defaults.set(false, forKey: "gateway.remember")
        session = nil
        if let signedOutEndpoint {
            do {
                try credentials.deleteSession(for: signedOutEndpoint)
                try credentials.deleteToken(for: signedOutEndpoint)
            } catch { banner = "Sign-in could not be removed from Keychain." }
        }
        await client.disconnect()
        await oldSession?.logout()
        guard generation == signedOutGeneration else { return }
        await disconnect()
    }

    private func persistSession(_ snapshot: GatewaySessionSnapshot?, endpoint: GatewayEndpoint, generation stamp: UUID) {
        guard generation == stamp, remembersSignIn else { return }
        do {
            if let snapshot { try credentials.saveSession(snapshot, for: endpoint) }
            else { try credentials.deleteSession(for: endpoint) }
        } catch { banner = "Connected, but sign-in could not be saved to Keychain." }
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
        if !force, let cached = conversations[id], !cached.requiresHydration { select(id); if id == homeSessionID { homeAvailability = .available }; return }
        let stamp = generation; isLoadingSession = true
        let beforeSnapshot = snapshotVersion
        defer { if generation == stamp { isLoadingSession = false } }
        do {
            let result = try await client.request("session.resume", params: .object([
                "session_id": .string(id.rawValue), "profile": .string(endpoint.profile),
                "source": .string("native")
            ]), timeout: 90)
            await waitForSnapshot(result, after: beforeSnapshot, generation: stamp)
        } catch {
            if generation == stamp {
                banner = safeDescription(error)
                conversations[id]?.requiresHydration = true
                if id == homeSessionID {
                    homeAvailability = HomeResolution.isConfirmedMissing(error) ? .unavailable : .failed(safeDescription(error))
                }
            }
            return
        }
        if generation == stamp, id == homeSessionID {
            if conversations[id] != nil { homeAvailability = .available; cacheHomeTranscript() }
            else { homeAvailability = .failed("Hermes returned a different conversation. Choose the conversation to use as Home.") }
        }
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
        let authoritative = pendingRequests[input.id]
        let receiptOwner = conversations.values.first { state in
            state.owner == currentHierarchyOwner && state.pendingInputs.contains { $0.id == input.id }
        }.map { ComposerScope(owner: $0.owner, sessionID: $0.storedID) }
        do {
            try await client.respond(to: input.id, result: result)
            guard generation == stamp else { return false }
            if let receiptOwner, let authoritative {
                let receipt = RequestReceipt(id: input.id, method: authoritative.method, result: result)
                requestReceiptStore[receiptOwner, default: []].append(receipt)
                requestReceiptStore[receiptOwner] = Array((requestReceiptStore[receiptOwner] ?? []).suffix(20))
            }
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
        let remember = remembersSignIn
        if var active = activeEndpoint {
            active.profile = profile
            await connect(to: active, configuredEndpoint: target, token: token, remember: remember)
        } else {
            await connect(to: target, token: token, remember: remember)
        }
        if isConnected, endpoint?.profile == profile { await loadSettings(); return true }
        settingsError = banner ?? "The profile could not be connected."
        return false
    }

    public func addAttachments(_ urls: [URL], to scope: ComposerScope) async {
        guard canAttach, composerScope == scope, let endpoint, let session, let state = conversation,
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
                    let result = try await AttachmentTransferService().upload(staged, workspace: workspace, session: session)
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
            resetMobileActivity(preserveLoaded: true)
            releaseSnapshotWaiters()
            cancelAttachmentTransfers()
            pendingRequests = [:]
            if let reason {
                banner = conversations.isEmpty ? reason : reason + " Reconnect to restore the conversation."
            }
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
                if state.storedID == homeSessionID { homeAvailability = .available; cacheHomeTranscript() }
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
            if event.type == "message.complete" { cacheHomeTranscript() }
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
        // Request settlement can precede the next activity refresh. Reflect it
        // immediately without leaving a cached run stuck at Waiting for input.
        for (id, detail) in runDetails {
            guard let index = mobileActivity.runs.firstIndex(where: { $0.id == id }) else { continue }
            let run = mobileActivity.runs[index]
            let waiting = mobilePendingInputs.contains { $0.sessionID == run.sessionID }
            let status = waiting ? AutomationRunStatus.waitingForInput : AutomationRunResult.status(for: run, result: detail.result)
            guard detail.status != status else { continue }
            runDetails[id] = AutomationRunDetail(runID: id, result: detail.result, messages: detail.messages,
                status: status, executionAvailable: detail.executionAvailable, isHistoryTruncated: detail.isHistoryTruncated)
            mobileActivity.runs[index].status = status
        }
    }

    private func safeDescription(_ error: Error) -> String {
        var text = error.localizedDescription
        if let token, !token.isEmpty { text = text.replacingOccurrences(of: token, with: "[redacted]") }
        return text
    }
}

extension HermesAppModel {
    /// Capability discovery is read-only. Only an explicit import creates organisation.
    public func refreshTelegramTopics() async {
        guard isConnected, let endpoint, let session else { return }
        let stamp = generation
        telegramTopicsRevision += 1; let revision = telegramTopicsRevision
        isLoadingTelegramTopics = true; telegramTopicsError = nil
        defer { if generation == stamp, telegramTopicsRevision == revision { isLoadingTelegramTopics = false } }
        do {
            let response: JSONValue
            if let telegramTopicsLoader { response = try await telegramTopicsLoader(endpoint, session) }
            else { response = try await GatewayReader(session: session).read(.telegramTopics) }
            let snapshot = try TelegramTopicsSnapshot(json: response, expectedProfile: endpoint.profile)
            guard generation == stamp, revision == telegramTopicsRevision, isConnected,
                  let owner = currentHierarchyOwner else { return }
            telegramTopics = snapshot.topics; hasLoadedTelegramTopics = true
            hierarchyFeatures.telegramBindings = true
            classificationStore.update(for: owner) { $0.reconcileTelegramTopics(snapshot.topics) }
            // Topic bindings can point beyond the ordinary latest-100 session list.
            let existing = Set(sessions.map(\.id))
            sessions += snapshot.topics.filter { !existing.contains($0.currentSessionID) }.map { topic in
                SessionSummary(json: .object(["id": .string(topic.currentSessionID.rawValue),
                    "title": .string(topic.displayLabel), "source": .string("telegram")]))
            }
        } catch {
            guard generation == stamp, revision == telegramTopicsRevision else { return }
            hasLoadedTelegramTopics = false
            if case GatewayTransportError.httpStatus(404) = error {
                hierarchyFeatures.telegramBindings = false
                telegramTopicsError = "This Hermes gateway does not expose Telegram topics yet. Install the Talaria gateway extension to import them."
            } else { telegramTopicsError = safeDescription(error) }
        }
    }

    @discardableResult public func importTelegramTopics(home: TelegramTopicIdentity?,
        asWorkspaces identities: Set<TelegramTopicIdentity>) async -> Bool {
        guard !isLoadingTelegramTopics, isConnected, let owner = currentHierarchyOwner else { return false }
        let stamp = generation
        await refreshTelegramTopics()
        guard generation == stamp, hasLoadedTelegramTopics, owner == currentHierarchyOwner else { return false }
        let available = Set(telegramTopics.map(\.id))
        guard identities.isSubset(of: available), home.map(available.contains) ?? true else {
            telegramTopicsError = "A selected Telegram topic is no longer available. Refresh and choose again."; return false
        }
        classificationStore.update(for: owner) {
            $0.importTelegramTopics(telegramTopics, home: home, asWorkspaces: identities)
        }
        guard classificationStore.error == nil else { return false }
        await navigate(to: home == nil ? .workspaces : .home)
        return true
    }

    public func telegramTopic(for workspaceID: UUID) -> TelegramTopic? {
        guard let assignment = telegramAssignment(for: .workspace(workspaceID)) else { return nil }
        return telegramTopics.first { $0.id == assignment.identity }
    }

    private func telegramAssignment(for destination: HierarchyDestination) -> TelegramTopicAssignment? {
        hierarchyClassification.telegramTopicAssignments.first { assignment in
            switch (destination, assignment.destination) {
            case (.home, .home): true
            case (.workspace(let id), .workspace(let assigned)): id == assigned
            case (.conversation(let id), _): id == assignment.lastKnownSessionID
            default: false
            }
        }
    }

    private var telegramDestinationIsReady: Bool {
        guard let assignment = telegramAssignment(for: hierarchyDestination) else { return true }
        return hasLoadedTelegramTopics && !isLoadingTelegramTopics
            && telegramTopics.contains { $0.id == assignment.identity && $0.currentSessionID == selectedID }
    }

    public func requestReceipts(for sessionID: StoredSessionID) -> [RequestReceipt] {
        guard let owner = currentHierarchyOwner else { return [] }
        return requestReceiptStore[ComposerScope(owner: owner, sessionID: sessionID)] ?? []
    }
    public var currentHierarchyOwner: SessionOwner? {
        endpoint.map { SessionOwner(connectionID: $0.id, profile: $0.profile) }
    }
    public var hierarchyClassification: HierarchyClassification {
        currentHierarchyOwner.map { classificationStore.classification(for: $0) } ?? HierarchyClassification()
    }
    public var homeSessionID: StoredSessionID? { hierarchyClassification.homeSessionID }
    public var cachedHomeMessages: [ChatMessage] { hierarchyClassification.cachedHomeMessages }
    public var workspaces: [TalariaWorkspace] { hierarchyClassification.workspaces }
    public var automations: [TalariaAutomation] { mobileActivity.schedules }
    public var runs: [AutomationRun] { mobileActivity.runs }
    public var needsYouCount: Int { mobilePendingInputs.count }
    public var activityCount: Int { needsYouCount + unreadMobileRunCount }
    public var otherConversations: [SessionSummary] {
        let classified = Set(workspaces.flatMap(\.sessionIDs))
        let knownRuns = Set(runs.map(\.sessionID))
        return filteredSessions.filter { $0.id != homeSessionID && !classified.contains($0.id) && !knownRuns.contains($0.id) && !hierarchyClassification.archivedSessionIDs.contains($0.id) }
    }
    public var archivedConversations: [SessionSummary] {
        filteredSessions.filter { hierarchyClassification.archivedSessionIDs.contains($0.id) && $0.id != homeSessionID && workspace(for: $0.id) == nil }
    }
    public func archiveConversation(_ id: StoredSessionID, archived: Bool = true) {
        guard let owner = currentHierarchyOwner, id != homeSessionID else { return }
        classificationStore.update(for: owner) { value in
            if archived { value.archivedSessionIDs.insert(id) } else { value.archivedSessionIDs.remove(id) }
        }
    }
    public func createConversationForDiscussion() async -> StoredSessionID? {
        let stamp = generation; let before = selectedID
        await newConversation()
        guard generation == stamp, let id = selectedID, id != before else { return nil }
        return id
    }
    public func newConversation(in workspaceID: UUID, startedFrom parent: StoredSessionID? = nil) async {
        guard workspace(id: workspaceID) != nil else { return }
        let owner = currentHierarchyOwner; let before = selectedID; let stamp = generation
        await newConversation()
        guard generation == stamp, owner == currentHierarchyOwner, let id = selectedID, id != before else { return }
        assignSession(id, to: workspaceID)
        if let parent { recordLineage(child: id, parent: parent, kind: .branch) }
        hierarchyDestination = .workspace(workspaceID)
    }
    public func workspace(id: UUID) -> TalariaWorkspace? { workspaces.first { $0.id == id } }
    public func workspace(for sessionID: StoredSessionID) -> TalariaWorkspace? {
        workspaces.first { $0.sessionIDs.contains(sessionID) }
    }
    public func automationRuns(_ id: String) -> [AutomationRun] { runs.filter { $0.automationID == id } }
    public func automationRuns(id: String) -> [AutomationRun] { automationRuns(id) }
    public func isRunUnread(_ id: String) -> Bool { runs.first(where: { $0.id == id }).map(isRunUnread) ?? false }
    public func isRunUnread(_ run: AutomationRun) -> Bool {
        !run.isActive && run.status.isTerminal && !seenMobileRunIDs.contains(run.id)
            && !hierarchyClassification.readRunIDs.contains(run.id)
    }
    public func openActivityInput(_ item: MobilePendingInput) async {
        activityRequestFocusID = item.input.id
        guard let sessionID = item.sessionID else { return }
        await navigate(to: sessionID == homeSessionID ? .home : .conversation(sessionID))
    }
    public var canAnswerPendingText: Bool {
        let inputs = conversation?.pendingInputs ?? []
        return isConnected && inputs.count == 1 && inputs[0].method == "clarify"
            && (inputs[0].params["questions"]?.arrayValue ?? []).isEmpty
    }
    @discardableResult public func answerPendingText(_ text: String) async -> Bool {
        guard canAnswerPendingText, let input = conversation?.pendingInputs.first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let scope = composerScope; let stamp = generation
        let acknowledged = await answer(input, result: .object(["answer": .string(text)]))
        if acknowledged, generation == stamp, composerScope == scope, draft == text { draft = "" }
        return acknowledged
    }
    @discardableResult public func openHierarchyLink(_ url: URL) async -> Bool {
        guard url.scheme == "talaria", url.host == "run", let owner = currentHierarchyOwner,
              let route = URLComponents(url: url, resolvingAgainstBaseURL: false),
              route.queryItems?.first(where: { $0.name == "connection" })?.value == owner.connectionID.uuidString,
              route.queryItems?.first(where: { $0.name == "profile" })?.value == owner.profile else { return false }
        let id = String(url.path.dropFirst())
        guard runs.contains(where: { $0.id == id }) else { return false }
        await navigate(to: .run(id)); return true
    }
    public func navigate(to destination: HierarchyDestination) async {
        if case .conversation = destination, let assignment = telegramAssignment(for: destination) {
            switch assignment.destination {
            case .home: await navigate(to: .home)
            case .workspace(let id): await navigate(to: .workspace(id))
            }
            return
        }
        hierarchyNavigationRevision += 1
        let revision = hierarchyNavigationRevision; let stamp = generation
        hierarchyDestination = destination; hierarchyError = nil
        // A previous resume is allowed to finish, but a later destination owns
        // navigation. Waiting here prevents a quick second click from being
        // silently discarded by openSession's single-flight guard.
        switch destination {
        case .home, .conversation, .workspace:
            while isLoadingSession {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard generation == stamp, hierarchyNavigationRevision == revision else { return }
            }
        default: break
        }
        guard generation == stamp, hierarchyNavigationRevision == revision else { return }
        if telegramAssignment(for: destination) != nil {
            await refreshTelegramTopics()
            guard generation == stamp, hierarchyNavigationRevision == revision else { return }
            guard let assignment = telegramAssignment(for: destination), hasLoadedTelegramTopics,
                  telegramTopics.contains(where: { $0.id == assignment.identity }) else {
                let message = telegramTopicsError ?? "This Telegram topic is unavailable. Its saved conversation has been retained."
                hierarchyError = message; banner = message
                if destination == .home { homeAvailability = hasLoadedTelegramTopics ? .unavailable : .failed(message) }
                return
            }
        }
        switch destination {
        case .home:
            guard let id = homeSessionID else { homeAvailability = .unselected; return }
            guard isConnected else { return }
            homeAvailability = .loading
            await openSession(id, force: telegramAssignment(for: destination) != nil)
        case .conversation(let id): await openSession(id)
        case .workspace(let id):
            if let sessionID = telegramAssignment(for: destination)?.lastKnownSessionID ?? workspace(id: id)?.sessionIDs.first {
                await openSession(sessionID, force: telegramAssignment(for: destination) != nil)
            }
        case .automations, .activity:
            if mobileActivity.schedules.isEmpty { await refreshMobileActivity() }
        case .automation(let id):
            if mobileActivity.schedules.isEmpty { await refreshMobileActivity() }
            guard generation == stamp, hierarchyNavigationRevision == revision else { return }
            await refreshAutomationRuns(id)
        case .run(let id): await loadRunDetail(id)
        case .workspaces, .otherConversations: break
        }
    }
    public func chooseHome(_ id: StoredSessionID) async {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) { value in
            value.telegramTopicAssignments.removeAll { $0.destination == .home || $0.lastKnownSessionID == id }
            if value.homeSessionID != id { value.cachedHomeMessages = [] }
            value.homeSessionID = id
            value.archivedSessionIDs.remove(id)
            for index in value.workspaces.indices { value.workspaces[index].sessionIDs.removeAll { $0 == id } }
        }
        await navigate(to: .home)
    }
    public func startFreshHome() async {
        let before = selectedID; let stamp = generation
        await newConversation()
        guard generation == stamp, let selectedID, selectedID != before else { return }
        await chooseHome(selectedID)
    }
    @discardableResult public func createWorkspace(name: String, purpose: String = "", swatch: String = "#4F6AF2",
                                                  sessionID: StoredSessionID? = nil) -> UUID? {
        guard let owner = currentHierarchyOwner else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, sessionID != homeSessionID || sessionID == nil else { return nil }
        let workspace = TalariaWorkspace(name: String(name.prefix(200)), purpose: String(purpose.prefix(2_000)),
            swatch: swatch, sessionIDs: sessionID.map { [$0] } ?? [])
        classificationStore.update(for: owner) { value in
            if let sessionID {
                value.telegramTopicAssignments.removeAll { $0.lastKnownSessionID == sessionID }
                for index in value.workspaces.indices { value.workspaces[index].sessionIDs.removeAll { $0 == sessionID } }
            }
            value.workspaces.append(workspace)
        }
        return workspaces.contains(where: { $0.id == workspace.id }) ? workspace.id : nil
    }
    public func assignSession(_ sessionID: StoredSessionID, to workspaceID: UUID) {
        guard let owner = currentHierarchyOwner, sessionID != homeSessionID,
              workspace(id: workspaceID) != nil else { return }
        classificationStore.update(for: owner) { value in
            value.telegramTopicAssignments.removeAll { $0.lastKnownSessionID == sessionID }
            value.archivedSessionIDs.remove(sessionID)
            for index in value.workspaces.indices {
                value.workspaces[index].sessionIDs.removeAll { $0 == sessionID }
                if value.workspaces[index].id == workspaceID { value.workspaces[index].sessionIDs.append(sessionID) }
            }
        }
    }
    public func removeSessionFromWorkspace(_ sessionID: StoredSessionID) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) { value in
            value.telegramTopicAssignments.removeAll { $0.lastKnownSessionID == sessionID }
            for index in value.workspaces.indices { value.workspaces[index].sessionIDs.removeAll { $0 == sessionID } }
        }
    }
    public func updateWorkspace(_ id: UUID, name: String, purpose: String, swatch: String) {
        guard let owner = currentHierarchyOwner, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        classificationStore.update(for: owner) { value in
            guard let index = value.workspaces.firstIndex(where: { $0.id == id }) else { return }
            value.workspaces[index].name = String(name.prefix(200)); value.workspaces[index].purpose = String(purpose.prefix(2_000))
            value.workspaces[index].swatch = swatch
        }
    }
    public func archiveWorkspace(_ id: UUID, archived: Bool = true) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) { value in
            guard let index = value.workspaces.firstIndex(where: { $0.id == id }) else { return }
            value.workspaces[index].isArchived = archived
        }
    }
    public func recordLineage(child: StoredSessionID, parent: StoredSessionID, kind: SessionLineageKind) {
        guard let owner = currentHierarchyOwner, child != parent else { return }
        classificationStore.update(for: owner) { value in
            value.lineage.removeAll { $0.childSessionID == child }
            value.lineage.append(SessionLineage(childSessionID: child, parentSessionID: parent, kind: kind))
        }
    }
    public func place(for sessionID: StoredSessionID) -> SessionPlace {
        hierarchyClassification.places[sessionID.rawValue] ?? SessionPlace()
    }
    public func rememberPlace(_ messageID: String?, for sessionID: StoredSessionID) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) { $0.places[sessionID.rawValue] = SessionPlace(visibleMessageID: messageID) }
    }
    public func markRunRead(_ id: String) {
        guard let owner = currentHierarchyOwner, let run = runs.first(where: { $0.id == id }),
              !run.isActive, run.status.isTerminal else { return }
        classificationStore.update(for: owner) { $0.readRunIDs.insert(id) }
    }
    public func markAllActivityRead() {
        guard let owner = currentHierarchyOwner else { return }
        let ids = runs.filter { !$0.isActive && $0.status.isTerminal }.map(\.id)
        classificationStore.update(for: owner) { $0.readRunIDs.formUnion(ids) }
        // Needs-you requests are decisions, never dismissed by marking updates read.
    }
    public func loadRunDetail(_ id: String) async {
        guard isConnected, let endpoint, let session, let run = runs.first(where: { $0.id == id }),
              loadingRunIDs.insert(id).inserted else { return }
        let stamp = generation
        defer { if stamp == generation { loadingRunIDs.remove(id) } }
        do {
            let response: JSONValue
            if let runDetailLoader { response = try await runDetailLoader(endpoint, session, run) }
            else { response = try await GatewayReader(session: session).read(.sessionMessages(id: run.sessionID.rawValue, limit: 40)) }
            guard stamp == generation else { return }
            guard let currentRun = runs.first(where: { $0.id == id }) else { return }
            guard currentRun.isActive == run.isActive, currentRun.endedAt == run.endedAt, currentRun.endReason == run.endReason else {
                Task { [weak self] in
                    guard let self, self.generation == stamp else { return }
                    await self.loadRunDetail(id)
                }
                return
            }
            guard response["profile"]?.stringValue.map({ $0 == endpoint.profile }) != false,
                  response["session_id"]?.stringValue.map({ $0 == run.sessionID.rawValue }) != false,
                  response["messages"]?.arrayValue != nil else { throw MobileActivityError.invalidResponse }
            var detail = AutomationRunResult.parse(run, response: response)
            if mobilePendingInputs.contains(where: { $0.sessionID == run.sessionID }) {
                detail = AutomationRunDetail(runID: id, result: detail.result, messages: detail.messages, status: .waitingForInput,
                    isHistoryTruncated: detail.isHistoryTruncated)
            }
            runDetails[id] = detail
            if let index = mobileActivity.runs.firstIndex(where: { $0.id == id }) {
                mobileActivity.runs[index].status = detail.status
                mobileActivity.runs[index].summary = String(detail.result.prefix(1_200))
            }
            markRunRead(id)
        } catch {
            guard stamp == generation else { return }
            hierarchyError = safeDescription(error)
            if runDetails[id] == nil {
                runDetails[id] = AutomationRunDetail(runID: id, result: "", messages: [], status: .unavailable, executionAvailable: false)
            }
        }
    }
    public func setAutomationEnabled(_ id: String, enabled: Bool) async {
        guard isConnected, let endpoint, let session, automations.contains(where: { $0.id == id }),
              automationActionIDs.insert(id).inserted else { return }
        let stamp = generation
        defer { if generation == stamp { automationActionIDs.remove(id) } }
        do {
            _ = try await GatewayReader(session: session).setAutomationEnabled(id: id, enabled: enabled)
            guard generation == stamp else { return }
            await refreshMobileActivity()
        } catch { if generation == stamp { hierarchyError = safeDescription(error) } }
    }
    public func rerunAutomation(_ id: String) async {
        guard let automation = automations.first(where: { $0.id == id }) else { return }
        // Hermes force-firing a paused automation also enables its recurring
        // schedule. Require a separate, explicit Enabled toggle first.
        guard automation.enabled else { hierarchyError = "Enable this automation before running it."; return }
        guard isConnected, let endpoint, let session,
              automationActionIDs.insert(id).inserted else { return }
        let stamp = generation
        defer { if generation == stamp { automationActionIDs.remove(id) } }
        do {
            _ = try await GatewayReader(session: session).triggerAutomation(id: id)
            guard generation == stamp else { return }
            await refreshMobileActivity()
            await refreshAutomationRuns(id)
            scheduleAutomationRefreshes(id, generation: stamp)
        } catch {
            if generation == stamp {
                hierarchyError = "The run request could not be confirmed. Refresh its runs before trying again. " + safeDescription(error)
                scheduleAutomationRefreshes(id, generation: stamp)
            }
        }
    }
    /// Stages only chosen content in the destination's draft. The regular Send
    /// action is still explicit; destination selection never starts a host turn.
    @discardableResult public func stageResultDiscussion(result: String, runID: String, destination: StoredSessionID,
                                                         includeResult: Bool = true, includeBacklink: Bool = true) async -> Bool {
        guard let owner = currentHierarchyOwner else { return false }
        let stamp = generation
        var sections: [String] = []
        if includeResult, !result.isEmpty { sections.append(result.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")) }
        if includeBacklink {
            var link = URLComponents(); link.scheme = "talaria"; link.host = "run"; link.path = "/" + runID
            link.queryItems = [URLQueryItem(name: "connection", value: owner.connectionID.uuidString), URLQueryItem(name: "profile", value: owner.profile)]
            if let url = link.url { sections.append("[View original run](\(url.absoluteString))") }
        }
        guard !sections.isEmpty else { return false }
        let scope = ComposerScope(owner: owner, sessionID: destination)
        let current = draftStore.text(for: scope)
        let quotation = sections.joined(separator: "\n\n")
        draftStore.setText(current.isEmpty ? quotation : current + "\n\n" + quotation, for: scope)
        await navigate(to: destination == homeSessionID ? .home : .conversation(destination))
        guard generation == stamp else { return false }
        guard selectedID == destination, conversation?.owner == owner else { return false }
        draft = draftStore.text(for: scope)
        return true
    }
    private func cacheHomeTranscript() {
        guard let owner = currentHierarchyOwner, let homeSessionID, let state = conversations[homeSessionID] else { return }
        var retainedBytes = 0
        let messages = state.messages.suffix(100).reversed().compactMap { message -> ChatMessage? in
            guard message.role == .user || message.role == .assistant, retainedBytes < 200_000 else { return nil }
            var copy = message; copy.text = String(copy.text.prefix(8_000)); copy.reasoning = ""; copy.toolInput = nil
            copy.isStreaming = false; retainedBytes += copy.text.utf8.count; return copy
        }
        classificationStore.update(for: owner) { $0.cachedHomeMessages = messages.reversed() }
    }
}

extension HermesAppModel {
    public func workspaceFiles(_ id: UUID) -> [WorkspaceFileReference] {
        guard let workspace = workspace(id: id) else { return [] }
        return workspace.sessionIDs.flatMap { sessionID in
            guard let state = conversations[sessionID] else { return [WorkspaceFileReference]() }
            return WorkspaceFileReferences.collect(sessionID: sessionID, cwd: state.cwd, messages: state.messages)
        }
    }
}

extension HermesAppModel {
    /// A focused read, independent of the overview's bounded fan-out. This makes
    /// every explicitly opened automation usable, including those beyond its first page.
    public func refreshAutomationRuns(_ id: String) async {
        guard isConnected, !isLoadingMobileActivity, let endpoint, let session,
              let automation = automations.first(where: { $0.id == id }),
              loadingAutomationRunIDs.insert(id).inserted else { return }
        let stamp = generation
        defer { if generation == stamp { loadingAutomationRunIDs.remove(id) } }
        do {
            let response: JSONValue
            if let automationRunsLoader { response = try await automationRunsLoader(endpoint, session, id) }
            else { response = try await GatewayReader(session: session).read(.scheduleRuns(id: id, limit: 20)) }
            guard generation == stamp, isConnected else { return }
            guard response["profile"]?.stringValue.map({ $0 == endpoint.profile }) != false,
                  let rows = response["runs"]?.arrayValue else { throw MobileActivityError.invalidResponse }
            var seen = Set<String>()
            var refreshed = rows.prefix(20).compactMap { MobileRun(json: $0, schedule: automation, profile: endpoint.profile) }
                .filter { seen.insert($0.id).inserted }
            guard !refreshed.contains(where: { candidate in
                runs.contains { $0.id == candidate.id && $0.automationID != id }
            }) else { throw MobileActivityError.invalidResponse }
            var changed = Set<String>()
            for index in refreshed.indices {
                let current = refreshed[index]
                if let previous = runs.first(where: { $0.id == current.id }),
                   previous.isActive == current.isActive, previous.endedAt == current.endedAt, previous.endReason == current.endReason {
                    refreshed[index].summary = previous.summary; refreshed[index].status = previous.status
                } else { changed.insert(current.id); runDetails.removeValue(forKey: current.id) }
            }
            // Keep the explicitly opened automation visible even when unrelated
            // overview history already fills the bounded in-memory cache.
            let retained = mobileActivity.runs.filter { $0.automationID != id }.prefix(400 - refreshed.count)
            let merged = Array(retained) + refreshed
            mobileActivity.runs = Array(merged.sorted {
                if $0.startedAt == $1.startedAt { return $0.id < $1.id }
                return ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }.prefix(400))
            if case .run(let selected) = hierarchyDestination, changed.contains(selected) { await loadRunDetail(selected) }
        } catch {
            guard generation == stamp, !(error is CancellationError) else { return }
            hierarchyError = safeDescription(error)
        }
    }

    /// Owned by the visible Run view's task. Cancellation stops subsequent reads;
    /// it never interrupts the backend run. At most one poll every five seconds.
    public func observeRun(_ id: String) async {
        let stamp = generation
        await loadRunDetail(id)
        for _ in 0..<60 {
            guard !Task.isCancelled, generation == stamp, isConnected, hierarchyDestination == .run(id),
                  let run = runs.first(where: { $0.id == id }),
                  run.isActive || runDetails[id]?.status == .waitingForInput else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, generation == stamp, hierarchyDestination == .run(id) else { return }
            await refreshAutomationRuns(run.automationID)
            guard !Task.isCancelled, generation == stamp, hierarchyDestination == .run(id) else { return }
            await loadRunDetail(id)
        }
    }

    private func scheduleAutomationRefreshes(_ id: String, generation stamp: UUID) {
        automationRefreshTasks[id]?.cancel()
        automationRefreshTasks[id] = Task { [weak self] in
            for seconds in [3, 5] {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self, !Task.isCancelled, self.generation == stamp, self.isConnected else { return }
                await self.refreshAutomationRuns(id)
            }
        }
    }
}
