#if os(macOS)
import SwiftUI
import HermesCore
import HermesProtocol

/// Hierarchy navigation is explicit; stored conversation titles never classify work.
struct MacWorkspaceView<Content: View>: View {
    @Bindable var model: HermesAppModel
    private let content: Content
    @State private var showsInspector = true
    @State private var showsNewConversation = false
    @State private var showsWorkspaceEditor = false
    @State private var showsHomeChooser = false
    @State private var showsSkills = false
    @State private var discussedRun: AutomationRun?
    @State private var workspaceOrigin: StoredSessionID?
    @State private var inspectorTab = MacHierarchyInspectorTab.context
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(model: HermesAppModel, @ViewBuilder content: () -> Content) {
        self.model = model; self.content = content()
    }
    private var destination: HierarchyDestination { model.hierarchyDestination }
    private var sidebarSelection: HierarchyDestination {
        MacHierarchyNavigation.sidebarSelection(destination, home: model.homeSessionID,
            runParent: { id in model.runs.first { $0.id == id }?.automationID },
            workspace: { model.workspace(for: $0)?.id })
    }
    private var displayedState: ConversationState? {
        switch destination {
        case .home: return model.homeSessionID.flatMap { model.conversations[$0] }
        case .workspace(let id):
            guard let selected = model.conversation, model.workspace(id: id)?.sessionIDs.contains(selected.storedID) == true else { return nil }
            return selected
        case .conversation(let id): return model.conversations[id]
        default: return nil
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: T.sidebarW)
            Rectangle().fill(T.panelEdge).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Hairline()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .background(reduceTransparency ? T.opaquePanel : T.chatBG)
            if showsInspector {
                Rectangle().fill(T.panelEdge).frame(width: 1)
                inspector.frame(width: T.inspectorW)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
        .background { keyboardActions }
        .sheet(isPresented: $showsNewConversation) { newConversationSheet }
        .sheet(isPresented: $showsWorkspaceEditor, onDismiss: { workspaceOrigin = nil }) {
            HierarchyWorkspaceEditor(model: model, startedFromHome: workspaceOrigin, onNavigate: navigate)
        }
        .sheet(isPresented: $showsHomeChooser) { HierarchyHomeChooserSheet(model: model, onNavigate: navigate) }
        .sheet(isPresented: $showsSkills) { skillsSheet }
        .sheet(item: $discussedRun) { run in
            if let detail = model.runDetails[run.id] {
                HierarchyDiscussSheet(model: model, run: run, detail: detail, onNavigate: navigate)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaNewConversation)) { _ in
            if model.isConnected { showsNewConversation = true }
        }
        .onChange(of: destination) { _, _ in inspectorTab = .context }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: 70)
                TalariaBrandLockup()
                Spacer(minLength: 0)
                Button { showsNewConversation = true } label: {
                    Image(systemName: "pencil").font(T.f(15, .medium)).foregroundStyle(T.deep)
                        .frame(width: 30, height: 30)
                }.buttonStyle(.plain).controlGlass(9, opacity: 0.7)
                    .accessibilityLabel("New conversation").help("New conversation (⌘N)")
                    .disabled(!model.isConnected)
            }.padding(.trailing, 14).frame(height: 52)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(T.f(11)).foregroundStyle(T.ink3)
                TextField("Search", text: $model.searchText).textFieldStyle(.plain).font(T.f(12))
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.ink3) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 10).frame(height: 28).background(T.card, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    navRow("Home", symbol: "house", destination: .home,
                           working: model.homeSessionID.flatMap { model.conversations[$0]?.isRunning } == true)
                    navRow("Activity", symbol: "bell", destination: .activity, count: model.needsYouCount)
                    section("Workspaces", destination: .workspaces)
                    ForEach(activeWorkspaces.prefix(5)) { workspace in
                        workspaceRow(workspace)
                    }
                    if activeWorkspaces.isEmpty {
                        Button("New workspace…") { workspaceOrigin = nil; showsWorkspaceEditor = true }
                            .font(T.f(11)).buttonStyle(.plain).foregroundStyle(T.deep).padding(.horizontal, 10).padding(.vertical, 6)
                            .disabled(!model.isConnected)
                    }
                    section("Automations", destination: .automations)
                    ForEach(filteredAutomations) { automation in
                        navRow(automation.name, symbol: "clock", destination: .automation(automation.id),
                               secondary: automation.enabled ? nil : "Paused",
                               unread: model.automationRuns(automation.id).contains(where: model.isRunUnread))
                    }
                    if filteredAutomations.isEmpty {
                        Text(model.isLoadingMobileActivity ? "Loading…" : "No automations").font(T.f(11))
                            .foregroundStyle(T.ink3).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    section("Other conversations", destination: .otherConversations, count: model.otherConversations.count)
                    ForEach(filteredConversations.prefix(model.searchText.isEmpty ? 3 : 100)) { session in
                        navRow(session.displayTitle, destination: .conversation(session.id))
                    }
                    if model.otherConversations.count > 3 && model.searchText.isEmpty {
                        Button("Show all") { navigate(.otherConversations) }.buttonStyle(.plain)
                            .font(T.f(11)).foregroundStyle(T.deep).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    if !model.searchText.isEmpty {
                        let matchingRuns = model.runs.filter { $0.title.localizedCaseInsensitiveContains(model.searchText) || $0.summary.localizedCaseInsensitiveContains(model.searchText) }
                        if !matchingRuns.isEmpty {
                            section("Runs", destination: .automations)
                            ForEach(matchingRuns.prefix(20)) { run in
                                navRow(run.title, symbol: "clock", destination: .run(run.id),
                                       subtitle: model.automations.first { $0.id == run.automationID }?.name)
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            Hairline()
            footer
        }.background(reduceTransparency ? T.opaquePanel : T.sideBG)
    }
    private var activeWorkspaces: [TalariaWorkspace] {
        model.workspaces.filter { !$0.isArchived && (model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || $0.purpose.localizedCaseInsensitiveContains(model.searchText)) }
    }
    private var filteredAutomations: [MobileSchedule] {
        model.automations.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) }
    }
    private var filteredConversations: [SessionSummary] {
        model.otherConversations.filter { model.searchText.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(model.searchText) || $0.preview.localizedCaseInsensitiveContains(model.searchText) }
    }
    private func section(_ title: String, destination: HierarchyDestination, count: Int? = nil) -> some View {
        HStack {
            Text(title.uppercased()).font(T.section).tracking(0.3).foregroundStyle(T.ink3)
            Spacer(minLength: 2)
            Button { navigate(destination) } label: {
                Text(count.map(String.init) ?? "All ›").font(T.f(11)).foregroundStyle(T.ink3)
            }.buttonStyle(.plain).accessibilityLabel("All \(title.lowercased())")
        }.padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }
    private func navRow(_ title: String, symbol: String? = nil, destination target: HierarchyDestination,
                        secondary: String? = nil, subtitle: String? = nil, count: Int = 0,
                        working: Bool = false, unread: Bool = false) -> some View {
        let selected = sidebarSelection == target
        return Button { navigate(target) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).font(T.f(12)).foregroundStyle(target == .home ? T.deep : T.ink2).frame(width: 16) }
                    Text(title).font(selected || target == .home ? T.rowSelected : T.row).foregroundStyle(T.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if count > 0 { countBadge(count) }
                    else if working { Circle().fill(T.fill).frame(width: 7, height: 7).modifier(MacWorkspacePulse(isActive: true)).accessibilityLabel("Working") }
                    else if let secondary { Text(secondary).font(T.f(10)).foregroundStyle(T.ink2) }
                    else if unread { Circle().fill(T.fill).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                }
                if let subtitle { Text(subtitle).font(T.rowSub).foregroundStyle(T.ink2).lineLimit(1).padding(.leading, 24) }
            }.padding(.horizontal, 10).padding(.vertical, subtitle == nil ? 5 : 6)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(selected ? T.rowSel : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? T.glassHi : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func workspaceRow(_ workspace: TalariaWorkspace) -> some View {
        let selected = sidebarSelection == .workspace(workspace.id)
        let needsYou = model.mobilePendingInputs.filter { $0.sessionID.map(workspace.sessionIDs.contains) == true }.count
        let working = workspace.sessionIDs.contains { model.conversations[$0]?.isRunning == true }
        return Button { navigate(.workspace(workspace.id)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(workspaceColor(workspace.swatch).opacity(0.45)).frame(width: 14, height: 11)
                    Text(workspace.name).font(selected ? T.rowSelected : T.row).foregroundStyle(T.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if needsYou > 0 { Label("NEEDS YOU", systemImage: "exclamationmark").font(T.f(9.5, .bold)).foregroundStyle(T.attention).labelStyle(.titleAndIcon) }
                    else if working { Circle().fill(T.fill).frame(width: 7, height: 7).modifier(MacWorkspacePulse(isActive: true)) }
                }
                Text(workspace.purpose.isEmpty ? "\(workspace.sessionIDs.count) conversations" : workspace.purpose)
                    .font(T.rowSub).foregroundStyle(T.ink2).lineLimit(1).padding(.leading, 22)
            }.padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                .background(selected ? T.rowSel : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? T.glassHi : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.showConnection = true } label: {
                HStack(spacing: 9) {
                    Text(String((model.endpoint?.name ?? "Talaria").prefix(1)).uppercased())
                        .font(T.f(12, .semibold)).foregroundStyle(.white).frame(width: 22, height: 22)
                        .background(T.deep, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.endpoint?.name ?? "Connect to Hermes").font(T.f(12, .semibold)).foregroundStyle(T.ink).lineLimit(1)
                        HStack(spacing: 5) {
                            Circle().fill(model.isConnected ? T.fill : T.failed).frame(width: 6, height: 6)
                            Text(model.isConnecting ? "Connecting…" : model.isConnected ? "Connected · \(model.endpoint?.profile ?? "")" : "Disconnected")
                                .font(T.f(11)).foregroundStyle(T.ink2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(T.f(10)).foregroundStyle(T.ink3)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(model.endpoint?.name ?? "Hermes"), \(model.isConnected ? "Connected" : "Disconnected")")
            HStack(spacing: 16) {
                Button { showsSkills = true } label: { Label("Skills", systemImage: "sparkles") }
                Button { model.showSessionSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }.font(T.f(11)).foregroundStyle(T.ink2).buttonStyle(.plain).disabled(!model.isConnected)
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            if let parent = parentDestination {
                Button { navigate(parent.destination) } label: { Label(parent.title, systemImage: "chevron.left") }
                    .font(T.f(12)).foregroundStyle(T.deep).buttonStyle(.plain).lineLimit(1)
                Text("›").foregroundStyle(T.ink3)
            }
            Text(destinationTitle).font(T.toolbar).foregroundStyle(T.ink).lineLimit(1)
            if let subtitle = toolbarSubtitle { Text(subtitle).font(T.status).foregroundStyle(T.ink2).lineLimit(1) }
            Spacer(minLength: 0)
            if destination == .activity {
                toolbarButton("Mark all read") { model.markAllActivityRead() }
            } else if destination == .workspaces {
                toolbarButton("New workspace", symbol: "plus") { workspaceOrigin = nil; showsWorkspaceEditor = true }
            } else if case .automation = destination, let automation = selectedAutomation {
                Text(automation.enabled ? "Enabled" : "Paused").font(T.f(11)).foregroundStyle(T.ink2)
                Toggle("Enabled", isOn: Binding(get: { automation.enabled }, set: { enabled in
                    Task { await model.setAutomationEnabled(automation.id, enabled: enabled) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(!model.isConnected || model.automationActionIDs.contains(automation.id))
                toolbarButton("Run now") { Task { await model.rerunAutomation(automation.id) } }
                    .disabled(!model.isConnected || !automation.enabled || model.automationActionIDs.contains(automation.id))
                    .help(automation.enabled ? "Run this automation now" : "Enable this automation before running it.")
            } else if case .run(let id) = destination, let run = model.runs.first(where: { $0.id == id }) {
                Button("Discuss…") { discussedRun = run }
                    .buttonStyle(HierarchyCapsuleStyle(prominent: true))
                    .disabled(model.runDetails[id]?.result.isEmpty != false)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                toolbarButton("Rerun") { Task { await model.rerunAutomation(run.automationID) } }
                    .disabled(!model.isConnected || model.automations.first(where: { $0.id == run.automationID })?.enabled != true || model.automationActionIDs.contains(run.automationID))
                    .help("Run this automation again. Paused automations must first be enabled.")
            }
            Button { showsInspector.toggle() } label: { Image(systemName: "rectangle.on.rectangle").font(T.f(12)).foregroundStyle(T.ink2).frame(width: 26, height: 26) }
                .buttonStyle(.plain).controlGlass(13, opacity: 0.55).accessibilityLabel(showsInspector ? "Hide inspector" : "Show inspector")
                .keyboardShortcut("i", modifiers: [.command, .option])
        }.padding(.horizontal, 16).frame(height: 52)
    }
    private func toolbarButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(T.f(11, .medium)).padding(.horizontal, 10).frame(height: 26)
        }.buttonStyle(.plain).foregroundStyle(T.ink).controlGlass(13, opacity: 0.55)
    }
    private var destinationTitle: String {
        switch destination {
        case .home: "Home"
        case .activity: "Activity"
        case .workspaces: "Workspaces"
        case .workspace(let id): model.workspace(id: id)?.name ?? "Workspace"
        case .automations: "Automations"
        case .automation(let id): model.automations.first { $0.id == id }?.name ?? "Automation"
        case .run(let id): model.runs.first { $0.id == id }?.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Run"
        case .conversation(let id): model.conversations[id]?.title ?? model.sessions.first { $0.id == id }?.displayTitle ?? "Conversation"
        case .otherConversations: "Other conversations"
        }
    }
    private var toolbarSubtitle: String? {
        switch destination {
        case .home: "Your conversation with \(model.endpoint?.name ?? "Hermes")"
        case .activity: "\(model.needsYouCount) need you · \(model.unreadMobileRunCount) unread"
        case .workspaces: "\(model.workspaces.filter { !$0.isArchived }.count) active · \(model.workspaces.filter(\.isArchived).count) archived"
        case .workspace: displayedState?.isRunning == true ? "Working" : nil
        case .run(let id): model.runDetails[id]?.status.rawValue
        default: nil
        }
    }
    private var parentDestination: (title: String, destination: HierarchyDestination)? {
        switch destination {
        case .workspace: ("Workspaces", .workspaces)
        case .automation: ("Automations", .automations)
        case .run(let id): model.runs.first { $0.id == id }.map { run in
            (model.automations.first { $0.id == run.automationID }?.name ?? "Automation", .automation(run.automationID))
        }
        case .conversation(let id):
            if let workspace = model.workspace(for: id) { (workspace.name, .workspace(workspace.id)) }
            else { ("Other conversations", .otherConversations) }
        default: nil
        }
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(MacHierarchyInspectorTab.allCases, id: \.self) { value in
                    Button { inspectorTab = value } label: {
                        Text(value.rawValue).font(T.f(12, inspectorTab == value ? .semibold : .regular))
                            .foregroundStyle(inspectorTab == value ? T.ink : T.ink2)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(inspectorTab == value ? T.rowSel : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(inspectorTab == value ? .isSelected : [])
                }
            }.padding(.horizontal, 12).frame(height: 52)
            Hairline()
            if inspectorTab == .context { contextInspector }
            else if case .run(let id) = destination, let detail = model.runDetails[id], let owner = model.currentHierarchyOwner {
                WorkspaceInspector(run: detail, owner: owner, pane: inspectorTab == .files ? .files : .terminal)
                    .id("\(owner.connectionID)-\(owner.profile)-\(id)-\(inspectorTab)")
            } else { WorkspaceInspector(state: displayedState,
                attachments: displayedState?.storedID == model.selectedID && displayedState?.owner == model.currentHierarchyOwner ? model.attachments : [],
                pane: inspectorTab == .files ? .files : .terminal).id(inspectorTab) }
        }.frame(maxHeight: .infinity).background(reduceTransparency ? T.opaquePanel : T.sideBG)
    }
    private var contextInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch destination {
                case .home:
                    contextSection("Recent results") {
                        ForEach(model.runs.prefix(3)) { run in
                            Button { navigate(.run(run.id)) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(model.automations.first { $0.id == run.automationID }?.name ?? run.title, systemImage: "clock").font(T.f(11.5, .medium))
                                    Text(HierarchyRunPresentation.preview(run.summary)).font(T.f(11)).foregroundStyle(T.ink2).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    contextSection("Home") {
                        Text(model.homeSessionID == nil ? "Choose the conversation you want to return to." : "Your explicitly chosen conversation for this profile.")
                            .font(T.f(11.5)).foregroundStyle(T.ink2)
                        Button("Change Home conversation…") { showsHomeChooser = true }.font(T.f(11.5)).buttonStyle(.plain).foregroundStyle(T.deep)
                    }
                case .workspace(let id):
                    if let workspace = model.workspace(id: id) {
                        contextSection("Workspace") { Text(workspace.purpose.isEmpty ? workspace.name : workspace.purpose).font(T.f(11.5)).foregroundStyle(T.ink2) }
                        contextSection("Conversations") {
                            ForEach(workspace.sessionIDs, id: \.self) { id in
                                Button(model.sessions.first { $0.id == id }?.displayTitle ?? "Conversation") { navigate(.conversation(id)) }
                                    .font(T.f(11.5)).buttonStyle(.plain).foregroundStyle(T.deep).lineLimit(2)
                            }
                        }
                        workspaceFiles(workspace)
                        WorkspaceStatusStack(state: displayedState)
                    }
                case .automation, .run:
                    if let automation = selectedAutomation {
                        contextSection("This automation") {
                            contextValue("Schedule", automation.schedule)
                            contextValue("State", automation.enabled ? "Enabled" : "Paused")
                            if let next = automation.nextRunAt, automation.enabled { contextValue("Next", next.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        contextSection("Instructions preview") {
                            Text(automation.promptPreview).font(T.mono).foregroundStyle(T.ink2).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(T.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                case .conversation(let id):
                    if let workspace = model.workspace(for: id) {
                        contextSection("Workspace") {
                            Text(workspace.purpose.isEmpty ? workspace.name : workspace.purpose).font(T.f(11.5)).foregroundStyle(T.ink2)
                            HierarchyHomeOriginLink(model: model, workspace: workspace, onNavigate: navigate)
                        }
                        workspaceFiles(workspace)
                    } else {
                        contextSection("Conversation") {
                            Text("Assign this conversation to Home or a workspace to keep its context together.").font(T.f(11.5)).foregroundStyle(T.ink2)
                        }
                    }
                    WorkspaceStatusStack(state: displayedState)
                default:
                    Text("Select a workspace or run to see its context and recorded files here.")
                        .font(T.f(11.5)).foregroundStyle(T.ink3).padding(.top, 22)
                }
            }.padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 16)
        }
    }
    private var selectedAutomation: MobileSchedule? {
        let id: String?
        switch destination {
        case .automation(let selected): id = selected
        case .run(let selected): id = model.runs.first { $0.id == selected }?.automationID
        default: id = nil
        }
        return model.automations.first { $0.id == id }
    }
    @ViewBuilder private func workspaceFiles(_ workspace: TalariaWorkspace) -> some View {
        let files = model.workspaceFiles(workspace.id)
        if !files.isEmpty {
            contextSection("Files & results") {
                ForEach(files.prefix(12)) { file in
                    Label((file.path as NSString).lastPathComponent, systemImage: "doc")
                        .font(T.mono).foregroundStyle(T.ink2).lineLimit(1).help(file.path)
                }
                Button("Recorded files ›") { inspectorTab = .files }
                    .font(T.f(11.5)).buttonStyle(.plain).foregroundStyle(T.deep)
            }
        }
    }
    private func contextSection<Rows: View>(_ title: String, @ViewBuilder content: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(T.section).tracking(0.3).foregroundStyle(T.ink3).padding(.top, 10)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func contextValue(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(name).foregroundStyle(T.ink2); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(T.f(11.5))
    }
    private func countBadge(_ count: Int) -> some View {
        Text("\(count)").font(T.f(10, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
            .background(T.attention, in: Capsule()).accessibilityLabel("\(count) need you")
    }
    private var newConversationSheet: some View {
        SettingsSheet("New conversation", content: {
            SettingsSection("Where") {
                SettingsRow("Home") { Button("Reply in Home") { showsNewConversation = false; navigate(.home) }.buttonStyle(.plain).foregroundStyle(T.deep) }
                SettingsRow("Workspace") { Button("New workspace…") {
                    workspaceOrigin = destination == .home ? model.homeSessionID : nil
                    showsNewConversation = false; showsWorkspaceEditor = true
                }.buttonStyle(.plain).foregroundStyle(T.deep) }
                SettingsRow("Other conversation") { Button("Start conversation") {
                    showsNewConversation = false
                    Task { if let id = await model.createConversationForDiscussion() { await model.navigate(to: .conversation(id)) } }
                }.buttonStyle(.plain).foregroundStyle(T.deep) }
            }
        }, footer: { Spacer(); Button("Cancel") { showsNewConversation = false }.keyboardShortcut(.cancelAction) }).frame(height: 260)
    }
    private var skillsSheet: some View {
        SettingsSheet("Skills", width: 460, content: {
            SettingsSection("Installed skills", footer: "Skills run on your Hermes host.") {
                if model.mobileActivity.skills.isEmpty { SettingsRow("No skills loaded") { EmptyView() } }
                ForEach(model.mobileActivity.skills) { skill in SettingsRow(skill.name, tall: true) { Text(skill.category).foregroundStyle(.secondary) } }
            }
        }, footer: { Spacer(); Button("Done") { showsSkills = false }.keyboardShortcut(.cancelAction) }).frame(height: 460)
    }
    private var keyboardActions: some View {
        Group {
            Button("Home") { navigate(.home) }.keyboardShortcut("1")
            Button("Workspaces") { navigate(.workspaces) }.keyboardShortcut("2")
            Button("Automations") { navigate(.automations) }.keyboardShortcut("3")
            Button("Activity") { navigate(.activity) }.keyboardShortcut("4")
            Button("Back") { if let parent = parentDestination { navigate(parent.destination) } }.keyboardShortcut("[")
        }.hidden().frame(width: 0, height: 0)
    }
    private func navigate(_ destination: HierarchyDestination) {
        model.searchText = ""
        Task { await model.navigate(to: destination) }
    }
}

enum MacHierarchyInspectorTab: String, CaseIterable { case context = "Context", files = "Files", terminal = "Terminal" }

public extension Notification.Name {
    static let talariaNewConversation = Notification.Name("com.talaria.newConversation")
}

enum MacHierarchyNavigation {
    static func sidebarSelection(_ destination: HierarchyDestination, home: StoredSessionID?,
                                 runParent: (String) -> String?, workspace: (StoredSessionID) -> UUID?) -> HierarchyDestination {
        switch destination {
        case .run(let id): return runParent(id).map(HierarchyDestination.automation) ?? .automations
        case .conversation(let id):
            if id == home { return .home }
            return workspace(id).map(HierarchyDestination.workspace) ?? .conversation(id)
        default: return destination
        }
    }
}

private func workspaceColor(_ hex: String) -> Color {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x3B7DDD
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}

private struct MacWorkspacePulse: ViewModifier {
    let isActive: Bool
    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(isActive && !reduceMotion ? (bright ? 1 : 0.35) : 1)
            .animation(isActive && !reduceMotion ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: bright)
            .onAppear { bright = true }
    }
}
#endif
