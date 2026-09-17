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
        .onChange(of: selection) { _, id in
            if let id, id != model.selectedID { Task { await model.openSession(id) } }
        }
        .onChange(of: model.selectedID) { _, id in
            selection = id
            if id != nil { preferredColumn = .detail }
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
                                            .font(.body.weight(.medium)).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if model.conversations[session.id]?.isRunning == true {
                                            Image(systemName: "circle.fill")
                                                .font(.caption2).foregroundStyle(TalariaStyle.accent)
                                                .accessibilityLabel("Reply in progress")
                                        }
                                        if model.conversations[session.id]?.pendingInputs.isEmpty == false {
                                            Image(systemName: "hand.raised")
                                                .foregroundStyle(TalariaStyle.accent)
                                                .accessibilityLabel("Needs your answer")
                                        }
                                    }
                                    if !session.preview.isEmpty {
                                        Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                        Text(model.endpoint?.profile ?? "default").font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
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
                        Text(model.endpoint?.name ?? "Connect to Hermes").font(.callout.weight(.medium)).lineLimit(1)
                        Text(model.isConnecting ? "Connecting…" : model.isConnected ? "Connected" : "Disconnected")
                            .font(.caption).foregroundStyle(.secondary)
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
                Text(message).font(.callout).textSelection(.enabled).padding(.vertical, 10)
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
        ScrollView {
            VStack(spacing: 24) {
                TalariaMark(size: 76).accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(model.isConnected ? "Ready when you are." : "Hermes, made native.")
                        .font(.largeTitle.weight(.medium)).multilineTextAlignment(.center)
                    Text(model.isConnected ? "Start a conversation, bring a file, and work through your next idea." : "Your Hermes agent, at home on your Mac and iPhone.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                connectionActions.frame(maxWidth: 320)
            }
            .frame(maxWidth: 520).padding(32).padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionActions: some View {
        VStack(spacing: 12) {
            if model.isConnected {
                Button { Task { await model.newConversation() } } label: {
                    Label("New conversation", systemImage: "square.and.pencil").frame(minHeight: 44)
                }
                .talariaProminentButton().disabled(model.isLoadingSession)
            } else {
                if let startLocal {
                    Button {
                        startingLocal = true
                        Task { await startLocal(); startingLocal = false }
                    } label: {
                        Text(startingLocal ? "Starting Hermes…" : "Start local Hermes").frame(minHeight: 44)
                    }
                    .talariaProminentButton().disabled(startingLocal || model.isConnecting)
                }
                Button { model.showConnection = true } label: {
                    Text(model.isConnecting ? "Connecting…" : "Connect to a gateway").frame(minHeight: 44)
                }.talariaSecondaryButton().disabled(model.isConnecting)
                Text(startLocal == nil ? "Use Hermes running on your Mac or server." : "Uses your existing Hermes installation and selected model.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
    @FocusState private var composerFocused: Bool
    @ScaledMetric(relativeTo: .body) private var composerHeight: CGFloat = 76

    private var contentInset: CGFloat {
        #if os(macOS)
        24
        #else
        16
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(state.status, systemImage: state.isRunning ? "sparkles" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button { model.showSessionSettings = true } label: {
                    HStack(spacing: 6) {
                        Text(state.model.isEmpty ? "Choose model" : state.model).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.callout).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.isConnected).help("Model and profile settings")
                .accessibilityLabel("Model: \(state.model.isEmpty ? "Not selected" : state.model)")
                .accessibilityHint("Opens model and profile settings")
            }
            .padding(.horizontal, contentInset).padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if state.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("What are we working on?").font(.title2.weight(.medium))
                                Text("Ask a question, share a file, or start with an idea.")
                                    .font(.body).foregroundStyle(.secondary)
                            }.padding(.vertical, 40)
                        }
                        ForEach(state.messages) { message in MessageView(message: message) }
                        ForEach(state.pendingInputs) { input in
                            InputRequestView(input: input) { result in
                                await model.answer(input, result: result)
                            }.id(input.id)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .frame(maxWidth: 760).padding(.horizontal, contentInset).padding(.vertical, 24)
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
                .frame(maxWidth: 808).padding(.horizontal, contentInset).padding(.top, 8).padding(.bottom, 12)
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

    private var composer: some View {
        VStack(spacing: 4) {
            if !model.attachments.isEmpty {
                AttachmentStrip(items: model.attachments, onRemove: model.removeAttachment)
                    .padding(.horizontal, 12).padding(.top, 12).disabled(model.isSubmitting)
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Message Hermes…").font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.top, 15)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                TextEditor(text: $model.draft).font(.body).scrollContentBackground(.hidden)
                    .frame(height: min(composerHeight, 140)).padding(8).focused($composerFocused)
                    .accessibilityLabel("Message Hermes")
            }
            HStack(spacing: 4) {
                Button {
                    importScope = model.composerScope
                    showImporter = true
                } label: {
                    Image(systemName: "paperclip").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!model.canAttach).accessibilityLabel("Attach files")
                .help("Upload files to this conversation’s workspace on the Hermes host")
                Menu {
                    Toggle("Follow replies", isOn: $followTail)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel("Conversation options")
                Spacer(minLength: 8)
                if state.isRunning {
                    Button { Task { await model.stop() } } label: {
                        Label("Stop", systemImage: "stop.fill").font(.callout.weight(.semibold))
                            #if os(iOS)
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            #else
                            .frame(minWidth: 52, minHeight: 44)
                            #endif
                    }
                    .talariaSecondaryButton().disabled(!model.isConnected || state.status == "Stopping…")
                    .accessibilityLabel("Stop response")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { Task { await model.send() } } label: {
                        Label("Send", systemImage: "arrow.up").font(.callout.weight(.semibold))
                            #if os(iOS)
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            #else
                            .frame(minWidth: 52, minHeight: 44)
                            #endif
                    }
                    .talariaProminentButton().disabled(!model.canSend)
                    .accessibilityLabel("Send message")
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .talariaGlass(cornerRadius: 26)
    }
}

private struct MessageView: View {
    let message: ChatMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: message.role == .user ? "person.crop.circle" : message.role == .tool ? "wrench.and.screwdriver" : "sparkle")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                Text(message.role == .user ? "You" : message.role == .tool ? message.toolName ?? "Tool" : "Hermes")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if message.isStreaming { ProgressView().controlSize(.mini).accessibilityLabel("Reply in progress") }
                Spacer()
            }
            if !message.reasoning.isEmpty {
                DisclosureGroup("Reasoning") {
                    Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if message.role == .tool {
                DisclosureGroup(message.isStreaming ? "Working…" : message.toolSummary ?? "View tool result") {
                    if let input = message.toolInput { Text(input).padding(.bottom, 8) }
                    Text(message.text)
                }
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
            } else if !message.text.isEmpty {
                MarkdownMessage(text: message.text).font(.body).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(message.isError ? Color.red : .primary)
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
                    Section { Text(text).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
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
