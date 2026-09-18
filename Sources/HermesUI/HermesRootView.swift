import SwiftUI
import HermesCore
import HermesProtocol
import HermesTransport
import UniformTypeIdentifiers

public struct HermesRootView: View {
    @Bindable private var model: HermesAppModel
    private let startLocal: (@MainActor () async -> Void)?
    @State private var startingLocal = false
    @State private var selection: StoredSessionID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(model: HermesAppModel, startLocal: (@MainActor () async -> Void)? = nil) {
        self.model = model; self.startLocal = startLocal
    }

    public var body: some View {
        Group {
            #if os(macOS)
            MacWorkspaceView(model: model) {
                VStack(spacing: 0) {
                    if let banner = model.banner { connectionBanner(banner) }
                    if let conversation = model.conversation {
                        ConversationView(model: model, state: conversation)
                    } else {
                        welcome
                    }
                }
            }
            .talariaWindowBackground()
            .preferredColorScheme(.light)
            #else
            mobileNavigation
            #endif
        }
        .tint(TalariaStyle.accent)
        .sheet(isPresented: $model.showConnection) { ConnectionView(model: model) }
        .sheet(isPresented: $model.showSessionSettings) {
            SessionSettingsView(state: SessionSettingsViewState(snapshot: model.settingsSnapshot,
                profile: model.endpoint?.profile ?? "default", sessionID: model.conversation?.runtimeID.rawValue,
                isLoading: model.isLoadingSettings, isApplying: model.isApplyingSettings || model.isSubmitting,
                errorMessage: model.settingsError),
                onRefresh: { await model.loadSettings(refresh: true) },
                onSelectModel: { selection, confirmed in await model.selectModel(selection, confirmed: confirmed) },
                onSelectProfile: { await model.selectProfile($0) })
                .task { await model.loadSettings() }
        }
        #if os(iOS)
        .onChange(of: selection) { _, id in
            if let id, id != model.selectedID { Task { await model.openSession(id) } }
        }
        .onChange(of: model.selectedID) { _, id in
            selection = id
            if id != nil { preferredColumn = .detail }
        }
        #endif
    }

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
                Button("Reconnect") { Task { await model.reconnect() } }
                    .frame(minHeight: 44).talariaSecondaryButton().disabled(model.isConnecting)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(.quaternary.opacity(0.35))
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
                .buttonStyle(.plain).disabled(!model.isConnected).help("Model and profile settings")
                .accessibilityLabel("Model: \(state.model.isEmpty ? "Not selected" : state.model)")
                .accessibilityHint("Opens model and profile settings")
            }
            .padding(.horizontal, contentInset).padding(.vertical, 4)
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if state.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("What are we working on?").font(TalariaTypography.title2.weight(.medium))
                                Text("Ask a question, share a file, or start with an idea.")
                                    .font(TalariaTypography.body).foregroundStyle(.secondary)
                            }.padding(.vertical, 40)
                        }
                        ForEach(transcriptGroups) { group in
                            if group.isToolGroup {
                                ToolActivityCard(messages: group.messages)
                            } else if let message = group.messages.first {
                                MessageView(message: message)
                            }
                        }
                        ForEach(state.pendingInputs) { input in
                            InputRequestView(input: input) { result in
                                await model.answer(input, result: result)
                            }.id(input.id)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .frame(maxWidth: 760).padding(.horizontal, contentInset).padding(.top, 26).padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: state.messages.last) { _, _ in if followTail { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: state.pendingInputs.count) { _, _ in if followTail { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: state.storedID) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                .onAppear { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                #if os(macOS)
                .frame(maxWidth: T.composerMaxW).padding(.horizontal, T.chatInset).padding(.top, 14).padding(.bottom, 18)
                #else
                .frame(maxWidth: 760).padding(.horizontal, contentInset).padding(.top, 8).padding(.bottom, 12)
                #endif
                .frame(maxWidth: .infinity)
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
    }

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
            .foregroundStyle(Color.black.opacity(0.65))
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
                    Text("Message Hermes…").font(transcriptFont)
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
                if state.isRunning {
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
                    Button { Task { await model.send() } } label: {
                        Label("Send", systemImage: "arrow.up")
                            #if os(iOS)
                            .font(TalariaTypography.callout.weight(.semibold)).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            #else
                            .labelStyle(.titleAndIcon)
                            #endif
                    }
                    .talariaProminentButton().disabled(!model.canSend)
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
        .talariaGlass(cornerRadius: 26)
    }
}

private struct MessageView: View {
    let message: ChatMessage

    private var messageFont: Font {
        #if os(macOS)
        T.body
        #else
        .body
        #endif
    }

    private var roleFont: Font {
        #if os(macOS)
        T.section
        #else
        .caption.weight(.semibold)
        #endif
    }

    private var secondaryInk: Color {
        #if os(macOS)
        T.ink2
        #else
        .secondary
        #endif
    }

    private var bodyInk: Color {
        #if os(macOS)
        T.ink
        #else
        .primary
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if message.role != .user { TalariaMark(size: 16) }
                Text(message.role == .user ? "You" : "Hermes")
                    .font(roleFont).foregroundStyle(secondaryInk)
                Spacer()
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(message.reasoning).font(messageFont).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                #if os(macOS)
                .font(T.f(11))
                #else
                .font(TalariaTypography.callout)
                #endif
                .foregroundStyle(secondaryInk)
            }
            if !message.text.isEmpty || message.isStreaming {
                MarkdownMessage(text: message.text, isStreaming: message.isStreaming).font(messageFont).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(message.isError ? Color.red : bodyInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct ConnectionView: View {
    @Bindable var model: HermesAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Hermes"
    @State private var address = "http://127.0.0.1:8642"
    @State private var profile = "default"
    @State private var token = ""
    @State private var remember = true
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Gateway URL", text: $address).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    TextField("Profile", text: $profile).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Connect to a token-authenticated Hermes gateway. Remote connections require HTTPS.")
                }
                Section {
                    SecureField("Session token", text: $token)
                    Toggle("Remember connection in Keychain", isOn: $remember)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("An empty token field reuses this connection’s current or saved token. OAuth gateways are not supported in this preview.")
                }
                if let text = validation ?? model.banner {
                    Section { Text(text).font(TalariaTypography.callout).foregroundStyle(.red).textSelection(.enabled) }
                }
                if model.isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            Task { await model.disconnect(); dismiss() }
                        }.frame(minHeight: 44)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isConnecting)
            .navigationTitle("Connect to Hermes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isConnecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(model.isConnecting).keyboardShortcut(.defaultAction)
                }
            }
        }
        .tint(TalariaStyle.accent)
        .frame(idealWidth: 480, idealHeight: 560)
        .onAppear {
            if let endpoint = model.endpoint ?? model.savedEndpoint {
                name = endpoint.name; address = endpoint.baseURL.absoluteString; profile = endpoint.profile
            }
        }
        .onDisappear { token = "" }
    }

    private func connect() {
        validation = nil
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else {
            validation = "Enter a full gateway URL, including http:// or https://."; return
        }
        let previous = model.endpoint ?? model.savedEndpoint
        let same = previous?.baseURL == url
        let endpoint = GatewayEndpoint(id: same ? previous!.id : UUID(), name: name.isEmpty ? "Hermes" : name,
            baseURL: url, profile: profile.isEmpty ? "default" : profile)
        Task { await model.connect(to: endpoint, token: token, remember: remember); token = "" }
    }
}
