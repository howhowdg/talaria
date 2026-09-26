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
    public var searchText = "" {
        didSet { if searchText != oldValue { channelSearchRevision += 1; channelSearchResults = []; channelSearchError = nil; isSearchingChannels = false } }
    }
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
    public private(set) var channelError: String?
    public private(set) var isLoadingChannels = false
    public private(set) var channelDiscoveryHasMore = false
    private var channelDiscoveryOffset = 0
    public private(set) var channelSearchResults: [SessionSummary] = []
    public private(set) var channelSearchError: String?
    public private(set) var isSearchingChannels = false
    public private(set) var channelHistoryError: String?
    public private(set) var isLoadingChannelHistory = false
    public private(set) var channelHandoffDestinations: [ChannelHandoffDestination] = []
    public private(set) var channelHandoffStatus: String?
    public private(set) var isLoadingChannelHandoff = false
    private var channelRows: [String: [SessionSummary]] = [:]
    private var channelOffsets: [String: Int] = [:]
    private var channelMore: [String: Bool] = [:]
    private var channelHistory: [StoredSessionID: [ChatMessage]] = [:]
    private var channelHistoryCounts: [StoredSessionID: Int] = [:]
    private var channelHistoryMore: [StoredSessionID: Bool] = [:]
    private var channelResolvedIDs: [StoredSessionID: StoredSessionID] = [:]
    private var continuedChannelIDs = Set<StoredSessionID>()
    private var unavailableChannelIDs = Set<StoredSessionID>()
    private var channelUnsettledTails: [StoredSessionID: ChatMessage] = [:]
    private var channelsDiscovered = false
    private var channelChangeEvents = false
    private var channelForeground = true
    @ObservationIgnored private let channelReader: ChannelReader?
    @ObservationIgnored private var channelPollTask: Task<Void, Never>?
    @ObservationIgnored private var channelHistoryRevision = 0
    @ObservationIgnored private var channelSearchRevision = 0
    @ObservationIgnored private var channelListRevision = 0
    @ObservationIgnored private var channelHandoffRevision = 0
    @ObservationIgnored private var channelHandoffSession: RuntimeSessionID?
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
                channelReader: ChannelReader? = nil,
                clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() }) {
        self.credentials = credentials
        self.classificationStore = HierarchyClassificationStore(defaults: defaults)
        self.defaults = defaults; self.draftStore = draftStore ?? DraftStore(); self.sender = sender
        self.clientFactory = clientFactory; client = clientFactory()
        self.mobileActivityLoader = mobileActivityLoader
        self.runDetailLoader = runDetailLoader
        self.automationRunsLoader = automationRunsLoader
        self.telegramTopicsLoader = telegramTopicsLoader
        self.channelReader = channelReader
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
        isConnected && !isPassiveChannel && channelHandoffSession == nil && telegramDestinationIsReady && conversation != nil && !isLoadingSession && !isSubmitting && !isTransferringAttachments
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
        isConnected && !isPassiveChannel && channelHandoffSession == nil && telegramDestinationIsReady && !isLoadingSession && conversation != nil && conversation?.isRunning != true
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
        resetChannels(preserveLoaded: sameConnection)
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
            await refreshChannels()
            guard generation == stamp, isConnected else { return }
            startChannelPolling()
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
        resetChannels(preserveLoaded: true)
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
        resetChannels(preserveLoaded: true)
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
            let incoming = (result["sessions"]?.arrayValue ?? []).map(SessionSummary.init).filter { !$0.id.rawValue.isEmpty }
            let keep = Set(telegramTopics.map(\.currentSessionID)).union(hierarchyClassification.pinnedChannelIDs)
            let incomingIDs = Set(incoming.map(\.id))
            let retained = sessions.filter { keep.contains($0.id) && !incomingIDs.contains($0.id) }
            sessions = incoming + retained
            mergeChannelRowsIntoSessions()
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
        if !sessions.contains(where: { $0.id == id }), !isChannelSession(id), channelsDiscovered,
           let endpoint, let session {
            let stamp = generation
            do { try await hydrateChannelReference(id, endpoint: endpoint, session: session) }
            catch { if generation == stamp { banner = safeDescription(error) }; return }
            guard generation == stamp, isConnected else { return }
        }
        if isChannelSession(id) { await openChannelSession(id); return }
        await resumeNativeSession(id, force: force)
    }

    private func resumeNativeSession(_ id: StoredSessionID, force: Bool = false) async {
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
        guard isConnected, !isPassiveChannel, let id = selectedID, let state = conversations[id] else { return }
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
        guard isConnected, !isPassiveChannel, let endpoint else { return }
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
            resetChannels(preserveLoaded: true)
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
            if event.type == "gateway.ready" { channelChangeEvents = event.payload["change_events"]?.boolValue == true }
            if event.type == "request.cancel", let raw = event.payload["id"]?.stringValue {
                pendingRequests.removeValue(forKey: .string(raw))
            }
            for id in Array(conversations.keys) {
                if isChannelSession(id), !continuedChannelIDs.contains(id) { continue }
                conversations[id]?.apply(event)
                if let state = conversations[id], state.storedID != id {
                    conversations.removeValue(forKey: id); conversations[state.storedID] = state
                    moveChannelIdentity(from: id, to: state.storedID)
                    moveComposer(from: ComposerScope(owner: state.owner, sessionID: id),
                                 to: ComposerScope(owner: state.owner, sessionID: state.storedID))
                    if selectedID == id { selectedID = state.storedID }
                    _ = await sender.hasPending(ComposerScope(owner: state.owner, sessionID: state.storedID), runtimeID: state.runtimeID)
                    guard generation == stamp else { return }
                }
            }
            updateMobilePendingInputs()
            if event.type == "message.complete" {
                cacheHomeTranscript()
                for state in conversations.values where continuedChannelIDs.contains(state.storedID)
                    && (event.sessionID == state.runtimeID.rawValue || event.sessionID == state.storedID.rawValue) {
                    channelUnsettledTails[state.storedID] = state.messages.last { $0.role == .assistant || $0.role == .user }
                }
            }
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
                    await self?.refreshChannels()
                    await self?.refreshVisibleChannel()
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
        guard let owner = currentHierarchyOwner else { return SessionPlace() }
        return classificationStore.place(for: sessionID, owner: owner)
    }
    public func rememberPlace(_ messageID: String?, for sessionID: StoredSessionID) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.rememberPlace(messageID, for: sessionID, owner: owner)
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

// Channel transcripts share the ordinary renderer, but only an explicit continuation
// attaches a runtime. Browsing must never acquire the messaging agent's session.
extension HermesAppModel {
    /// Take one snapshot when filtering a list, rather than scanning every source per row.
    public var channelSessionIDs: Set<StoredSessionID> {
        Set(sessions.filter(\.isChannel).map(\.id))
            .union(channelRows.values.flatMap { $0.map(\.id) })
            .union(telegramTopics.map(\.currentSessionID))
            .union(channelHistory.keys).union(continuedChannelIDs).union(unavailableChannelIDs)
    }

    public func isChannelSession(_ id: StoredSessionID) -> Bool {
        sessions.contains { $0.id == id && $0.isChannel }
            || channelRows.values.contains { $0.contains { $0.id == id } }
            || telegramTopics.contains { $0.currentSessionID == id }
            || channelHistory[id] != nil || continuedChannelIDs.contains(id) || unavailableChannelIDs.contains(id)
    }
    public var isPassiveChannel: Bool {
        selectedID.map { isChannelSession($0) && !continuedChannelIDs.contains($0) } ?? false
    }
    public var isViewingChannel: Bool {
        switch hierarchyDestination {
        case .home, .workspace, .conversation: selectedID.map(isChannelSession) ?? false
        default: false
        }
    }
    public var channelHistoryHasMore: Bool { selectedID.flatMap { channelHistoryMore[$0] } ?? false }
    public var pinnedChannelSessions: [SessionSummary] {
        channelVisibleRows.filter { isChannelPinned($0.id) }
    }
    private var channelVisibleRows: [SessionSummary] {
        sessions.filter {
            ($0.isChannel || (unavailableChannelIDs.contains($0.id) && isChannelPinned($0.id))) && !hierarchyClassification.archivedSessionIDs.contains($0.id)
                && (searchText.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                    || $0.preview.localizedCaseInsensitiveContains(searchText)
                    || $0.channelLabel.localizedCaseInsensitiveContains(searchText))
        }.sorted { ($0.activityAt ?? $0.startedAt ?? .distantPast) > ($1.activityAt ?? $1.startedAt ?? .distantPast) }
    }
    public var channelGroups: [ChannelGroup] {
        let groups = Dictionary(grouping: channelVisibleRows.filter { !isChannelPinned($0.id) }, by: { $0.source ?? "" })
        return groups.map { source, rows in
            ChannelGroup(source: source, sessions: rows, hasMore: channelMore[source] ?? false)
        }.sorted { ($0.sessions.first?.activityAt ?? $0.sessions.first?.startedAt ?? .distantPast)
            > ($1.sessions.first?.activityAt ?? $1.sessions.first?.startedAt ?? .distantPast) }
    }
    public func isChannelPinned(_ id: StoredSessionID) -> Bool { hierarchyClassification.pinnedChannelIDs.contains(id) }
    public func toggleChannelPin(_ id: StoredSessionID) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) {
            if !$0.pinnedChannelIDs.insert(id).inserted { $0.pinnedChannelIDs.remove(id) }
        }
    }
    public func isChannelCollapsed(_ source: String) -> Bool { hierarchyClassification.collapsedChannelSources.contains(source) }
    public func toggleChannelCollapsed(_ source: String) {
        guard let owner = currentHierarchyOwner else { return }
        classificationStore.update(for: owner) {
            if !$0.collapsedChannelSources.insert(source).inserted { $0.collapsedChannelSources.remove(source) }
        }
    }
    public func isChannelUnread(_ session: SessionSummary) -> Bool {
        guard let activity = session.activityAt else { return false }
        return activity > (hierarchyClassification.channelReadDates[session.id.rawValue] ?? .distantPast)
    }
    private func markChannelRead(_ id: StoredSessionID) {
        guard channelForeground, let owner = currentHierarchyOwner,
              let activity = sessions.first(where: { $0.id == id })?.activityAt else { return }
        classificationStore.update(for: owner) { $0.channelReadDates[id.rawValue] = activity }
    }
    private func resetChannels(preserveLoaded: Bool) {
        channelPollTask?.cancel(); channelPollTask = nil
        channelListRevision += 1; channelHistoryRevision += 1; channelSearchRevision += 1; channelHandoffRevision += 1
        isLoadingChannels = false; isLoadingChannelHistory = false; isSearchingChannels = false
        isLoadingChannelHandoff = false; channelHandoffSession = nil
        channelHandoffDestinations = []; channelHandoffStatus = nil
        channelChangeEvents = false; channelsDiscovered = false
        continuedChannelIDs = []; channelUnsettledTails = [:]; channelSearchResults = []; channelSearchError = nil
        if !preserveLoaded {
            channelRows = [:]; channelOffsets = [:]; channelMore = [:]
            channelDiscoveryOffset = 0; channelDiscoveryHasMore = false
            channelHistory = [:]; channelHistoryCounts = [:]; channelHistoryMore = [:]; channelResolvedIDs = [:]; unavailableChannelIDs = []
            channelError = nil; channelHistoryError = nil
        }
    }
    private func readChannel(_ resource: GatewayReadEndpoint, endpoint: GatewayEndpoint, session: GatewaySession) async throws -> JSONValue {
        let stamp = generation
        do {
            if let channelReader { return try await channelReader(session, resource) }
            return try await GatewayReader(session: session).read(resource)
        } catch {
            await recoverChannelSignIn(error, generation: stamp)
            throw error
        }
    }
    private func recoverChannelSignIn(_ error: Error, generation stamp: UUID) async {
        guard generation == stamp, error as? GatewayTransportError == .sessionExpired else { return }
        await disconnect()
        // disconnect retains cached transcripts and drafts while stopping all polling.
        // A concurrent reconnect owns its own UI and must not inherit this prompt.
        guard !isConnected, !isConnecting else { return }
        let message = GatewayTransportError.sessionExpired.localizedDescription
        channelError = message; channelHistoryError = message; banner = message
        showConnection = true
    }
    private func mergeChannelRowsIntoSessions() {
        var positions = Dictionary(sessions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for row in channelRows.values.flatMap({ $0 }) {
            if let index = positions[row.id] { sessions[index] = row }
            else { positions[row.id] = sessions.count; sessions.append(row) }
        }
    }
    private func mergeChannelSummaries(_ incoming: [SessionSummary], source: String, replace: Bool = false) {
        var rows = replace ? [] : channelRows[source] ?? []
        var positions = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for row in incoming {
            if let index = positions[row.id] { rows[index] = row }
            else { positions[row.id] = rows.count; rows.append(row) }
        }
        channelRows[source] = rows
    }
    private var protectedChannelIDs: Set<StoredSessionID> {
        Set(workspaces.flatMap(\.sessionIDs)).union(hierarchyClassification.pinnedChannelIDs)
            .union(hierarchyClassification.archivedSessionIDs)
            .union([homeSessionID, selectedID].compactMap { $0 })
    }
    private func hydrateChannelReference(_ id: StoredSessionID, endpoint: GatewayEndpoint, session: GatewaySession) async throws {
        let stamp = generation
        do {
            let row = try await readChannel(.channelSession(id: id.rawValue), endpoint: endpoint, session: session)
            guard generation == stamp, isConnected else { return }
            guard row["profile"]?.stringValue == nil || row["profile"]?.stringValue == endpoint.profile else { throw GatewayTransportError.invalidResponse }
            let summary = SessionSummary(json: row)
            guard summary.id == id else { throw GatewayTransportError.invalidResponse }
            unavailableChannelIDs.remove(id)
            if summary.isChannel { mergeChannelSummaries([summary], source: summary.source ?? "") }
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index] = summary }
            else { sessions.append(summary) }
        } catch GatewayTransportError.httpStatus(404) {
            guard generation == stamp, isConnected else { return }
            // A missing individual record is not an unsupported list endpoint.
            // Keep an explicit pin removable, and never implicitly resume missing history.
            unavailableChannelIDs.insert(id)
            if !sessions.contains(where: { $0.id == id }) {
                sessions.append(SessionSummary(json: .object(["id": .string(id.rawValue),
                    "title": .string("Unavailable conversation · " + String(id.rawValue.prefix(12)))])))
            }
        }
    }
    private func channelWindow(source: String?, through: Int, endpoint: GatewayEndpoint, session: GatewaySession) async throws -> (rows: [SessionSummary], offset: Int, hasMore: Bool) {
        var rows: [SessionSummary] = []; var offset = 0; var hasMore = true
        // ponytail: refresh the loaded window; use host cursors if very large histories make this costly.
        while offset < max(100, through), hasMore {
            try Task.checkCancellation()
            let page = try ChannelSessionPage(response: await readChannel(.channelSessions(source: source, limit: 100, offset: offset), endpoint: endpoint, session: session), profile: endpoint.profile, source: source)
            rows += page.sessions; hasMore = page.hasMore(offset: offset, limit: 100); offset += 100
        }
        return (rows, offset, hasMore)
    }
    public func refreshChannels() async {
        guard isConnected, !isLoadingChannels, let endpoint, let session else { return }
        let stamp = generation; channelListRevision += 1; let revision = channelListRevision
        isLoadingChannels = true
        defer { if generation == stamp, revision == channelListRevision { isLoadingChannels = false } }
        do {
            let seed = try await channelWindow(source: nil, through: channelDiscoveryOffset, endpoint: endpoint, session: session)
            guard generation == stamp, revision == channelListRevision, isConnected else { return }
            // Probe each known platform on first connection so one busy platform
            // cannot bury every older conversation from another platform.
            let sources = Set(seed.rows.compactMap(\.source)).union(channelRows.filter { !$0.value.isEmpty }.keys)
                .union(channelsDiscovered ? [] : ChannelSource.known)
            channelDiscoveryOffset = seed.offset; channelDiscoveryHasMore = seed.hasMore
            for row in seed.rows { mergeChannelSummaries([row], source: row.source ?? "") }
            for source in sources.sorted() {
                let page = try await channelWindow(source: source, through: channelOffsets[source] ?? 100, endpoint: endpoint, session: session)
                guard generation == stamp, revision == channelListRevision, isConnected else { return }
                let incomingIDs = Set(page.rows.map(\.id))
                let retainedIDs = protectedChannelIDs
                let retained = (channelRows[source] ?? []).filter { retainedIDs.contains($0.id) && !incomingIDs.contains($0.id) }
                // Replace the authoritative loaded window, not just its first page.
                sessions.removeAll { $0.source == source && !incomingIDs.contains($0.id) && !retainedIDs.contains($0.id) }
                mergeChannelSummaries(page.rows + retained, source: source, replace: true)
                channelOffsets[source] = page.offset; channelMore[source] = page.hasMore
            }
            mergeChannelRowsIntoSessions(); channelsDiscovered = true; channelError = nil
            let references = protectedChannelIDs
            for id in references where !sessions.contains(where: { $0.id == id }) || unavailableChannelIDs.contains(id) {
                do { try await hydrateChannelReference(id, endpoint: endpoint, session: session) }
                catch {
                    guard generation == stamp, revision == channelListRevision else { return }
                    channelError = "Saved conversation refresh failed. " + safeDescription(error)
                }
                guard generation == stamp, revision == channelListRevision, isConnected else { return }
            }
            mergeChannelRowsIntoSessions()
        } catch {
            guard generation == stamp, revision == channelListRevision else { return }
            mergeChannelRowsIntoSessions()
            if error is CancellationError { return }
            if error as? GatewayTransportError == .httpStatus(404) {
                channelError = "This host does not support channel discovery. Only its loaded conversations are shown."
            } else { channelError = "Channel refresh failed. " + safeDescription(error) }
        }
    }
    public func loadMoreChannels(source: String) async {
        guard isConnected, !isLoadingChannels, let endpoint, let session else { return }
        let stamp = generation; channelListRevision += 1; let revision = channelListRevision
        let offset = channelOffsets[source] ?? 0
        isLoadingChannels = true
        defer { if generation == stamp, revision == channelListRevision { isLoadingChannels = false } }
        do {
            let page = try ChannelSessionPage(response: await readChannel(.channelSessions(source: source, limit: 100, offset: offset), endpoint: endpoint, session: session), profile: endpoint.profile, source: source)
            guard generation == stamp, revision == channelListRevision, isConnected else { return }
            mergeChannelSummaries(page.sessions, source: source)
            channelOffsets[source] = offset + 100
            channelMore[source] = page.hasMore(offset: offset, limit: 100)
            mergeChannelRowsIntoSessions(); channelError = nil
        } catch { if generation == stamp, revision == channelListRevision { channelError = safeDescription(error) } }
    }
    public func loadMoreChannelSources() async {
        guard isConnected, !isLoadingChannels, let endpoint, let session else { return }
        let stamp = generation; channelListRevision += 1; let revision = channelListRevision
        let offset = channelDiscoveryOffset
        isLoadingChannels = true
        defer { if generation == stamp, revision == channelListRevision { isLoadingChannels = false } }
        do {
            let page = try ChannelSessionPage(response: await readChannel(.channelSessions(source: nil, limit: 100, offset: offset), endpoint: endpoint, session: session), profile: endpoint.profile, source: nil)
            guard generation == stamp, revision == channelListRevision, isConnected else { return }
            for row in page.sessions { mergeChannelSummaries([row], source: row.source ?? "") }
            channelDiscoveryOffset = offset + 100
            channelDiscoveryHasMore = page.hasMore(offset: offset, limit: 100)
            for source in Set(page.sessions.compactMap(\.source)) where channelOffsets[source] == nil { channelMore[source] = true }
            mergeChannelRowsIntoSessions(); channelError = nil
        } catch { if generation == stamp, revision == channelListRevision { channelError = safeDescription(error) } }
    }
    public func searchChannelHistory() async {
        guard isConnected, let endpoint, let session else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        channelSearchRevision += 1; let revision = channelSearchRevision; let stamp = generation
        channelSearchResults = []; channelSearchError = nil
        guard !query.isEmpty else { isSearchingChannels = false; return }
        isSearchingChannels = true
        defer { if generation == stamp, revision == channelSearchRevision { isSearchingChannels = false } }
        do {
            let response = try await readChannel(.channelSearch(query: query), endpoint: endpoint, session: session)
            guard generation == stamp, revision == channelSearchRevision, query == searchText.trimmingCharacters(in: .whitespacesAndNewlines), isConnected else { return }
            guard let results = response["results"]?.arrayValue else { throw GatewayTransportError.invalidResponse }
            var seen = Set<StoredSessionID>()
            for result in results {
                guard result["profile"]?.stringValue == nil || result["profile"]?.stringValue == endpoint.profile else { throw GatewayTransportError.invalidResponse }
                var row = result.objectValue ?? [:]
                row["id"] = result["session_id"] ?? result["id"]
                row["preview"] = result["snippet"] ?? result["preview"]
                let summary = SessionSummary(json: .object(row))
                if summary.isChannel, !summary.id.rawValue.isEmpty, seen.insert(summary.id).inserted {
                    channelSearchResults.append(summary)
                    mergeChannelSummaries([summary], source: summary.source ?? "")
                }
            }
            mergeChannelRowsIntoSessions()
        } catch { if generation == stamp, revision == channelSearchRevision { channelSearchError = safeDescription(error) } }
    }
    private func openChannelSession(_ id: StoredSessionID) async {
        guard isConnected, !isLoadingSession, let owner = currentHierarchyOwner else { return }
        channelHistoryRevision += 1; isLoadingChannelHistory = false; channelHistoryError = nil
        if conversations[id] == nil {
            do {
                var state = try ConversationState(snapshot: .object([
                    "session_id": .string("mirror:" + id.rawValue), "stored_session_id": .string(id.rawValue),
                    "info": .object(["title": .string(sessions.first { $0.id == id }?.displayTitle ?? "Conversation")])
                ]), owner: owner)
                state.messages = channelHistory[id] ?? []; state.requiresHydration = true
                conversations[id] = state
            } catch { channelHistoryError = safeDescription(error); return }
        }
        select(id)
        await refreshChannelHistory()
        if id == homeSessionID { homeAvailability = channelHistoryError.map(HomeAvailability.failed) ?? .available; cacheHomeTranscript() }
    }
    public func refreshChannelHistory() async { await loadChannelHistory(older: false) }
    public func loadOlderChannelMessages() async { await loadChannelHistory(older: true) }
    private func loadChannelHistory(older: Bool) async {
        guard isConnected, !isLoadingChannelHistory, let id = selectedID, isChannelSession(id),
              conversations[id]?.isRunning != true, !isSubmitting,
              let endpoint, let session else { return }
        let stamp = generation; channelHistoryRevision += 1; let revision = channelHistoryRevision
        let baseline = conversations[id]?.messages
        isLoadingChannelHistory = true
        defer { if generation == stamp, revision == channelHistoryRevision { isLoadingChannelHistory = false } }
        do {
            // Re-read the loaded window when paging: latest offsets shift whenever
            // another client appends a turn. Stable persisted IDs preserve row identity.
            let desired = max(100, channelHistoryCounts[id] ?? 100) + (older ? 100 : 0)
            var messages: [ChatMessage] = []; var count = 0; var hasMore = true; var resolved = id
            while count < desired && hasMore {
                let limit = min(100, desired - count)
                let page = try ChannelMessagePage(response: await readChannel(.channelMessages(id: id.rawValue, limit: limit, offset: count), endpoint: endpoint, session: session), profile: endpoint.profile, requestedID: id)
                guard generation == stamp, revision == channelHistoryRevision, selectedID == id, isConnected else { return }
                guard page.offset == count, page.limit == limit, count == 0 || resolved == page.resolvedID else { throw GatewayTransportError.invalidResponse }
                messages = page.messages + messages; resolved = page.resolvedID
                count += page.returned; hasMore = page.returned >= limit
            }
            guard conversations[id]?.isRunning != true, !isSubmitting,
                  isPassiveChannel || conversations[id]?.messages == baseline else { return }
            var seen = Set<String>()
            messages = messages.filter { seen.insert($0.id).inserted }
            // A new tail must not evict history the user already scrolled to.
            let old = channelHistory[id] ?? []
            if let unsettled = channelUnsettledTails[id] {
                let oldIDs = Set(old.map(\.id))
                guard messages.contains(where: { $0.role == unsettled.role && $0.text == unsettled.text && !oldIDs.contains($0.id) }) else { return }
                channelUnsettledTails.removeValue(forKey: id)
            }
            let retained = hasMore ? old.filter { !seen.contains($0.id) } : []
            channelHistory[id] = retained + messages
            channelHistoryCounts[id] = max(count, channelHistory[id]?.count ?? count)
            channelHistoryMore[id] = hasMore; channelResolvedIDs[id] = resolved
            conversations[id]?.messages = channelHistory[id] ?? []
            if isPassiveChannel { conversations[id]?.requiresHydration = true; conversations[id]?.status = "Mirrored conversation" }
            channelHistoryError = nil; markChannelRead(id)
        } catch {
            guard generation == stamp, revision == channelHistoryRevision, selectedID == id else { return }
            channelHistoryError = "Conversation refresh failed. " + safeDescription(error)
        }
    }
    private func moveChannelIdentity(from old: StoredSessionID, to new: StoredSessionID) {
        guard old != new, isChannelSession(old) else { return }
        if continuedChannelIDs.remove(old) != nil { continuedChannelIDs.insert(new) }
        channelHistory[new] = channelHistory[old]
        channelHistoryCounts[new] = channelHistoryCounts[old]
        channelHistoryMore[new] = channelHistoryMore[old]
        channelUnsettledTails[new] = channelUnsettledTails.removeValue(forKey: old)
        channelResolvedIDs[old] = new; channelResolvedIDs[new] = new
        if let previous = sessions.first(where: { $0.id == old }), !sessions.contains(where: { $0.id == new }) {
            var json: [String: JSONValue] = ["id": .string(new.rawValue), "title": .string(previous.title)]
            if let source = previous.source { json["source"] = .string(source) }
            let summary = SessionSummary(json: .object(json))
            sessions.append(summary)
            if let source = previous.source { mergeChannelSummaries([summary], source: source) }
        }
        if let owner = currentHierarchyOwner {
            classificationStore.update(for: owner) { value in
                if value.homeSessionID == old { value.homeSessionID = new }
                for index in value.workspaces.indices {
                    value.workspaces[index].sessionIDs = value.workspaces[index].sessionIDs.map { $0 == old ? new : $0 }
                }
                if value.pinnedChannelIDs.remove(old) != nil { value.pinnedChannelIDs.insert(new) }
                if value.archivedSessionIDs.remove(old) != nil { value.archivedSessionIDs.insert(new) }
                value.channelReadDates[new.rawValue] = value.channelReadDates[old.rawValue]
            }
            classificationStore.rememberPlace(classificationStore.place(for: old, owner: owner).visibleMessageID,
                                              for: new, owner: owner)
        }
        if hierarchyDestination == .conversation(old) { hierarchyDestination = .conversation(new) }
    }
    public func continueChannelInTalaria() async {
        guard isPassiveChannel, isConnected, !isLoadingSession, !isLoadingChannelHistory,
              telegramDestinationIsReady, let id = selectedID else { return }
        let stamp = generation
        await refreshChannelHistory()
        guard generation == stamp, selectedID == id, channelHistoryError == nil else { return }
        let target = channelResolvedIDs[id] ?? id
        await resumeNativeSession(target, force: true)
        guard generation == stamp, let state = conversation,
              state.runtimeID.rawValue != "mirror:" + state.storedID.rawValue,
              state.storedID == target || state.storedID == id else { return }
        continuedChannelIDs.insert(state.storedID)
        if state.storedID != id {
            moveChannelIdentity(from: id, to: state.storedID)
            moveComposer(from: ComposerScope(owner: state.owner, sessionID: id), to: ComposerScope(owner: state.owner, sessionID: state.storedID))
            channelHistory[state.storedID] = channelHistory[id]
            channelHistoryCounts[state.storedID] = channelHistoryCounts[id]
            if case .conversation = hierarchyDestination { hierarchyDestination = .conversation(state.storedID) }
        }
    }
    public func renameChannel(id: StoredSessionID, title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !title.isEmpty, title.count <= 200, let endpoint, let session else { return }
        let stamp = generation
        do {
            _ = try await GatewayReader(session: session).renameSession(id: id.rawValue, title: title)
            guard generation == stamp else { return }
            conversations[id]?.title = title
            for key in channelRows.keys {
                if let index = channelRows[key]?.firstIndex(where: { $0.id == id }) { channelRows[key]?[index].title = title }
            }
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = title }
            channelError = nil
        } catch {
            if generation == stamp { channelError = safeDescription(error) }
            await recoverChannelSignIn(error, generation: stamp)
        }
    }
    public func setChannelForeground(_ foreground: Bool) {
        channelForeground = foreground
        channelPollTask?.cancel(); channelPollTask = nil
        if foreground, isConnected {
            startChannelPolling()
            Task { [weak self] in await self?.refreshChannels(); await self?.refreshVisibleChannel() }
        }
    }
    private func refreshVisibleChannel() async {
        guard channelForeground, isViewingChannel else { return }
        // Existing explicit topic bindings are the only authority after /reset.
        if telegramAssignment(for: hierarchyDestination) != nil {
            let old = selectedID
            await refreshTelegramTopics()
            guard isConnected, channelForeground else { return }
            if let assignment = telegramAssignment(for: hierarchyDestination), assignment.lastKnownSessionID != old,
               telegramTopics.contains(where: { $0.currentSessionID == assignment.lastKnownSessionID }) {
                await openChannelSession(assignment.lastKnownSessionID); return
            }
        }
        await refreshChannelHistory()
    }
    private func startChannelPolling() {
        channelPollTask?.cancel()
        guard channelForeground, isConnected else { return }
        let stamp = generation
        channelPollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.generation == stamp, self.isConnected, self.channelForeground else { return }
                ticks += 1
                if !self.channelChangeEvents && ticks.isMultiple(of: 2) { await self.refreshChannels() }
                if !self.channelChangeEvents || ticks.isMultiple(of: 6) { await self.refreshVisibleChannel() }
                if self.channelHandoffSession != nil { await self.refreshChannelHandoffState() }
            }
        }
    }
    public func loadChannelHandoffDestinations() async {
        guard isConnected, let endpoint, let session, !isLoadingChannelHandoff else { return }
        let stamp = generation; channelHandoffRevision += 1; let revision = channelHandoffRevision
        isLoadingChannelHandoff = true
        defer { if generation == stamp, revision == channelHandoffRevision { isLoadingChannelHandoff = false } }
        do {
            let result = try await readChannel(.messagingPlatforms, endpoint: endpoint, session: session)
            guard generation == stamp, revision == channelHandoffRevision else { return }
            guard let platforms = result["platforms"]?.arrayValue else { throw GatewayTransportError.invalidResponse }
            channelHandoffDestinations = platforms.compactMap { row in
                guard let id = row["id"]?.stringValue, row["enabled"]?.boolValue == true,
                      row["configured"]?.boolValue == true,
                      let home = row["home_channel"], let chat = home["chat_id"]?.stringValue, !chat.isEmpty else { return nil }
                let name = home["name"]?.stringValue ?? chat
                let topic = home["thread_id"]?.stringValue.map { " · Topic " + $0 } ?? ""
                return ChannelHandoffDestination(id: id, label: ChannelSource.label(id) + " · " + name + topic,
                    isAvailable: row["gateway_running"]?.boolValue == true)
            }
        } catch { if generation == stamp, revision == channelHandoffRevision { channelHandoffStatus = safeDescription(error) } }
    }
    public func handoffChannel(to platform: String) async {
        guard isConnected, !isPassiveChannel, !isLoadingChannelHandoff, !isSubmitting,
              let state = conversation, !state.isRunning, !state.requiresHydration,
              !state.hasQueuedPrompt, channelHandoffSession == nil,
              channelHandoffDestinations.contains(where: { $0.id == platform && $0.isAvailable }) else { return }
        let stamp = generation; let client = client
        isLoadingChannelHandoff = true
        channelHandoffSession = state.runtimeID; channelHandoffStatus = "pending"
        defer { if generation == stamp { isLoadingChannelHandoff = false } }
        do {
            let result = try await client.request("handoff.request", params: .object([
                "session_id": .string(state.runtimeID.rawValue), "profile": .string(state.owner.profile), "platform": .string(platform)]))
            guard generation == stamp else { return }
            guard result["queued"]?.boolValue == true else { throw GatewayTransportError.invalidResponse }
            channelHandoffSession = state.runtimeID; channelHandoffStatus = "pending"
        } catch {
            if generation == stamp {
                if error is JSONRPCError { channelHandoffSession = nil; channelHandoffStatus = safeDescription(error) }
                else { channelHandoffStatus = "Transfer status unavailable. " + safeDescription(error) }
            }
        }
    }
    public func refreshChannelHandoffState() async {
        guard isConnected, let runtime = channelHandoffSession, let endpoint else { return }
        let stamp = generation
        do {
            let result = try await client.request("handoff.state", params: .object([
                "session_id": .string(runtime.rawValue), "profile": .string(endpoint.profile)]))
            guard generation == stamp, runtime == channelHandoffSession else { return }
            let state = result["state"]?.stringValue ?? ""
            if state.isEmpty { channelHandoffSession = nil; channelHandoffStatus = "No transfer queued."; return }
            guard ["pending", "running", "completed", "failed"].contains(state) else { throw GatewayTransportError.invalidResponse }
            channelHandoffStatus = state
            if state == "completed" || state == "failed" {
                channelHandoffSession = nil
                if state == "completed" {
                    for id in conversations.keys where conversations[id]?.runtimeID == runtime {
                        continuedChannelIDs.remove(id); conversations[id]?.requiresHydration = true
                    }
                }
            }
        } catch { if generation == stamp { channelHandoffStatus = "Transfer status unavailable. " + safeDescription(error) } }
    }
}
