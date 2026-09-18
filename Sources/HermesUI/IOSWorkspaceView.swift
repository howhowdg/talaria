#if os(iOS)
import SwiftUI
import HermesCore

/// The iPhone's scrolling content sits beneath floating native glass controls.
struct IOSWorkspaceView: View {
    @Bindable var model: HermesAppModel
    @State private var tab: IOSTab = .chat
    @State private var keyboardVisible = false
    @State private var navigationOperation = UUID()
    @ScaledMetric(relativeTo: .caption) private var headerTextAllowance: CGFloat = 50
    @Environment(\.scenePhase) private var scenePhase

    init(model: HermesAppModel) {
        self.model = model
        #if DEBUG
        if ProcessInfo.processInfo.environment["TALARIA_DESIGN_PREVIEW"] == "1",
           let name = ProcessInfo.processInfo.environment["TALARIA_DESIGN_TAB"],
           let initial = IOSTab(rawValue: name) {
            _tab = State(initialValue: initial)
        }
        #endif
    }

    private var headerInset: CGFloat { 68 + headerTextAllowance }
    private var owner: String {
        guard let endpoint = model.endpoint, model.isConnected else { return "disconnected" }
        return "\(endpoint.id.uuidString):\(endpoint.profile)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                IOSBackdrop()
                content.frame(width: geometry.size.width, height: geometry.size.height)
                headerFade.allowsHitTesting(false)
                header
                if !keyboardVisible {
                    VStack {
                        Spacer()
                        tabBar.padding(.horizontal, 16).padding(.bottom, 10)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: tab) { _, _ in navigationOperation = UUID() }
        .task(id: owner) {
            navigationOperation = UUID()
            if model.isConnected { await model.refreshMobileActivity() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isConnected { Task { await model.refreshMobileActivity() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .accessibilityIdentifier("talaria.iphone.workspace")
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .chat:
            if let state = model.conversation {
                IOSChatView(model: model, state: state, topInset: headerInset,
                            keyboardVisible: keyboardVisible)
            } else {
                welcome
            }
        case .sessions:
            IOSSessionsView(model: model, onOpen: open, onNew: newConversation,
                            topInset: 66, bottomInset: keyboardVisible ? 12 : 90)
        case .updates:
            IOSUpdatesView(model: model, onOpen: open, topInset: headerInset, bottomInset: keyboardVisible ? 12 : 90)
        case .skills:
            IOSSkillsView(model: model, topInset: headerInset, bottomInset: keyboardVisible ? 12 : 90)
        case .files:
            WorkspaceInspector(state: model.conversation, attachments: model.attachments)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.top, headerInset).padding(.bottom, 90)
        }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            if tab == .sessions {
                HStack {
                    HStack(spacing: -3) {
                        TalariaMark(size: 28)
                        Text("Talaria").font(.system(.body, design: .serif).weight(.semibold)).padding(.top, 3)
                    }
                    .padding(.horizontal, 18).frame(minHeight: 48)
                    .talariaGlass(cornerRadius: 24)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Talaria")
                    Spacer()
                    roundButton("New conversation", symbol: "pencil", disabled: !model.isConnected || model.isLoadingSession,
                                action: newConversation)
                }
            } else {
                HStack {
                    roundButton("Show sessions", symbol: "line.3.horizontal") { tab = .sessions }
                    Spacer()
                    roundButton(tab == .chat ? "Show conversation files" : "Model and profile settings",
                                symbol: tab == .chat ? "rectangle.on.rectangle" : "slider.horizontal.3") {
                        if tab == .chat { tab = .files }
                        else if model.isConnected { model.showSessionSettings = true }
                        else { model.showConnection = true }
                    }
                }
                VStack(spacing: -6) {
                    TalariaMark(size: 56)
                    VStack(spacing: 2) {
                        Text("Talaria").font(.system(.body, design: .serif).weight(.semibold))
                        HStack(spacing: 5) {
                            if model.isConnected { IOSActivityDot(active: model.conversation?.isRunning == true) }
                            Text(headerStatus).iosFont(12.5, relativeTo: .caption)
                                .foregroundStyle(needsInput ? TalariaStyle.accent : .secondary)
                                .lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .talariaGlass(cornerRadius: 16)
                }
                .frame(maxWidth: 210)
                .offset(y: -4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
    }

    private var needsInput: Bool { !(model.conversation?.pendingInputs.isEmpty ?? true) }
    private var headerStatus: String {
        if model.isConnecting { return "Connecting…" }
        if !model.isConnected { return "Your Hermes, anywhere" }
        switch tab {
        case .updates:
            let count = model.mobileActivity.schedules.count
            return "\(count) \(count == 1 ? "schedule" : "schedules") · \(model.unreadMobileRunCount) new"
        case .skills: return "\(model.mobileActivity.skills.count) installed"
        case .files: return "Conversation workspace"
        default:
            if needsInput { return "Needs your OK" }
            return model.conversation?.isRunning == true ? "Working" : "Ready when you are"
        }
    }

    private var headerFade: some View {
        Rectangle().fill(.ultraThinMaterial)
            .overlay(IOSDesign.background.opacity(0.55))
            .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.35),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .frame(height: (tab == .sessions ? 70 : headerInset) + 65)
            .padding(.top, -65)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(IOSTab.allCases) { destination in
                Button {
                    tab = destination
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: destination.symbol).font(.system(size: 20, weight: .regular))
                            .frame(maxWidth: .infinity).frame(height: 48)
                        if destination == .updates, model.unreadMobileRunCount > 0 || !model.mobilePendingInputs.isEmpty {
                            Circle().fill(TalariaStyle.prominentAccent).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .offset(x: -15, y: 10)
                        }
                    }
                    .foregroundStyle(tab == destination ? TalariaStyle.accent : Color.primary)
                    .background(tab == destination ? TalariaStyle.accentTint : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.rawValue)
                .accessibilityAddTraits(tab == destination ? .isSelected : [])
            }
        }
        .padding(6).frame(height: 60)
        .talariaGlass(cornerRadius: 30, interactive: true)
        .background {
            LinearGradient(colors: [.clear, IOSDesign.background.opacity(0.96)], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -16).padding(.top, -30).padding(.bottom, -44)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func roundButton(_ title: String, symbol: String, disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                .frame(width: 48, height: 48).contentShape(Circle())
        }
        .buttonStyle(.plain).talariaGlass(cornerRadius: 24, interactive: true)
        .accessibilityLabel(title).disabled(disabled)
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let banner = model.banner {
                    Text(banner).iosFont(14).foregroundStyle(.secondary)
                }
                Text(model.isConnected ? "What are we working on?" : "Hermes, wherever you are.")
                    .iosFont(28, .bold, relativeTo: .title).tracking(-0.4)
                Text(model.isConnected ? "Start a conversation, share a file, or pick up where you left off."
                     : "Connect to your Hermes agent to chat, follow its work, and give it the go-ahead.")
                    .iosFont(16).foregroundStyle(.secondary).lineSpacing(4)
                Button(model.isConnected ? "New conversation" : "Connect to Hermes") {
                    if model.isConnected { newConversation() } else { model.showConnection = true }
                }
                .talariaProminentButton().disabled(model.isLoadingSession || model.isConnecting)
                if model.isConnected {
                    Button("Browse conversations") { tab = .sessions }.talariaSecondaryButton()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, headerInset + 36).padding(.bottom, 100)
        }
    }

    private func open(_ id: StoredSessionID) {
        guard model.isConnected, !model.isLoadingSession, let endpoint = model.endpoint else { return }
        let expectedOwner = SessionOwner(connectionID: endpoint.id, profile: endpoint.profile)
        let previousID = model.selectedID
        let stamp = UUID(); navigationOperation = stamp
        Task {
            await model.openSession(id)
            guard navigationOperation == stamp, let state = model.conversation,
                  state.owner == expectedOwner, !state.requiresHydration,
                  state.storedID == id || state.storedID != previousID else { return }
            tab = .chat
        }
    }
    private func newConversation() {
        guard model.isConnected, !model.isLoadingSession, let endpoint = model.endpoint else { return }
        let expectedOwner = SessionOwner(connectionID: endpoint.id, profile: endpoint.profile)
        let previousRuntime = model.conversation?.runtimeID
        let stamp = UUID(); navigationOperation = stamp
        Task {
            await model.newConversation()
            guard navigationOperation == stamp, let state = model.conversation,
                  state.owner == expectedOwner, state.runtimeID != previousRuntime else { return }
            tab = .chat
        }
    }
}

private enum IOSTab: String, CaseIterable, Identifiable {
    case chat = "Chat", sessions = "Sessions", updates = "Updates", skills = "Skills", files = "Files"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .sessions: "line.3.horizontal"
        case .updates: "clock"
        case .skills: "sparkles"
        case .files: "folder"
        }
    }
}
#endif
