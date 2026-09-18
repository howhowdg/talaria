#if os(macOS)
import SwiftUI
import HermesCore

/// Native workspace chrome. Closing a tab only hides that view; it never deletes a session.
struct MacWorkspaceView<Content: View>: View {
    @Bindable var model: HermesAppModel
    private let content: Content
    @AppStorage("talaria.mac.sessionsPlacement") private var sessionsPlacement = "sidebar"
    @State private var navigation = MacWorkspaceNavigationState()
    @State private var showsSidebar = true
    @State private var showsInspector = true
    @State private var showsPreferences = false
    @State private var navigationOperation = UUID()
    @State private var isRefreshing = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(model: HermesAppModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var usesTabs: Bool { sessionsPlacement == "tabs" }
    private var owner: SessionOwner? {
        model.endpoint.map { SessionOwner(connectionID: $0.id, profile: $0.profile) }
    }
    private var displayedState: ConversationState? { usesTabs && navigation.showsStartPage ? nil : model.conversation }
    private var sessionRuntimes: [StoredSessionID: RuntimeSessionID] {
        model.conversations.mapValues(\.runtimeID)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar.frame(width: T.sidebarW)
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1)
            }
            VStack(spacing: 0) {
                workspaceHeader
                Rectangle().fill(T.hair).frame(height: 1)
                if usesTabs && navigation.showsStartPage {
                    ContentUnavailableView {
                        TalariaMark(size: 56)
                        Text("Ready when you are.").font(T.f(12, .semibold)).foregroundStyle(T.ink)
                    } description: {
                        Text("Open a conversation or start something new.").font(T.f(11)).foregroundStyle(T.ink2)
                    } actions: {
                        Button("New conversation", action: newConversation)
                            .buttonStyle(ProminentCapsule()).disabled(!model.isConnected)
                    }
                    .font(T.f(13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .background(reduceTransparency || contrast == .increased ? TalariaStyle.solidControlSurface : T.chatBG)
            if showsInspector {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1)
                WorkspaceInspector(state: displayedState, attachments: displayedState == nil ? [] : model.attachments)
                    .frame(width: T.inspectorW)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showsPreferences) {
            MacNavigationPreferences(placement: $sessionsPlacement)
        }
        .onAppear { synchronizeSelection(revealSelection: true) }
        .onChange(of: model.selectedID) { _, _ in synchronizeSelection() }
        .onChange(of: sessionRuntimes) { _, _ in synchronizeSelection() }
        .onChange(of: owner) { _, _ in
            navigationOperation = UUID()
            navigation = MacWorkspaceNavigationState()
            synchronizeSelection(revealSelection: true)
        }
        .onChange(of: sessionsPlacement) { _, _ in
            synchronizeSelection(revealSelection: true)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // This reservation starts at the window edge; adding leading padding
                // would move the lockup away from the traffic lights.
                Spacer().frame(width: 70)
                TalariaBrandLockup()
                Spacer(minLength: 0)
                Button(action: newConversation) {
                    Image(systemName: "pencil")
                        .font(T.f(15, .medium)).foregroundStyle(T.deep).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).controlGlass(9, opacity: 0.7)
                .help("New conversation (⌘N)")
                .accessibilityLabel("New conversation")
                .disabled(!model.isConnected || model.isLoadingSession)
            }
            .padding(.trailing, 14).frame(height: T.toolbarH)
            if usesTabs {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        folders
                        VStack(alignment: .leading, spacing: 3) {
                            sectionHeading("Hermes")
                            unavailableDestination("Skills", symbol: "sparkles")
                            unavailableDestination("Schedules", symbol: "clock")
                            unavailableDestination("Kanban", symbol: "rectangle.split.3x1")
                            Button { showsPreferences = true } label: {
                                Label("Settings", systemImage: "gearshape").font(T.f(12)).foregroundStyle(T.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 8).padding(.top, 10)
                }
            } else {
                searchField
                sessionList
            }
            Rectangle().fill(T.hair).frame(height: 1)
            connectionFooter
        }
        .background(reduceTransparency || contrast == .increased ? TalariaStyle.solidControlSurface : T.sideBG)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(T.f(11)).foregroundStyle(T.ink3)
                .accessibilityHidden(true)
            TextField("Find a conversation", text: $model.searchText,
                      prompt: Text("Find a conversation").font(T.f(11)).foregroundStyle(T.ink3))
                .textFieldStyle(.plain).font(T.f(11)).foregroundStyle(T.ink)
                .accessibilityLabel("Find a conversation")
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.field))
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if sessionItems.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "bubble.left.and.bubble.right").font(T.f(28)).foregroundStyle(T.ink3)
                        Text(model.searchText.isEmpty ? "No conversations yet" : "No matches")
                            .font(T.f(12, .semibold)).foregroundStyle(T.ink)
                    } description: {
                        Text(model.searchText.isEmpty ? "Connect to Hermes or start a conversation." : "Try a different title or phrase.")
                            .font(T.f(11)).foregroundStyle(T.ink2)
                    }
                    .font(T.f(13))
                    .frame(maxWidth: .infinity)
                }
                ForEach(Array(sessionGroups.enumerated()), id: \.element.title) { index, group in
                    sectionHeading(group.title).padding(.top, index == 0 ? 0 : 8)
                    ForEach(group.items) { item in
                        MacSessionButton(model: model, item: item) { open(item.id) }
                    }
                }
                sectionHeading("Folders").padding(.top, 8)
                folderRows
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            if !showsSidebar { Spacer().frame(width: 70) }
            if usesTabs {
                sessionTabs
            } else {
                Text(model.conversation?.title ?? "Talaria")
                    .font(T.toolbar).foregroundStyle(T.ink).lineLimit(1).truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if let state = model.conversation {
                    HStack(spacing: 6) {
                        Circle().fill(state.isRunning ? T.fill : T.ink3).frame(width: 6, height: 6)
                            .modifier(MacWorkspacePulse(isActive: state.isRunning)).accessibilityHidden(true)
                        Text(state.pendingInputs.isEmpty ? state.status : "Needs you")
                            .font(T.status).foregroundStyle(T.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Button { showsInspector.toggle() } label: {
                Image(systemName: "rectangle.on.rectangle").font(T.f(12)).foregroundStyle(T.ink2)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain).controlGlass(15, opacity: 0.5)
            .help(showsInspector ? "Hide inspector" : "Show inspector")
            .accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
        }
        .padding(.horizontal, 12).frame(height: T.toolbarH)
        .contentShape(Rectangle())
        .contextMenu { workspaceActions }
    }

    private var sessionTabs: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(navigation.tabIDs, id: \.self) { id in
                        let active = id == model.selectedID && !navigation.showsStartPage
                        HStack(spacing: 7) {
                            Button { open(id) } label: {
                                HStack(spacing: 7) {
                                    if let state = model.conversations[id], state.isRunning {
                                        Circle().fill(T.fill).frame(width: 6, height: 6)
                                            .modifier(MacWorkspacePulse(isActive: true)).accessibilityHidden(true)
                                    }
                                    Text(title(for: id)).font(active ? T.f(11, .semibold) : T.tab).foregroundStyle(T.ink)
                                        .lineLimit(1).truncationMode(.tail)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(title(for: id))
                            if active {
                                Button { closeTab(id) } label: {
                                    Image(systemName: "xmark").font(T.f(10, .semibold))
                                        .frame(width: 20, height: 24).contentShape(Rectangle())
                                }.buttonStyle(.plain).foregroundStyle(T.ink2)
                                    .accessibilityLabel("Close tab: \(title(for: id))")
                            }
                        }
                        .padding(.leading, 12).padding(.trailing, active ? 5 : 12).frame(height: 32)
                        .frame(maxWidth: 220)
                        .background(active ? T.rowSel : .clear, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(active ? 0.7 : 0), lineWidth: 1))
                        .accessibilityElement(children: .contain)
                    }
                }
            }.scrollIndicators(.hidden)
            Menu {
                if model.sessions.isEmpty { Text("No saved conversations") }
                ForEach(model.sessions) { session in
                    Button(session.displayTitle) { open(session.id) }
                }
            } label: { Image(systemName: "chevron.down").font(T.f(10)).foregroundStyle(T.ink2).frame(width: 24, height: 28) }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Open a saved conversation")
                .disabled(!model.isConnected || model.isLoadingSession)
            Button(action: newConversation) { Image(systemName: "plus").font(T.f(12)).foregroundStyle(T.ink2).frame(width: 30, height: 30) }
                .buttonStyle(.plain).help("New conversation")
                .accessibilityLabel("New conversation")
                .disabled(!model.isConnected || model.isLoadingSession)
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeading("Folders")
            folderRows
        }
    }

    @ViewBuilder private var folderRows: some View {
        if workspaces.isEmpty {
            Text("Workspaces appear as you open conversations.")
                .font(T.f(10.5)).foregroundStyle(T.ink3).padding(.horizontal, 10)
        } else {
            ForEach(workspaces, id: \.self) { path in
                Menu {
                    ForEach(model.conversations.values.filter { $0.owner == owner && $0.cwd == path }.sorted { $0.title < $1.title }, id: \.storedID) { state in
                        Button(state.title) { open(state.storedID) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(path == model.conversation?.cwd ? T.fill.opacity(0.45) : Color.black.opacity(0.18))
                            .frame(width: 14, height: 11)
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(T.f(12)).foregroundStyle(T.ink)
                    }
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .tint(nil as Color?).help(path)
                .disabled(!model.isConnected || model.isLoadingSession)
            }
        }
    }

    private var connectionFooter: some View {
        VStack(spacing: 6) {
            Button { model.showSessionSettings = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "person.crop.rectangle.stack").font(T.f(12)).foregroundStyle(T.ink3)
                    Text(model.endpoint?.profile ?? "Profile").font(T.f(11.5, .medium)).foregroundStyle(T.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(T.f(9)).foregroundStyle(T.ink3)
                }
                .padding(.horizontal, 6).padding(.vertical, 4).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.isConnected).help("Model and profile settings")
            Button { model.showConnection = true } label: {
                HStack(spacing: 9) {
                    Circle().fill(model.isConnected ? T.fill : T.ink3)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.endpoint?.name ?? "Connect to Hermes").font(T.f(11.5, .medium)).foregroundStyle(T.ink).lineLimit(1)
                        Text(model.isConnecting ? "Connecting…" : model.isConnected ? "Connected" : "Disconnected")
                            .font(T.f(10)).foregroundStyle(T.ink2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "slider.horizontal.3").font(T.f(12)).foregroundStyle(T.ink3)
                }
                .padding(.horizontal, 6).padding(.vertical, 4).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Gateway connection")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { workspaceActions }
    }

    @ViewBuilder private var workspaceActions: some View {
        Button {
            isRefreshing = true
            Task {
                await model.refreshSessions()
                isRefreshing = false
            }
        } label: { Label("Refresh conversations", systemImage: "arrow.clockwise") }
            .disabled(!model.isConnected || model.isLoadingSession || isRefreshing)
        Divider()
        Button(showsSidebar ? "Hide sidebar" : "Show sidebar") {
            showsSidebar.toggle()
        }.keyboardShortcut("s", modifiers: [.command, .control])
        Button("Navigation settings…") { showsPreferences = true }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(T.section).foregroundStyle(T.ink3)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }

    private func unavailableDestination(_ title: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("Soon").font(T.f(10)).foregroundStyle(T.ink3)
        }
        .font(T.f(11)).foregroundStyle(T.ink2)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), coming soon")
    }

    private var workspaces: [String] {
        Array(Set(model.conversations.values.filter { $0.owner == owner }.map(\.cwd).filter { !$0.isEmpty })).sorted()
    }

    private var sessionItems: [MacSessionItem] {
        var items = model.filteredSessions.map { session in
            MacSessionItem(id: session.id, title: model.conversations[session.id]?.title ?? session.displayTitle,
                preview: session.preview, startedAt: session.startedAt, state: model.conversations[session.id])
        }
        if let state = model.conversation, !items.contains(where: { $0.id == state.storedID }),
           !model.sessions.contains(where: { $0.id == state.storedID }),
           model.searchText.isEmpty || state.title.localizedCaseInsensitiveContains(model.searchText) {
            items.insert(MacSessionItem(id: state.storedID, title: state.title, preview: "", startedAt: nil, state: state), at: 0)
        }
        return items
    }

    private var sessionGroups: [(title: String, items: [MacSessionItem])] {
        let calendar = Calendar.current
        return ["Today", "Yesterday", "Earlier", "Conversations"].compactMap { title in
            let items = sessionItems.filter { item in
                guard let date = item.startedAt else { return title == "Conversations" }
                if calendar.isDateInToday(date) { return title == "Today" }
                if calendar.isDateInYesterday(date) { return title == "Yesterday" }
                return title == "Earlier"
            }
            return items.isEmpty ? nil : (title, items)
        }
    }

    private func title(for id: StoredSessionID) -> String {
        model.conversations[id]?.title ?? model.sessions.first(where: { $0.id == id })?.displayTitle ?? "Conversation"
    }

    private func synchronizeSelection(revealSelection: Bool? = nil) {
        navigation.synchronize(selectedID: model.selectedID, runtimes: sessionRuntimes,
                               revealSelection: revealSelection)
    }

    private func open(_ id: StoredSessionID) {
        guard model.isConnected, !model.isLoadingSession else {
            synchronizeSelection(revealSelection: false)
            return
        }
        let operation = UUID()
        navigationOperation = operation
        let requestedOwner = owner
        let previousSelection = model.selectedID
        Task {
            await model.openSession(id)
            guard navigationOperation == operation, owner == requestedOwner else { return }
            let selected = model.selectedID == id || model.selectedID != previousSelection
            synchronizeSelection(revealSelection: selected)
        }
    }

    private func newConversation() {
        guard model.isConnected, !model.isLoadingSession else { return }
        let operation = UUID()
        navigationOperation = operation
        let requestedOwner = owner
        let previousSelection = model.selectedID
        Task {
            await model.newConversation()
            guard navigationOperation == operation, owner == requestedOwner else { return }
            synchronizeSelection(revealSelection: model.selectedID != previousSelection)
        }
    }

    private func closeTab(_ id: StoredSessionID) {
        guard !model.isLoadingSession else { return }
        navigationOperation = UUID()
        if let next = navigation.closeTab(id) { open(next) }
    }
}

/// Tab visibility is local UI state; the model remains authoritative about the
/// selected conversation. Runtime identities let stored-ID rotations retain a tab.
struct MacWorkspaceNavigationState {
    var selection: StoredSessionID?
    private(set) var tabIDs: [StoredSessionID] = []
    private(set) var showsStartPage = false
    private var modelSelection: StoredSessionID?
    private var knownRuntimes: [StoredSessionID: RuntimeSessionID] = [:]

    mutating func synchronize(selectedID: StoredSessionID?, runtimes: [StoredSessionID: RuntimeSessionID],
                              revealSelection: Bool? = nil) {
        let previousRuntime = modelSelection.flatMap { knownRuntimes[$0] }
        let selectedRuntime = selectedID.flatMap { runtimes[$0] }
        let rotatedIdentity = selectedID != modelSelection && previousRuntime != nil && previousRuntime == selectedRuntime
        var migrated: [StoredSessionID] = []
        for id in tabIDs {
            let replacement: StoredSessionID
            if runtimes[id] == nil, let runtime = knownRuntimes[id],
               let moved = runtimes.first(where: { $0.value == runtime })?.key {
                replacement = moved
            } else {
                replacement = id
            }
            if !migrated.contains(replacement) { migrated.append(replacement) }
        }
        tabIDs = migrated
        let reveal = revealSelection ?? (selectedID != modelSelection && !rotatedIdentity)
        selection = selectedID
        modelSelection = selectedID
        knownRuntimes = runtimes
        if reveal, let selectedID {
            if !tabIDs.contains(selectedID) { tabIDs.append(selectedID) }
            showsStartPage = false
        }
    }

    /// Hide the closed detail before any asynchronous attempt to open its neighbor.
    /// A failed or disconnected open then leaves a start page, never a phantom tab.
    mutating func closeTab(_ id: StoredSessionID) -> StoredSessionID? {
        tabIDs.removeAll { $0 == id }
        guard id == modelSelection else { return nil }
        selection = nil
        showsStartPage = true
        return tabIDs.last
    }
}

private struct MacSessionItem: Identifiable {
    let id: StoredSessionID
    let title: String
    let preview: String
    let startedAt: Date?
    let state: ConversationState?
}

private struct MacSessionButton: View {
    @Bindable var model: HermesAppModel
    let item: MacSessionItem
    let action: () -> Void

    var body: some View {
        // Observe authoritative selection in each lazy child, rather than capturing
        // the parent's mirrored navigation state in nested ForEach closures.
        let isSelected = model.selectedID == item.id
        Button(action: action) {
            MacSessionRow(item: item, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityRemoveTraits(isSelected ? [] : [.isSelected])
        .disabled(!model.isConnected || model.isLoadingSession)
    }
}

private struct MacSessionRow: View {
    let item: MacSessionItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.title).font(isSelected ? T.rowSelected : T.row).foregroundStyle(T.ink).lineLimit(1)
                Spacer(minLength: 0)
                if item.state?.isRunning == true {
                    Circle().fill(T.fill).frame(width: 7, height: 7)
                        .modifier(MacWorkspacePulse(isActive: true)).accessibilityHidden(true)
                }
                if item.state?.pendingInputs.isEmpty == false {
                    Text("NEEDS YOU").font(T.f(10, .semibold)).foregroundStyle(T.deep)
                }
            }
            if !item.preview.isEmpty {
                Text(item.preview).font(T.rowSub).foregroundStyle(T.ink2).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MacSessionSelectionBackground(isSelected: isSelected) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MacSessionSelectionBackground: View {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if isSelected {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let fill = reduceTransparency ? TalariaStyle.solidControlSurface : T.rowSel
            let border = contrast == .increased ? T.ink3 : Color.white.opacity(0.7)
            shape.fill(fill).overlay(shape.strokeBorder(border, lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                .accessibilityHidden(true)
        }
    }
}

private struct MacWorkspacePulse: ViewModifier {
    let isActive: Bool
    @State private var isBright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shouldPulse: Bool { isActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(shouldPulse ? (isBright ? 1 : 0.35) : 1)
            .animation(shouldPulse ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: isBright)
            .onChange(of: shouldPulse, initial: true) { _, value in isBright = value }
    }
}

private struct MacNavigationPreferences: View {
    @Binding var placement: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sessions in", selection: $placement) {
                        Text("Sidebar").tag("sidebar")
                        Text("Tabs").tag("tabs")
                    }.pickerStyle(.segmented)
                } header: { Text("Navigation") } footer: {
                    Text("Choose one place for your conversations. Closing a tab keeps its conversation and draft.")
                }
            }
            .font(T.f(13)).formStyle(.grouped).navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.frame(width: 440, height: 250)
    }
}
#endif
