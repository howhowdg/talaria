#if os(iOS)
import SwiftUI
import HermesCore

/// Four durable navigation stacks share a profile, while each conversation keeps
/// its own draft and reading position. Classification is always explicit.
struct IOSWorkspaceView: View {
    @Bindable var model: HermesAppModel
    @State private var tab: IOSTab = .home
    @State private var paths: [IOSTab: [IOSHierarchyRoute]] = [:]
    @State private var keyboardVisible = false
    @State private var navigationOwner: SessionOwner?
    @State private var detailHeaderHeight: CGFloat = 108
    @State private var showsSkills = false
    @State private var showsWorkspaceEditor = false
    @State private var workspaceOrigin: StoredSessionID?
    @State private var showsHomePicker = false
    @ScaledMetric(relativeTo: .caption) private var headerTextAllowance: CGFloat = 50
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
    private var detailInset: CGFloat { max(70 + headerTextAllowance, detailHeaderHeight + 12) }
    private var bottomInset: CGFloat { keyboardVisible ? 12 : 90 }
    private var activeRoute: IOSHierarchyRoute { paths[tab]?.last ?? .destination(tab.root) }
    private var profileName: String { model.endpoint?.name ?? model.savedEndpoint?.name ?? "Hermes" }
    private var owner: SessionOwner? { model.currentHierarchyOwner }
    private var connectionScope: String { "\(owner?.connectionID.uuidString ?? "none"):\(owner?.profile ?? ""):\(model.isConnected)" }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                IOSBackdrop()
                TabView(selection: $tab) {
                    ForEach(IOSTab.allCases) { destination in
                        NavigationStack(path: path(for: destination)) {
                            routeContent(.destination(destination.root))
                                .navigationDestination(for: IOSHierarchyRoute.self) { route in
                                    routeContent(route)
                                }
                        }
                        .toolbar(.hidden, for: .navigationBar)
                        .toolbar(.hidden, for: .tabBar)
                        .tag(destination)
                    }
                }
                .background(.clear)
                .frame(width: geometry.size.width, height: geometry.size.height)
                headerFade.allowsHitTesting(false)
                header
                if !keyboardVisible {
                    VStack {
                        Spacer()
                        tabBar.frame(maxWidth: 520).padding(.horizontal, 16).padding(.bottom, 10)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: tab) { _, destination in activate(paths[destination]?.last ?? .destination(destination.root)) }
        .onChange(of: model.hierarchyDestination) { _, destination in show(destination) }
        .task(id: connectionScope) {
            if navigationOwner != owner { paths = [:]; navigationOwner = owner }
            guard model.isConnected else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["TALARIA_DESIGN_PREVIEW"] == "1" { return }
            #endif
            await model.refreshMobileActivity()
            if case .destination(let destination) = activeRoute { await model.navigate(to: destination) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.isConnected { Task { await model.refreshMobileActivity() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .sheet(isPresented: $showsSkills) {
            NavigationStack {
                ZStack {
                    IOSBackdrop()
                    IOSSkillsView(model: model, topInset: 20, bottomInset: 24)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSkills = false } } }
            }
        }
        .sheet(isPresented: $showsWorkspaceEditor) {
            HierarchyWorkspaceEditor(model: model, startedFromHome: workspaceOrigin, onNavigate: navigate)
        }
        .sheet(isPresented: $showsHomePicker) {
            HierarchyHomeChooserSheet(model: model, onNavigate: { destination in
                showsHomePicker = false
                navigate(destination)
            })
        }
        .accessibilityIdentifier("talaria.iphone.workspace")
    }

    private func routeContent(_ route: IOSHierarchyRoute) -> some View {
        routeBody(route).frame(maxWidth: 840).frame(maxWidth: .infinity).background { IOSBackdrop() }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder private func routeBody(_ route: IOSHierarchyRoute) -> some View {
        switch route {
        case .files(let sessionID):
            WorkspaceInspector(state: model.conversations[sessionID],
                               attachments: model.selectedID == sessionID ? model.attachments : [])
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.top, 66).padding(.bottom, bottomInset)
        case .destination(let destination):
            switch destination {
            case .home:
                if model.endpoint == nil, !model.isConnected {
                    connectionWelcome
                } else if model.homeAvailability == .unavailable {
                    IOSUnavailableHomeView(model: model, topInset: headerInset,
                                           bottomInset: keyboardVisible ? 12 : 84, onNavigate: navigate)
                } else if let home = model.homeSessionID, let state = model.conversations[home],
                   model.homeAvailability == .available || model.homeAvailability == .unavailable {
                    IOSChatView(model: model, state: state, topInset: headerInset,
                                keyboardVisible: keyboardVisible,
                                composerPlaceholder: model.homeAvailability == .unavailable
                                    ? "Reconnect Home to continue" : "Message \(profileName)…",
                                isComposerDisabled: model.homeAvailability == .unavailable,
                                transcriptOpacity: model.homeAvailability == .unavailable ? 0.7 : 1,
                                contextHeader: AnyView(homeContext),
                                contextFooter: AnyView(HierarchyHomeReferences(model: model, onNavigate: navigate)), onBackToActivity: { navigate(.activity) })
                } else {
                    HierarchyContentView(model: model, destination: .home,
                                         topInset: headerInset + 24, bottomInset: bottomInset, onNavigate: navigate)
                }
            case .workspace(let id):
                if let workspace = model.workspace(id: id), let state = workspaceConversation(workspace) {
                    IOSChatView(model: model, state: state, topInset: 0,
                                keyboardVisible: keyboardVisible, composerPlaceholder: "Message in \(workspace.name)…",
                                contextHeader: AnyView(workspaceContext(workspace, state: state)), onBackToActivity: { navigate(.activity) })
                        .padding(.top, detailInset)
                } else {
                    HierarchyContentView(model: model, destination: destination,
                                         topInset: 66, bottomInset: bottomInset, onNavigate: navigate)
                }
            case .conversation(let id):
                if let state = model.conversations[id] {
                    IOSChatView(model: model, state: state, topInset: 0,
                                keyboardVisible: keyboardVisible, composerPlaceholder: "Message \(profileName)…",
                                contextHeader: AnyView(conversationContext(state)), onBackToActivity: { navigate(.activity) })
                        .padding(.top, detailInset)
                } else { loadingConversation }
            default:
                HierarchyContentView(model: model, destination: destination,
                                     topInset: 66, bottomInset: bottomInset, onNavigate: navigate)
            }
        }
    }

    private var connectionWelcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your Home with Hermes").iosFont(22, .bold, relativeTo: .title2)
                Text("Connect to your Hermes agent, then choose the conversation you always come back to.")
                    .iosFont(15).foregroundStyle(.secondary).lineSpacing(4)
                Button(model.isConnecting ? "Connecting…" : "Connect to Hermes") { model.showConnection = true }
                    .talariaProminentButton().disabled(model.isConnecting)
                if let banner = model.banner { Text(banner).iosFont(14).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 24).padding(.top, headerInset + 30).padding(.bottom, bottomInset)
        }
    }

    @ViewBuilder private var homeContext: some View {
        if model.homeAvailability == .unavailable {
            HierarchyHomeUnavailableNotice(model: model, onNavigate: navigate)
        }
    }

    private func workspaceContext(_ workspace: TalariaWorkspace, state: ConversationState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HierarchyHomeOriginLink(model: model, workspace: workspace, onNavigate: navigate)
                    Button { showFiles(state.storedID) } label: {
                        Label("Files & results", systemImage: "folder")
                            .iosFont(13).padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain).talariaGlass(cornerRadius: 22, interactive: true)
                    if workspace.sessionIDs.count > 1 {
                        Menu {
                            ForEach(workspace.sessionIDs, id: \.self) { id in
                                Button(model.sessions.first(where: { $0.id == id })?.displayTitle ?? "Conversation") {
                                    navigate(.conversation(id))
                                }
                            }
                        } label: {
                            Label("\(workspace.sessionIDs.count) conversations", systemImage: "bubble.left.and.bubble.right")
                                .iosFont(13).padding(.horizontal, 12).frame(minHeight: 44)
                        }
                        .talariaGlass(cornerRadius: 22, interactive: true)
                    }
                }
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 4)
    }

    private func conversationContext(_ state: ConversationState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.workspace(for: state.storedID) == nil, state.storedID != model.homeSessionID,
               !model.runs.contains(where: { $0.sessionID == state.storedID }) {
                HierarchyConversationNotice(model: model, sessionID: state.storedID, onNavigate: navigate)
            }
        }
        .padding(.bottom, 4)
    }

    private var loadingConversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.isLoadingSession ? "Loading…" : "Conversation unavailable")
                    .iosFont(22, .bold, relativeTo: .title2)
                if let banner = model.banner { Text(banner).iosFont(14).foregroundStyle(.secondary) }
                if model.isLoadingSession {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 18).fill(.primary.opacity(0.05)).frame(height: 70)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 66).padding(.bottom, bottomInset)
        }
    }

    private var header: some View {
        ZStack(alignment: .top) {
            if activeRoute == .destination(.home) {
                HStack {
                    profileMenu
                    Spacer()
                    roundButton("Browse conversations", symbol: "rectangle.on.rectangle") { navigate(.otherConversations) }
                }
                VStack(spacing: -6) {
                    TalariaMark(size: 56)
                    VStack(spacing: 2) {
                        Text("Home").font(.system(.body, design: .serif).weight(.semibold))
                        HStack(spacing: 5) {
                            if model.isConnected, model.homeAvailability == .available { IOSActivityDot(active: homeState?.isRunning == true) }
                            Text(homeStatus).iosFont(12.5, relativeTo: .caption)
                                .foregroundStyle(homeStatusColor).lineLimit(2).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7).talariaGlass(cornerRadius: 16)
                }
                .frame(maxWidth: 220).offset(y: -4).accessibilityElement(children: .combine)
            } else if isRootList {
                HStack {
                    profileLockup
                    Spacer()
                    if tab == .workspaces {
                        roundButton("New workspace", symbol: "plus", disabled: owner == nil) { workspaceOrigin = nil; showsWorkspaceEditor = true }
                    } else if tab == .activity {
                        Button("Mark read") { model.markAllActivityRead() }
                            .iosFont(16).padding(.horizontal, 18).frame(minHeight: 48)
                            .buttonStyle(.plain).talariaGlass(cornerRadius: 24, interactive: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                    Button(action: goBack) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").iosFont(14, .semibold)
                            Text(parentTitle).iosFont(16).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
                        }
                        .foregroundStyle(TalariaStyle.accent).padding(.horizontal, 16).frame(minHeight: 48)
                    }
                    .buttonStyle(.plain).talariaGlass(cornerRadius: 24, interactive: true)
                    .accessibilityLabel("Back to \(parentTitle)")
                    Spacer(minLength: 0)
                    detailMenu
                    }
                    if let heading = conversationHeading {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(heading.title).iosFont(22, .bold, relativeTo: .title2).tracking(-0.3).lineLimit(2)
                                .accessibilityAddTraits(.isHeader)
                            Text(heading.meta).iosFont(13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 16).frame(maxWidth: 840)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear {
                    if conversationHeading != nil { detailHeaderHeight = geometry.size.height }
                }
                .onChange(of: geometry.size.height) { _, height in
                    if conversationHeading != nil { detailHeaderHeight = height }
                }
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            profileActions
        } label: {
            Text(String(profileName.prefix(1)).uppercased()).iosFont(17, .bold)
                .foregroundStyle(.white).frame(width: 26, height: 26)
                .background(TalariaStyle.accent, in: RoundedRectangle(cornerRadius: 8))
                .frame(width: 48, height: 48)
        }
        .talariaGlass(cornerRadius: 24, interactive: true).accessibilityLabel("\(profileName) profile menu")
    }

    private var profileLockup: some View {
        Menu { profileActions } label: {
            HStack(spacing: -3) {
                TalariaMark(size: 28)
                Text("Talaria").font(.system(.body, design: .serif).weight(.semibold)).foregroundStyle(Color(uiColor: .label)).padding(.top, 3)
            }
            .padding(.horizontal, 18).frame(minHeight: 48)
        }
        .talariaGlass(cornerRadius: 24, interactive: true).accessibilityLabel("Talaria profile menu")
    }

    @ViewBuilder private var profileActions: some View {
        Text(profileName)
        Button("New workspace", systemImage: "plus") {
            workspaceOrigin = activeRoute == .destination(.home) ? model.homeSessionID : nil
            showsWorkspaceEditor = true
        }.disabled(owner == nil)
        Button("Skills", systemImage: "sparkles") { showsSkills = true }
        Button("Settings", systemImage: "gearshape") {
            if model.isConnected { model.showSessionSettings = true } else { model.showConnection = true }
        }.disabled(model.isPassiveChannel)
        Button("Change Home conversation…", systemImage: "house") { showsHomePicker = true }
            .disabled(!model.isConnected)
        Button("Connection…", systemImage: "network") { model.showConnection = true }
    }

    @ViewBuilder private var detailMenu: some View {
        switch activeRoute {
        case .destination(.workspace), .destination(.conversation):
            Menu {
                if let id = activeConversationID {
                    Button("Files & results", systemImage: "folder") { showFiles(id) }
                    Button("Use as Home", systemImage: "house") { Task { await model.chooseHome(id); navigate(.home) } }
                }
                Button("Settings", systemImage: "gearshape") { model.showSessionSettings = true }.disabled(model.isPassiveChannel)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 19)).frame(width: 48, height: 48)
            }
            .talariaGlass(cornerRadius: 24, interactive: true).accessibilityLabel("Conversation options")
        default: EmptyView()
        }
    }

    private var headerFade: some View {
        Group {
            if reduceTransparency {
                TalariaStyle.solidControlSurface.overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
            } else {
                Rectangle().fill(.ultraThinMaterial).overlay(IOSDesign.background.opacity(0.55))
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.35),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(height: (activeRoute == .destination(.home) ? headerInset : conversationHeading == nil ? 66 : detailInset) + 65).padding(.top, -65)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(IOSTab.allCases) { destination in
                Button { tab = destination } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: destination.symbol).font(.system(size: 20, weight: .regular))
                            .frame(maxWidth: .infinity).frame(height: 48)
                        if destination == .activity {
                            if model.needsYouCount > 0 {
                                Text("\(model.needsYouCount)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                    .background(TalariaStyle.attention, in: Capsule())
                                    .overlay(Capsule().stroke(.white, lineWidth: 2)).offset(x: -13, y: 8)
                            } else if model.unreadMobileRunCount > 0 {
                                Circle().fill(TalariaStyle.prominentAccent).frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(.white, lineWidth: 2)).offset(x: -17, y: 10)
                            }
                        }
                    }
                    .foregroundStyle(tab == destination ? TalariaStyle.accent : Color.primary)
                    .background(tab == destination ? TalariaStyle.accentTint : .clear, in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel(destination.rawValue)
                .accessibilityValue(destination == .activity && model.needsYouCount > 0 ? "\(model.needsYouCount) needs you" : "")
                .accessibilityAddTraits(tab == destination ? .isSelected : [])
            }
        }
        .padding(6).frame(height: 60).talariaGlass(cornerRadius: 30, interactive: true)
        .background {
            LinearGradient(colors: [.clear, IOSDesign.background.opacity(0.96)], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -16).padding(.top, -30).padding(.bottom, -44).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Main navigation")
    }

    private func roundButton(_ title: String, symbol: String, disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19)).frame(width: 48, height: 48).contentShape(Circle())
        }
        .buttonStyle(.plain).talariaGlass(cornerRadius: 24, interactive: true).accessibilityLabel(title).disabled(disabled)
    }

    private var conversationHeading: (title: String, meta: String)? {
        switch activeRoute {
        case .destination(.workspace(let id)):
            guard let workspace = model.workspace(id: id), workspaceConversation(workspace) != nil else { return nil }
            return (workspace.name, workspace.purpose.isEmpty ? "Workspace" : "Workspace · \(workspace.purpose)")
        case .destination(.conversation(let id)):
            guard let state = model.conversations[id] else { return nil }
            return (state.title, model.workspace(for: id).map { "Conversation in \($0.name)" } ?? "Other conversation")
        default: return nil
        }
    }
    private var homeState: ConversationState? { model.homeSessionID.flatMap { model.conversations[$0] } }
    private var homeStatus: String {
        if model.isConnecting { return "Connecting…" }
        if !model.isConnected { return model.endpoint == nil ? "Connect to Hermes" : "Disconnected · retrying" }
        switch model.homeAvailability {
        case .unselected: return "Not set for \(profileName)"
        case .unavailable: return "Session unavailable"
        case .loading: return "Loading…"
        case .failed: return "Couldn’t load Home"
        case .available:
            if homeState?.pendingInputs.isEmpty == false { return "Waiting for you" }
            return "\(profileName) · \(homeState?.isRunning == true ? "Working" : "Ready")"
        }
    }
    private var homeStatusColor: Color {
        if !model.isConnected || model.homeAvailability == .unavailable { return Color(red: 200/255, green: 64/255, blue: 47/255) }
        return homeState?.pendingInputs.isEmpty == false ? TalariaStyle.attention : .secondary
    }
    private var isRootList: Bool { paths[tab, default: []].isEmpty && tab != .home }
    private var activeConversationID: StoredSessionID? {
        switch activeRoute {
        case .destination(.home): model.homeSessionID
        case .destination(.conversation(let id)), .files(let id): id
        case .destination(.workspace(let id)): model.workspace(id: id).flatMap { workspaceConversation($0)?.storedID }
        default: nil
        }
    }
    private func workspaceConversation(_ workspace: TalariaWorkspace) -> ConversationState? {
        if let id = model.selectedID, workspace.sessionIDs.contains(id) { return model.conversations[id] }
        return workspace.sessionIDs.first.flatMap { model.conversations[$0] }
    }
    private var parentTitle: String {
        let stack = paths[tab, default: []]
        let parent = stack.count > 1 ? stack[stack.count - 2] : .destination(tab.root)
        switch parent {
        case .destination(.workspace(let id)): return model.workspace(id: id)?.name ?? "Workspaces"
        case .destination(.automation(let id)): return model.mobileActivity.schedules.first(where: { $0.id == id })?.name ?? "Automations"
        case .destination(.conversation(let id)): return model.conversations[id]?.title ?? "Conversation"
        case .destination(.home): return "Home"
        default: return tab.rawValue
        }
    }

    private func path(for destination: IOSTab) -> Binding<[IOSHierarchyRoute]> {
        Binding(get: { paths[destination, default: []] }, set: { value in
            paths[destination] = value
            if tab == destination { activate(value.last ?? .destination(destination.root)) }
        })
    }
    private func navigate(_ destination: HierarchyDestination) {
        let destination = normalized(destination)
        Task { await model.navigate(to: destination) }
    }
    private func normalized(_ destination: HierarchyDestination) -> HierarchyDestination {
        if case .conversation(let id) = destination, id == model.homeSessionID { return .home }
        return destination
    }
    private func show(_ destination: HierarchyDestination) {
        let destination = normalized(destination)
        let target = owningTab(for: destination)
        let route = IOSHierarchyRoute.destination(destination)
        if destination == target.root { paths[target] = [] }
        else if paths[target]?.last != route {
            if case .run(let id) = destination, let run = model.mobileActivity.runs.first(where: { $0.id == id }) {
                paths[target] = [.destination(.automation(run.scheduleID)), route]
            } else if case .conversation(let id) = destination, let workspace = model.workspace(for: id) {
                paths[target] = [.destination(.workspace(workspace.id)), route]
            } else { paths[target, default: []].append(route) }
        }
        tab = target
    }
    private func owningTab(for destination: HierarchyDestination) -> IOSTab {
        switch destination {
        case .home: .home
        case .activity: .activity
        case .automations, .automation, .run: .automations
        case .conversation(let id): id == model.homeSessionID ? .home : .workspaces
        default: .workspaces
        }
    }
    private func activate(_ route: IOSHierarchyRoute) {
        switch route {
        case .destination(let destination):
            guard model.hierarchyDestination != destination else { return }
            Task { await model.navigate(to: destination) }
        case .files(let id):
            guard model.selectedID != id else { return }
            Task { await model.openSession(id) }
        }
    }
    private func showFiles(_ id: StoredSessionID) { paths[tab, default: []].append(.files(id)) }
    private func goBack() {
        if !paths[tab, default: []].isEmpty { paths[tab]?.removeLast() }
        activate(activeRoute)
    }
}

private enum IOSHierarchyRoute: Hashable {
    case destination(HierarchyDestination)
    case files(StoredSessionID)
}
private enum IOSTab: String, CaseIterable, Identifiable {
    case home = "Home", workspaces = "Workspaces", automations = "Automations", activity = "Activity"
    var id: Self { self }
    var root: HierarchyDestination {
        switch self { case .home: .home; case .workspaces: .workspaces; case .automations: .automations; case .activity: .activity }
    }
    var symbol: String {
        switch self { case .home: "house"; case .workspaces: "square.stack"; case .automations: "clock"; case .activity: "bell.badge" }
    }
}
#endif
