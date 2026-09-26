import SwiftUI
import HermesCore

/// Shared result-first and organisation surfaces. The platform shells retain
/// their native conversation views, navigation stacks and floating controls.
struct HierarchyContentView: View {
    @Bindable var model: HermesAppModel
    let destination: HierarchyDestination
    var topInset: CGFloat = 24
    var bottomInset: CGFloat = 24
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var showsSearch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: H.mobile ? 20 : 22) {
                if H.mobile && isList && showsSearch { searchField }
                if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isList {
                    HierarchySearchResults(model: model, onNavigate: onNavigate)
                } else { content }
                if let error = model.hierarchyError ?? model.mobileActivityError {
                    HierarchyNotice(text: error, isError: true)
                }
                if let error = model.classificationStore.error { HierarchyNotice(text: error, isError: true) }
                if model.isLoadingMobileActivity && model.automations.isEmpty && destination != .home {
                    HierarchySkeletonRows(count: 3)
                }
                if showsActivityNotices {
                    ForEach(model.mobileActivity.notices, id: \.self) { HierarchyNotice(text: $0) }
                }
            }
            .frame(maxWidth: H.mobile ? .infinity : 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, H.inset)
            .padding(.top, topInset).padding(.bottom, bottomInset)
        }
        .refreshable { await model.refreshMobileActivity(); await model.refreshChannels() }
        .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
            if H.mobile && isList && value.translation.height > 60 { showsSearch = true }
        })
        .accessibilityAction(named: "Search") { if isList { showsSearch = true } }
    }

    private var showsActivityNotices: Bool {
        switch destination { case .automations, .automation, .activity: true; default: false }
    }
    private var isList: Bool {
        switch destination { case .workspaces, .automations, .activity, .otherConversations: true; default: false }
    }
    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText).textFieldStyle(.plain).hierarchyFont(16)
            Button { model.searchText = ""; showsSearch = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).frame(width: 44, height: 44).accessibilityLabel("Close search")
        }.padding(.leading, 14).hierarchyCard(opacity: 0.7, radius: 22)
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .home: home
        case .workspaces: HierarchyWorkspaces(model: model, onNavigate: onNavigate)
        case .otherConversations: HierarchyOtherConversations(model: model, onNavigate: onNavigate)
        case .workspace(let id):
            if let workspace = model.workspaces.first(where: { $0.id == id }) {
                HierarchyWorkspaceHeader(model: model, workspace: workspace, onNavigate: onNavigate)
                if workspace.sessionIDs.isEmpty {
                    HierarchyEmptyState(title: "Start in \(workspace.name)", detail: "Add an existing conversation, or start a new one in this workspace.")
                    HStack {
                        Button("New conversation") { Task { await model.newConversation(in: id); onNavigate(.workspace(id)) } }
                            .buttonStyle(HierarchyCapsuleStyle(prominent: true)).disabled(!model.isConnected)
                        Menu("Add conversation…") {
                            ForEach(model.otherConversations) { session in
                                Button(session.displayTitle) { model.assignSession(session.id, to: id); onNavigate(.workspace(id)) }
                            }
                        }.buttonStyle(HierarchyCapsuleStyle()).disabled(model.otherConversations.isEmpty)
                    }
                }
            } else { HierarchyEmptyState(title: "Workspace unavailable", detail: "This workspace is no longer in this profile.") }
        case .automations: HierarchyAutomations(model: model, onNavigate: onNavigate)
        case .automation(let id):
            if let automation = model.automations.first(where: { $0.id == id }) {
                HierarchyAutomationDetail(model: model, automation: automation, onNavigate: onNavigate)
            } else { HierarchyEmptyState(title: "Automation unavailable", detail: "Refresh to load the automations available on this host.", symbol: "clock") }
        case .run(let id):
            if let run = model.runs.first(where: { $0.id == id }) {
                HierarchyRunDetail(model: model, run: run, onNavigate: onNavigate)
            } else { HierarchyEmptyState(title: "Run unavailable", detail: "This run is not in the loaded history. Refresh its automation to try again.", symbol: "clock") }
        case .activity: HierarchyActivity(model: model, onNavigate: onNavigate)
        case .conversation:
            if model.isLoadingSession { HierarchySkeletonRows(count: 3) }
            else { HierarchyEmptyState(title: "Conversation unavailable", detail: "Reconnect to load this conversation.", symbol: "bubble.left") }
        }
    }

    @ViewBuilder private var home: some View {
        switch model.homeAvailability {
        case .unselected: HierarchyHomeSelection(model: model, onNavigate: onNavigate)
        case .unavailable:
            HierarchyHomeUnavailableNotice(model: model, onNavigate: onNavigate)
            cachedHome
            Text("Reconnect Home to continue").hierarchyFont(H.body).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16).hierarchyCard(opacity: 0.5, radius: 22)
        case .failed(let error):
            HierarchyNotice(text: error, isError: true)
            cachedHome
            Button("Try again") { onNavigate(.home) }.buttonStyle(HierarchyCapsuleStyle())
        case .loading: cachedHome
        case .available: cachedHome
        }
    }

    @ViewBuilder private var cachedHome: some View {
        #if os(macOS)
        MacTranscriptMessages(messages: model.cachedHomeMessages, assistantName: model.endpoint?.name ?? "Hermes")
            .opacity(0.7)
        #else
        ForEach(model.cachedHomeMessages) { message in
            VStack(alignment: .leading, spacing: 8) {
                HierarchySectionLabel(title: message.role == .user ? "You" : model.endpoint?.name ?? "Hermes")
                MarkdownMessage(text: message.displayText).hierarchyFont(H.mobile ? 16 : 12.5).lineSpacing(5)
            }.opacity(0.7)
        }
        #endif
    }
}

struct HierarchySearchResults: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var query: String { model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaces: [TalariaWorkspace] { model.workspaces.filter { matches($0.name + " " + $0.purpose) } }
    private var automations: [MobileSchedule] { model.automations.filter { matches($0.name + " " + $0.promptPreview) } }
    private var runs: [MobileRun] { model.runs.filter { matches($0.title + " " + $0.summary) } }
    private var sessions: [SessionSummary] {
        let channelIDs = model.channelSessionIDs
        return model.sessions.filter { !channelIDs.contains($0.id) && matches($0.displayTitle + " " + $0.preview) }
    }
    private func matches(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChannelSections(model: model, onNavigate: onNavigate)
            if H.mobile { Text("Search").hierarchyFont(28, .bold).tracking(-0.4) }
            if sessions.isEmpty && workspaces.isEmpty && automations.isEmpty && runs.isEmpty && model.channelGroups.allSatisfy({ $0.sessions.isEmpty }) && model.channelSearchResults.isEmpty && !model.isSearchingChannels {
                HierarchyEmptyState(title: "No matches", detail: "Try a different name or phrase.", symbol: "magnifyingglass")
            }
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HierarchySectionLabel(title: "Conversations")
                    ForEach(sessions) { session in
                        searchRow(session.displayTitle, parent: parent(session.id), destination: .conversation(session.id))
                    }
                }
            }
            if !workspaces.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HierarchySectionLabel(title: "Workspaces")
                    ForEach(workspaces) { searchRow($0.name, parent: nil, destination: .workspace($0.id)) }
                }
            }
            if !automations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HierarchySectionLabel(title: "Automations")
                    ForEach(automations) { searchRow($0.name, parent: nil, destination: .automation($0.id)) }
                }
            }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HierarchySectionLabel(title: "Runs")
                    ForEach(runs) { run in
                        searchRow(HierarchyRunPresentation.title(run), parent: model.automations.first { $0.id == run.automationID }?.name, destination: .run(run.id))
                    }
                }
            }
        }
    }
    private func parent(_ id: StoredSessionID) -> String? {
        if id == model.homeSessionID { return "Home" }
        return model.workspace(for: id)?.name
    }
    private func searchRow(_ title: String, parent: String?, destination: HierarchyDestination) -> some View {
        Button { model.searchText = ""; onNavigate(destination) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).hierarchyFont(H.mobile ? 16 : 12, .medium).lineLimit(1)
                    if let parent { Text(parent).hierarchyFont(H.meta).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").hierarchyFont(H.mobile ? 12 : 9).foregroundStyle(.secondary)
            }.padding(12).hierarchyCard(opacity: 0.55)
        }.buttonStyle(.plain)
    }
}

struct HierarchyWorkspaceHeader: View {
    @Bindable var model: HermesAppModel
    let workspace: TalariaWorkspace
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if H.mobile {
                HStack(spacing: 8) {
                    HierarchySwatch(color: workspace.swatch)
                    Text(workspace.name).hierarchyFont(22, .bold).tracking(-0.3)
                }
            }
            if !workspace.purpose.isEmpty { Text(workspace.purpose).hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(.secondary) }
            HierarchyHomeOriginLink(model: model, workspace: workspace, onNavigate: onNavigate)
            if H.mobile, !model.workspaceFiles(workspace.id).isEmpty {
                DisclosureGroup("Files & results") {
                    ForEach(model.workspaceFiles(workspace.id)) { file in
                        Label((file.path as NSString).lastPathComponent, systemImage: "doc")
                            .hierarchyFont(13).monospaced().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                    Text("Files touched in these conversations. Open Files for recorded previews.")
                        .hierarchyFont(12).foregroundStyle(.secondary)
                }.hierarchyFont(13, .medium)
            }
            if workspace.sessionIDs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.sessionIDs, id: \.self) { id in
                            Button(model.sessions.first(where: { $0.id == id })?.displayTitle ?? "Conversation") {
                                onNavigate(.conversation(id))
                            }.buttonStyle(HierarchyCapsuleStyle())
                        }
                    }
                }
            }
        }
    }
}

struct HierarchySkeletonRows: View {
    var count = 3
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: H.radius).fill(.primary.opacity(0.05)).frame(height: H.mobile ? 76 : 58)
            }
        }.accessibilityLabel("Loading")
    }
}
