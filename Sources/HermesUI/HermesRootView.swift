import SwiftUI
import HermesCore
import HermesProtocol
import HermesTransport
import UniformTypeIdentifiers

public struct HermesRootView: View {
    @Bindable private var model: HermesAppModel
    private let startLocal: (@MainActor () async -> Void)?
    private let connectSSH: (@MainActor (GatewayEndpoint, String?, String?, String?, Bool) async -> GatewayAuthentication?)?
    private let reconnectSSH: (@MainActor () async -> Void)?
    private let endSSH: (@MainActor (Bool) async -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var startingLocal = false
    @State private var selection: StoredSessionID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(model: HermesAppModel, startLocal: (@MainActor () async -> Void)? = nil,
                connectSSH: (@MainActor (GatewayEndpoint, String?, String?, String?, Bool) async -> GatewayAuthentication?)? = nil,
                reconnectSSH: (@MainActor () async -> Void)? = nil,
                endSSH: (@MainActor (Bool) async -> Void)? = nil) {
        self.model = model; self.startLocal = startLocal
        self.connectSSH = connectSSH; self.reconnectSSH = reconnectSSH; self.endSSH = endSSH
    }

    public var body: some View {
        Group {
            #if os(macOS)
            MacWorkspaceView(model: model) {
                VStack(spacing: 0) {
                    if model.isConnected, let banner = model.banner { connectionBanner(banner) }
                    macHierarchyContent
                }
                .overlay(alignment: .top) {
                    if !model.isConnected, model.endpoint != nil {
                        connectionBanner(model.banner ?? (model.isConnecting ? "Reconnecting…" : "Disconnected"))
                            .padding(.top, 12).padding(.horizontal, 16)
                    }
                }
            }
            .talariaWindowBackground()
            #else
            IOSWorkspaceView(model: model)
            #endif
        }
        .tint(TalariaStyle.accent)
        .onChange(of: scenePhase, initial: true) { _, phase in model.setChannelForeground(phase == .active) }
        .onOpenURL { url in Task { _ = await model.openHierarchyLink(url) } }
        .sheet(isPresented: $model.showConnection) {
            ConnectionView(model: model, connectSSH: connectSSH, endSSH: endSSH)
        }
        .sheet(isPresented: $model.showSessionSettings) {
            SessionSettingsView(state: SessionSettingsViewState(snapshot: model.settingsSnapshot,
                profile: model.endpoint?.profile ?? "default", sessionID: settingsConversation?.runtimeID.rawValue,
                isLoading: model.isLoadingSettings, isApplying: model.isApplyingSettings || model.isSubmitting || model.conversation?.isRunning == true,
                errorMessage: model.settingsError, workingDirectory: settingsConversation?.cwd),
                onRefresh: { await model.loadSettings(refresh: true) },
                onSelectModel: { selection, confirmed in
                    guard settingsConversation != nil else { return nil }
                    return await model.selectModel(selection, confirmed: confirmed)
                },
                onSelectProfile: { await model.selectProfile($0) })
                .task { await model.loadSettings() }
        }
        #if os(iOS)
        .onChange(of: selection) { _, id in
            if horizontalSizeClass != .compact, let id, id != model.selectedID {
                Task { await model.openSession(id) }
            }
        }
        .onChange(of: model.selectedID) { _, id in
            guard horizontalSizeClass != .compact else { return }
            selection = id
            if id != nil { preferredColumn = .detail }
        }
        #endif
    }

    private func reconnect() async {
        if model.endpoint?.ssh != nil, let reconnectSSH { await reconnectSSH() }
        else { await model.reconnect() }
    }

    /// List and Run destinations retain a selected conversation for drafts, but
    /// it is not a valid implicit target for an unrelated Settings sheet.
    private var settingsConversation: ConversationState? {
        guard !model.isPassiveChannel, let state = model.conversation, state.owner == model.currentHierarchyOwner else { return nil }
        switch model.hierarchyDestination {
        case .home: return state.storedID == model.homeSessionID && model.homeAvailability == .available ? state : nil
        case .workspace(let id): return model.workspace(id: id)?.sessionIDs.contains(state.storedID) == true ? state : nil
        case .conversation(let id): return id == state.storedID ? state : nil
        default: return nil
        }
    }

    #if os(macOS)
    @ViewBuilder private var macHierarchyContent: some View {
        if model.endpoint == nil && !model.isConnected {
            welcome
        } else if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView {
                HierarchySearchResults(model: model, onNavigate: navigateHierarchy)
                    .padding(.horizontal, T.chatInset).padding(.vertical, 24)
            }
        } else {
            switch model.hierarchyDestination {
            case .home where model.homeAvailability == .available:
                if let state = model.homeSessionID.flatMap({ model.conversations[$0] }), model.selectedID == state.storedID {
                    ConversationView(model: model, state: state).id(state.storedID)
                } else { hierarchyContent }
            case .workspace(let id):
                if let workspace = model.workspace(id: id), let state = model.conversation,
                   workspace.sessionIDs.contains(state.storedID) {
                    HierarchyWorkspaceHeader(model: model, workspace: workspace, onNavigate: navigateHierarchy)
                        .padding(.horizontal, T.chatInset).padding(.top, 12)
                    ConversationView(model: model, state: state).id(state.storedID)
                } else { hierarchyContent }
            case .conversation(let id):
                if let state = model.conversations[id], model.selectedID == id {
                    HierarchyConversationNotice(model: model, sessionID: id, onNavigate: navigateHierarchy)
                    ConversationView(model: model, state: state).id(state.storedID)
                } else { hierarchyContent }
            default: hierarchyContent
            }
        }
    }
    private var hierarchyContent: some View {
        HierarchyContentView(model: model, destination: model.hierarchyDestination, onNavigate: navigateHierarchy)
    }
    private func navigateHierarchy(_ destination: HierarchyDestination) {
        model.searchText = ""
        Task { await model.navigate(to: destination) }
    }
    #endif

    private var mobileNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                sidebarContent
                Divider()
                connectionControls
            }
            .navigationTitle("Talaria")
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.newConversation() } } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                    }
                    .help("New conversation (⌘N)")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.isConnected || model.isLoadingSession)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner { connectionBanner(banner) }
                if let conversation = model.conversation {
                    ConversationView(model: model, state: conversation)
                } else {
                    welcome
                }
            }
            .navigationTitle(model.conversation?.title ?? "Talaria")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if model.isLoadingSession {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading conversation")
                    } else if model.isConnected {
                        Button { Task { await model.refreshSessions() } } label: {
                            Label("Refresh conversations", systemImage: "arrow.clockwise")
                        }.help("Refresh conversations")
                    }
                }
            }
        }
    }

    private var sidebarContent: some View {
        Group {
            if model.filteredSessions.isEmpty {
                sidebarEmptyState
            } else {
                List(selection: $selection) {
                    Section("Conversations") {
                        ForEach(model.filteredSessions) { session in
                            NavigationLink(value: session.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(model.conversations[session.id]?.title ?? session.displayTitle)
                                            .font(TalariaTypography.body.weight(.medium)).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if model.conversations[session.id]?.isRunning == true {
                                            Image(systemName: "circle.fill")
                                                .font(TalariaTypography.caption2).foregroundStyle(TalariaStyle.accent)
                                                .accessibilityLabel("Reply in progress")
                                        }
                                        if model.conversations[session.id]?.pendingInputs.isEmpty == false {
                                            Image(systemName: "hand.raised")
                                                .foregroundStyle(TalariaStyle.accent)
                                                .accessibilityLabel("Needs your answer")
                                        }
                                    }
                                    if !session.preview.isEmpty {
                                        Text(session.preview).font(TalariaTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 7)
                                .frame(minHeight: 44)
                            }.tag(session.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(!model.isConnected || model.isLoadingSession)
            }
        }
        .searchable(text: $model.searchText, prompt: "Find a conversation")
    }

    private var sidebarEmptyState: some View {
        Group {
            if !model.searchText.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else if showsSidebarWelcome {
                ContentUnavailableView {
                    TalariaMark(size: 56).accessibilityHidden(true)
                    Text(model.isConnected ? "A fresh start" : "Welcome to Talaria")
                } description: {
                    Text(model.isConnected ? "Start a conversation with Hermes." : "Connect your Hermes agent to get started.")
                } actions: {
                    connectionActions
                        .frame(maxWidth: 300)
                }
            } else {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(model.isConnected ? "Your conversations will appear here." : "Connect to Hermes to see your conversations.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsSidebarWelcome: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var connectionControls: some View {
        VStack(spacing: 2) {
            if model.isConnected {
                Button { model.showSessionSettings = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.rectangle.stack").foregroundStyle(.secondary)
                        Text(model.endpoint?.profile ?? "default").font(TalariaTypography.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(TalariaTypography.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile: \(model.endpoint?.profile ?? "default")")
                .accessibilityHint("Opens model and profile settings")
            }
            Button { model.showConnection = true } label: {
                HStack(spacing: 10) {
                    Circle().fill(model.isConnected ? TalariaStyle.accent : Color.secondary)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.endpoint?.name ?? "Connect to Hermes").font(TalariaTypography.callout.weight(.medium)).lineLimit(1)
                        Text(model.isConnecting ? "Connecting…" : model.isConnected ? "Connected" : "Disconnected")
                            .font(TalariaTypography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens connection settings")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func connectionBanner(_ message: String) -> some View {
        #if os(macOS)
        HStack(spacing: 8) {
            Circle().fill(T.failed).frame(width: 7, height: 7)
            Text(message).font(T.f(11.5)).lineLimit(3).textSelection(.enabled)
            if !model.isConnected, model.endpoint != nil {
                Button("Retry now") { Task { await reconnect() } }
                    .font(T.f(11.5, .semibold)).buttonStyle(.plain).foregroundStyle(T.deep).disabled(model.isConnecting)
            } else {
                Button { model.banner = nil } label: { Image(systemName: "xmark").font(T.f(10)) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
            }
        }.padding(.horizontal, 14).padding(.vertical, 10).floatingGlass(18)
        #else
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).padding(.top, 12)
                Text(message).font(TalariaTypography.callout).textSelection(.enabled).padding(.vertical, 10)
                Spacer(minLength: 0)
                Button { model.banner = nil } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
            }
            if model.endpoint != nil {
                Button("Reconnect") { Task { await reconnect() } }
                    .frame(minHeight: 44).talariaSecondaryButton().disabled(model.isConnecting)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(.quaternary.opacity(0.35))
        #endif
    }

    private var welcome: some View {
        #if os(macOS)
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    TalariaMark(size: 76)
                    Text(model.isConnected ? "Ready when you are." : "Hermes, made native.")
                        .font(T.f(25, .medium)).foregroundStyle(T.ink)
                        .multilineTextAlignment(.center)
                    Text(model.isConnected ? "Start a conversation, bring a file, and work through your next idea." : "Your Hermes agent, at home on your Mac and iPhone.")
                        .font(T.body).foregroundStyle(T.ink2).multilineTextAlignment(.center)
                    connectionActions
                }
                .frame(maxWidth: 320).padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        #else
        ScrollView {
            VStack(spacing: 24) {
                TalariaMark(size: 76).accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(model.isConnected ? "Ready when you are." : "Hermes, made native.")
                        .font(TalariaTypography.largeTitle.weight(.medium)).multilineTextAlignment(.center)
                    Text(model.isConnected ? "Start a conversation, bring a file, and work through your next idea." : "Your Hermes agent, at home on your Mac and iPhone.")
                        .font(TalariaTypography.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                connectionActions.frame(maxWidth: 320)
            }
            .frame(maxWidth: 520).padding(32).padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var connectionActionHeight: CGFloat {
        #if os(macOS)
        0 // The button style supplies the exact 36pt height.
        #else
        44
        #endif
    }

    private var connectionActions: some View {
        VStack(spacing: 12) {
            if model.isConnected {
                Button { Task { await model.newConversation() } } label: {
                    Label("New conversation", systemImage: "square.and.pencil").frame(minHeight: connectionActionHeight)
                }
                .talariaProminentButton().disabled(model.isLoadingSession)
            } else {
                if let startLocal {
                    Button {
                        startingLocal = true
                        Task { await startLocal(); startingLocal = false }
                    } label: {
                        Text(startingLocal ? "Starting Hermes…" : "Start local Hermes").frame(minHeight: connectionActionHeight)
                    }
                    .talariaProminentButton().disabled(startingLocal || model.isConnecting)
                }
                Button { model.showConnection = true } label: {
                    Text(model.isConnecting ? "Connecting…" : "Connect to a gateway").frame(minHeight: connectionActionHeight)
                }.talariaSecondaryButton().disabled(model.isConnecting)
                Text(startLocal == nil ? "Use Hermes running on your Mac or server." : "Uses your existing Hermes installation and selected model.")
                    #if os(macOS)
                    .font(T.status).foregroundStyle(T.ink3)
                    #else
                    .font(TalariaTypography.caption).foregroundStyle(.secondary)
                    #endif
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ConversationView: View {
    @Bindable var model: HermesAppModel
    let state: ConversationState
    @State private var followTail = true
    @State private var showImporter = false
    @State private var importScope: ComposerScope?
    @State private var visibleMessageID: String?
    @State private var highlightsRequest = false
    @State private var showsActivityReturn = false
    #if os(macOS)
    @State private var composerFocused = false
    #else
    @FocusState private var composerFocused: Bool
    #endif
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    #if os(iOS)
    @ScaledMetric(relativeTo: .body) private var composerHeight: CGFloat = 76
    #endif

    private var contentInset: CGFloat {
        #if os(macOS)
        36
        #else
        16
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack(spacing: 12) {
                Label(state.status, systemImage: state.isRunning ? "sparkles" : "checkmark.circle")
                    .font(TalariaTypography.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button { model.showSessionSettings = true } label: {
                    HStack(spacing: 6) {
                        Text(state.model.isEmpty ? "Choose model" : state.model).lineLimit(1)
                        Image(systemName: "chevron.down").font(TalariaTypography.caption2)
                    }
                    .font(TalariaTypography.callout).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.isConnected || model.isPassiveChannel).help("Model and profile settings")
                .accessibilityLabel("Model: \(state.model.isEmpty ? "Not selected" : state.model)")
                .accessibilityHint("Opens model and profile settings")
            }
            .padding(.horizontal, contentInset).padding(.vertical, 4)
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ChannelHistoryControls(model: model)
                        if state.messages.isEmpty && !model.isPassiveChannel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("What are we working on?").font(TalariaTypography.title2.weight(.medium))
                                Text("Ask a question, share a file, or start with an idea.")
                                    .font(TalariaTypography.body).foregroundStyle(.secondary)
                            }.padding(.vertical, 40)
                        }
                        #if os(macOS)
                        let groups = macTranscriptGroups
                        ForEach(groups) { group in
                            // Keep session-owned cards visually adjacent without
                            // assigning them a message ID the gateway never sent.
                            VStack(alignment: .leading, spacing: 8) {
                                MacTranscriptGroupView(group: group,
                                    assistantName: model.endpoint?.name ?? "Hermes", workerTask: workerTask)
                                if group.id == groups.last?.id { sessionCards }
                            }
                        }
                        if groups.isEmpty { sessionCards }
                        #else
                        ForEach(transcriptGroups) { group in
                            if group.isToolGroup {
                                ToolActivityCard(messages: group.messages)
                            } else if let message = group.messages.first {
                                MessageView(message: message, assistantName: model.endpoint?.name ?? "Hermes")
                            }
                        }
                        if state.storedID == model.homeSessionID { homeReferences }
                        requestCards
                        #endif
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: 760).padding(.horizontal, contentInset).padding(.top, 24).padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition(id: $visibleMessageID, anchor: .top)
                .onChange(of: visibleMessageID) { _, value in
                    model.rememberPlace(value, for: state.storedID)
                }
                .onChange(of: state.messages.last) { _, _ in if followTail && !model.isPassiveChannel { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: state.pendingInputs.count) { _, _ in if followTail && !model.isPassiveChannel { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: state.storedID) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                .onAppear {
                    if model.isPassiveChannel { followTail = false }
                    if let saved = model.place(for: state.storedID).visibleMessageID {
                        followTail = false
                        #if os(macOS)
                        // Older reading places may point to a tool that now
                        // lives inside its issuing assistant's turn.
                        let anchor = macTranscriptGroups.first {
                            $0.id == saved || $0.tools.contains { $0.id == saved }
                        }?.id ?? saved
                        #else
                        let anchor = saved
                        #endif
                        visibleMessageID = anchor
                        proxy.scrollTo(anchor, anchor: .top)
                    } else { proxy.scrollTo("tail", anchor: .bottom) }
                }
                .task(id: model.activityRequestFocusID) {
                    guard let requestID = model.activityRequestFocusID,
                          state.pendingInputs.contains(where: { $0.id == requestID }) else { return }
                    followTail = false; showsActivityReturn = true; highlightsRequest = true
                    #if os(macOS)
                    // Materialize the last lazy row before targeting a request
                    // inside its auxiliary cards (including a saved place far above).
                    proxy.scrollTo(macTranscriptGroups.last?.id ?? "tail", anchor: .bottom)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    #endif
                    proxy.scrollTo(requestID, anchor: .center)
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    highlightsRequest = false
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    showsActivityReturn = false
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.isPassiveChannel {
            composer
                #if os(macOS)
                .frame(maxWidth: T.composerMaxW).padding(.horizontal, T.chatInset).padding(.top, 14).padding(.bottom, 18)
                #else
                .frame(maxWidth: 760).padding(.horizontal, contentInset).padding(.top, 8).padding(.bottom, 12)
                #endif
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: state.storedID) { _, _ in composerFocused = true }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let scope = importScope else { return }
            switch result {
            case .success(let urls): Task { await model.addAttachments(urls, to: scope) }
            case .failure(let error): model.banner = error.localizedDescription
            }
            importScope = nil
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "talaria" { Task { _ = await model.openHierarchyLink(url) }; return .handled }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction(url)
        })
    }

    private var homeReferences: some View {
        HierarchyHomeReferences(model: model, onNavigate: { destination in
            Task { await model.navigate(to: destination) }
        })
    }

    @ViewBuilder private var requestCards: some View {
        ForEach(state.pendingInputs) { input in
            VStack(alignment: .leading, spacing: 8) {
                if showsActivityReturn, input.id == model.activityRequestFocusID {
                    Button("‹ Back to Activity") { Task { await model.navigate(to: .activity) } }
                        .font(TalariaTypography.caption).buttonStyle(.plain).foregroundStyle(TalariaStyle.accent)
                }
                InputRequestView(input: input) { result in
                    await model.answer(input, result: result)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                highlightsRequest && input.id == model.activityRequestFocusID
                    ? TalariaStyle.attention.opacity(0.6) : .clear, lineWidth: 2))
            .id(input.id)
        }
        ForEach(model.requestReceipts(for: state.storedID)) { receipt in
            RequestReceiptView(receipt: receipt)
                .id("request-receipt-\(receipt.id)")
        }
    }

    #if os(macOS)
    private var macTranscriptGroups: [MacTranscriptGroup] { MacTranscriptGroup.make(state.messages) }

    @ViewBuilder private var sessionCards: some View {
        if hasHomeReferences || !state.pendingInputs.isEmpty || !model.requestReceipts(for: state.storedID).isEmpty {
            MacTranscriptAuxiliary {
                VStack(alignment: .leading, spacing: 8) {
                    if hasHomeReferences { homeReferences }
                    requestCards
                }
            }
        }
    }

    private var workerTask: String? {
        guard model.hierarchyFeatures.delegatedTasks,
              model.hierarchyClassification.lineage.contains(where: {
                  $0.childSessionID == state.storedID && $0.kind == .delegated
              }) else { return nil }
        return state.title
    }

    private var hasHomeReferences: Bool {
        guard state.storedID == model.homeSessionID else { return false }
        return model.hierarchyClassification.lineage.contains { record in
            record.parentSessionID == state.storedID && (record.kind == .branch || record.kind == .delegated)
                && model.workspaces.contains { !$0.isArchived && $0.sessionIDs.contains(record.childSessionID) }
        }
    }
    #else
    private struct TranscriptGroup: Identifiable {
        let messages: [ChatMessage]
        var id: String { messages[0].id }
        var isToolGroup: Bool { messages[0].role == .tool }
    }

    private var transcriptGroups: [TranscriptGroup] {
        var groups: [[ChatMessage]] = []
        for message in state.messages {
            if message.role == .tool, groups.last?.last?.role == .tool {
                groups[groups.count - 1].append(message)
            } else {
                groups.append([message])
            }
        }
        return groups.map { TranscriptGroup(messages: $0) }
    }

    #endif

    private var transcriptFont: Font {
        #if os(macOS)
        T.body
        #else
        .body
        #endif
    }

    private var composerSpacing: CGFloat {
        #if os(macOS)
        10
        #else
        4
        #endif
    }

    private var utilityFont: Font {
        #if os(macOS)
        T.f(14)
        #else
        .body
        #endif
    }

    private var utilityColor: Color {
        #if os(macOS)
        T.ink2
        #else
        .primary
        #endif
    }

    private var utilitySize: CGFloat {
        #if os(macOS)
        34
        #else
        44
        #endif
    }

    #if os(macOS)
    private var modelPillTitle: String {
        let name = state.model.isEmpty ? "Choose model" : state.model
        if let effort = model.settingsSnapshot?.reasoningEffort, !effort.isEmpty {
            return "\(name) · \(effort.capitalized)"
        }
        return name
    }

    private var modelPicker: some View {
        Menu {
            Button("Model and profile settings…") { model.showSessionSettings = true }
        } label: {
            HStack(spacing: 6) {
                Text(modelPillTitle).font(T.pill).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(T.f(8, .semibold))
            }
            .foregroundStyle(T.ink2)
            .padding(.horizontal, 10).frame(height: 26)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .controlGlass(13, opacity: 0.5)
        .disabled(!model.isConnected)
        .help("Model and profile settings")
        .accessibilityLabel("Model: \(state.model.isEmpty ? "Not selected" : state.model)")
        .accessibilityHint("Opens model and profile settings")
    }
    #endif

    private var composer: some View {
        VStack(spacing: composerSpacing) {
            if !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments, onRemove: model.removeAttachment)
                    .padding(.horizontal, 12).padding(.top, 12).disabled(model.isSubmitting)
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text(composerPlaceholder).font(transcriptFont)
                        #if os(macOS)
                        .foregroundStyle(T.ink4).padding(.horizontal, 4).padding(.top, 2)
                        #else
                        .foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.top, 15)
                        #endif
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                #if os(macOS)
                MacMessageEditor(text: $model.draft, isFocused: composerFocused,
                                 onFocusChange: { composerFocused = $0 })
                    .id(state.storedID)
                #else
                TextEditor(text: $model.draft).font(transcriptFont).scrollContentBackground(.hidden)
                    .frame(height: min(composerHeight, 140)).padding(8)
                    .focused($composerFocused)
                    .accessibilityLabel("Message Hermes")
                #endif
            }
            HStack(spacing: 4) {
                Button {
                    importScope = model.composerScope
                    showImporter = true
                } label: {
                    Image(systemName: "paperclip").font(utilityFont).foregroundStyle(utilityColor).frame(width: utilitySize, height: utilitySize).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.canAttach).accessibilityLabel("Attach files")
                .help("Upload files to this conversation’s workspace on the Hermes host")
                Menu {
                    Toggle("Follow replies", isOn: $followTail)
                } label: {
                    Image(systemName: "ellipsis").font(utilityFont).foregroundStyle(utilityColor).frame(width: utilitySize, height: utilitySize).contentShape(Rectangle())
                }
                .menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel("Conversation options")
                #if os(macOS)
                modelPicker
                #endif
                Spacer(minLength: 8)
                if state.isRunning && !model.canAnswerPendingText {
                    Button { Task { await model.stop() } } label: {
                        Label("Stop", systemImage: "stop.fill")
                            #if os(iOS)
                            .font(TalariaTypography.callout.weight(.semibold)).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            #else
                            .labelStyle(.titleAndIcon)
                            #endif
                    }
                    #if os(macOS)
                    .talariaProminentButton()
                    #else
                    .talariaSecondaryButton()
                    #endif
                    .disabled(!model.isConnected || state.status == "Stopping…")
                    .accessibilityLabel("Stop response")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { Task {
                        if model.canAnswerPendingText { _ = await model.answerPendingText(model.draft) }
                        else { await model.send() }
                    } } label: {
                        Label("Send", systemImage: "arrow.up")
                            #if os(iOS)
                            .font(TalariaTypography.callout.weight(.semibold)).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            #else
                            .labelStyle(.titleAndIcon)
                            #endif
                    }
                    .talariaProminentButton().disabled(!model.canSend && !(model.canAnswerPendingText && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityLabel("Send message")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            #if os(iOS)
            .padding(.horizontal, 10).padding(.bottom, 10)
            #endif
        }
        #if os(macOS)
        .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 10)
        .controlSize(.regular)
        #endif
        .talariaGlass(cornerRadius: 22)
    }

    private var composerPlaceholder: String {
        if model.canAnswerPendingText { return "Or answer in words…" }
        if let workspace = model.workspace(for: state.storedID) { return "Message in \(workspace.name)…" }
        return "Message \(model.endpoint?.name ?? "Hermes")…"
    }
}

#if os(iOS)
private struct MessageView: View {
    let message: ChatMessage
    var assistantName = "Hermes"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if message.role != .user { TalariaMark(size: 15) }
                Text((message.role == .user ? "You" : assistantName).uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(message.reasoning).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(TalariaTypography.callout).foregroundStyle(.secondary)
            }
            if !message.text.isEmpty || message.isStreaming {
                MarkdownMessage(text: message.text, isStreaming: message.isStreaming)
                    .font(.body).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(message.isError ? Color.red : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .contain)
    }
}

#endif

private struct ConnectionView: View {
    @Bindable var model: HermesAppModel
    let connectSSH: (@MainActor (GatewayEndpoint, String?, String?, String?, Bool) async -> GatewayAuthentication?)?
    let endSSH: (@MainActor (Bool) async -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Hermes"
    @State private var address = "http://127.0.0.1:8642"
    @State private var useSSH = false
    @State private var sshAddress = ""
    @State private var gatewayPort = "9119"
    @State private var gatewayPath = "/"
    @State private var identityFile = ""
    @State private var showSSHOptions = false
    @State private var useExistingGateway = false
    @State private var sshPrompt: GatewayAuthentication?
    @State private var profile = "default"
    @State private var authentication = GatewayAuthentication.basic
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var remember = true
    @State private var validation: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var sshStarting = false

    private var connectLabel: String {
        if sshStarting { return model.isConnecting ? "Signing in…" : "Connecting SSH…" }
        if useSSH { return sshPrompt == .basic ? "Sign in" : "Connect" }
        return model.isConnecting ? "Connecting gateway…" : authentication == .basic ? "Sign in" : "Connect"
    }

    private var authenticationPicker: some View {
        Picker("Authentication", selection: $authentication) {
            Text("Username & password").tag(GatewayAuthentication.basic)
            Text("Session token").tag(GatewayAuthentication.sessionToken)
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            macConnection
            #else
            NavigationStack {
                Form {
                    Section("Connection") {
                        TextField("Name", text: $name)
                        TextField("Gateway URL", text: $address)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("Profile", text: $profile)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }.disabled(model.isConnecting || sshStarting)
                    Section("Authentication") {
                        authenticationPicker
                        if authentication == .basic {
                            TextField("Username", text: $username).textContentType(.username)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            SecureField("Password", text: $password).textContentType(.password)
                        } else {
                            SecureField("Session token", text: $token)
                        }
                        Toggle("Remember sign-in", isOn: $remember)
                    }.disabled(model.isConnecting || sshStarting)
                    if let text = validation ?? model.banner {
                        Section { Text(text).font(TalariaTypography.callout).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    if model.endpoint != nil && !model.isConnecting && !sshStarting {
                        Section {
                            if model.isConnected {
                                Button("Disconnect", role: .destructive) {
                                    Task { await endConnection(signOut: false); dismiss() }
                                }
                            }
                            if model.endpoint?.authentication == .basic {
                                Button("Sign out", role: .destructive) {
                                    Task { await endConnection(signOut: true); dismiss() }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle("Connect to Hermes")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(connectLabel, action: connect)
                            .disabled(model.isConnecting || sshStarting).keyboardShortcut(.defaultAction)
                    }
                }
            }
            #endif
        }
        .tint(TalariaStyle.accent)
        .frame(idealWidth: 480, idealHeight: 560)
        .interactiveDismissDisabled(model.isConnecting || sshStarting)
        .onAppear {
            if let endpoint = model.endpoint ?? model.savedEndpoint {
                name = endpoint.name; address = endpoint.baseURL.absoluteString; profile = endpoint.profile
                authentication = endpoint.authentication
                remember = model.remembersSignIn
                if let ssh = endpoint.ssh {
                    useSSH = true
                    sshAddress = (ssh.user.map { "\($0)@" } ?? "") + ssh.host
                        + (ssh.sshPort == 22 ? "" : ":\(ssh.sshPort)")
                    gatewayPort = String(ssh.gatewayPort)
                    gatewayPath = ssh.gatewayPath.isEmpty ? "/" : ssh.gatewayPath
                    identityFile = ssh.identityFile ?? ""
                    useExistingGateway = ssh.attachesExistingGateway
                    showSSHOptions = useExistingGateway || ssh.identityFile != nil
                }
            }
        }
        .onChange(of: useSSH) { _, _ in
            sshPrompt = nil; password = ""; token = ""; validation = nil
        }
        .onChange(of: authentication) { _, _ in password = ""; token = ""; validation = nil }
        .onDisappear {
            password = ""; token = ""
            // Successful dismissal happens before session/history hydration finishes.
            if !model.isConnected && (model.isConnecting || sshStarting) { connectionTask?.cancel() }
        }
    }

    #if os(macOS)
    private var macConnection: some View {
        SettingsSheet("Connect to Hermes", content: {
            SettingsSection("Connection") {
                SettingsRow("Name") { ValueField(text: $name, mono: false).accessibilityLabel("Name") }
                SettingsRow("Transport") {
                    Picker("Transport", selection: $useSSH) {
                        Text("Direct").tag(false)
                        Text("SSH").tag(true)
                    }.labelsHidden()
                }
                if useSSH {
                    SettingsRow("SSH host") { ValueField(text: $sshAddress).accessibilityLabel("SSH host") }
                    DisclosureGroup("Advanced", isExpanded: $showSSHOptions) {
                        SettingsRow("Use running gateway") {
                            Toggle("Use running gateway", isOn: $useExistingGateway).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        if useExistingGateway {
                            SettingsRow("Gateway port") { ValueField(text: $gatewayPort).accessibilityLabel("Gateway port") }
                            SettingsRow("Gateway path") { ValueField(text: $gatewayPath).accessibilityLabel("Gateway path") }
                        }
                        SettingsRow("Identity file") { ValueField(text: $identityFile).accessibilityLabel("Identity file") }
                    }
                } else {
                    SettingsRow("Gateway URL") { ValueField(text: $address).accessibilityLabel("Gateway URL") }
                }
                SettingsRow("Profile") { ValueField(text: $profile).accessibilityLabel("Profile") }
            }.disabled(model.isConnecting || sshStarting)
            SettingsSection("Authentication") {
                if !useSSH { SettingsRow("Method") { authenticationPicker } }
                if (useSSH ? sshPrompt : authentication) == .basic {
                    SettingsRow("Username") { ValueField(text: $username, mono: false).textContentType(.username).accessibilityLabel("Username") }
                    SettingsRow("Password") { secretField("Password", text: $password).textContentType(.password) }
                } else if !useSSH || sshPrompt == .sessionToken {
                    SettingsRow("Session token") { secretField("Token", text: $token) }
                }
                SettingsRow("Remember sign-in") {
                    Toggle("Remember sign-in", isOn: $remember).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }.disabled(model.isConnecting || sshStarting)
            if let text = validation ?? model.banner {
                Text(text).font(T.f(11.5)).foregroundStyle(T.failed).textSelection(.enabled)
            }
        }, footer: {
            if !model.isConnecting && !sshStarting {
                if model.isConnected {
                    Button("Disconnect", role: .destructive) { Task { await endConnection(signOut: false); dismiss() } }
                        .buttonStyle(.plain).foregroundStyle(T.failed)
                }
                if model.endpoint?.authentication == .basic {
                    Button("Sign out", role: .destructive) { Task { await endConnection(signOut: true); dismiss() } }
                        .buttonStyle(.plain).foregroundStyle(T.failed)
                }
            }
            Spacer()
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button(connectLabel, action: connect)
                .disabled(model.isConnecting || sshStarting)
                .buttonStyle(.borderedProminent).tint(T.fill).keyboardShortcut(.defaultAction)
        }).frame(height: 470)
    }

    private func secretField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text).textFieldStyle(.plain).font(T.f(12.5))
            .padding(.horizontal, 9).frame(height: 26).background(T.field, in: RoundedRectangle(cornerRadius: 6))
    }
    #endif

    private func cancel() {
        connectionTask?.cancel()
        password = ""; token = ""
        if model.isConnecting || sshStarting { Task { await endConnection(signOut: false); dismiss() } }
        else { dismiss() }
    }

    private func endConnection(signOut: Bool) async {
        if model.endpoint?.ssh != nil || useSSH && sshStarting, let endSSH { await endSSH(signOut) }
        else if signOut { await model.signOut() }
        else { await model.disconnect() }
    }

    private func connect() {
        validation = nil
        var ssh: GatewaySSHDestination?
        let url: URL
        if useSSH {
            guard connectSSH != nil else { validation = "SSH is unavailable in this app."; return }
            guard var parsed = GatewaySSHDestination.parse(sshAddress),
                  !useExistingGateway || (Int(gatewayPort).map { (1...65535).contains($0) } == true && gatewayPath.hasPrefix("/")) else {
                validation = "Check the SSH host, gateway port and path."; return
            }
            let remotePort = useExistingGateway ? Int(gatewayPort)! : 9119
            parsed.gatewayPort = remotePort
            parsed.gatewayPath = useExistingGateway ? gatewayPath : "/"
            parsed.identityFile = identityFile.isEmpty ? nil : identityFile
            parsed.useExistingGateway = useExistingGateway
            ssh = parsed
            guard let configuredURL = URL(string: "http://127.0.0.1:\(remotePort)\(parsed.gatewayPath)") else {
                validation = "Check the gateway path."; return
            }
            url = configuredURL
        } else {
            guard let directURL = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), directURL.host != nil else {
                validation = "Enter a full gateway URL, including http:// or https://."; return
            }
            url = directURL
        }
        guard (useSSH ? sshPrompt : authentication) != .basic || password.isEmpty || !username.isEmpty else {
            validation = "Enter a username."; return
        }
        let previous = model.endpoint ?? model.savedEndpoint
        var priorSSH = previous?.ssh
        if var old = priorSSH {
            if old.gatewayPath.isEmpty { old.gatewayPath = "/" }
            if old.useExistingGateway == nil { old.useExistingGateway = old.attachesExistingGateway }
            priorSSH = old
        }
        let same = ssh == nil ? previous?.baseURL == url && previous?.ssh == nil : priorSSH == ssh
        let endpoint = GatewayEndpoint(id: same ? previous!.id : UUID(), name: name.isEmpty ? "Hermes" : name,
            baseURL: url, profile: profile.isEmpty ? "default" : profile,
            authentication: useSSH ? .sessionToken : authentication, ssh: ssh)
        let submittedPassword = password; let submittedToken = token
        password = ""; token = ""
        sshStarting = ssh != nil
        connectionTask = Task {
            if ssh != nil, let connectSSH {
                sshPrompt = await connectSSH(endpoint, sshPrompt == .basic ? username : nil,
                    sshPrompt == .basic ? submittedPassword : nil,
                    sshPrompt == .sessionToken ? submittedToken : nil, remember)
                sshStarting = false
            } else {
                if model.endpoint?.ssh != nil, let endSSH { await endSSH(false) }
                guard !Task.isCancelled else { return }
                if authentication == .basic {
                    await model.connect(to: endpoint, username: username, password: submittedPassword, remember: remember)
                } else {
                    await model.connect(to: endpoint, token: submittedToken, remember: remember)
                }
            }
        }
    }
}
