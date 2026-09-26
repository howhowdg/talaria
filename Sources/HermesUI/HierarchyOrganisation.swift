import SwiftUI
import HermesCore

struct HierarchyHomeSelection: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var choice: StoredSessionID?
    @State private var fresh = false
    @State private var saving = false
    @State private var query = ""
    private var candidates: [SessionSummary] {
        let runIDs = Set(model.runs.map(\.sessionID))
        return model.sessions.filter { !runIDs.contains($0.id) }
    }
    private var visibleCandidates: [SessionSummary] {
        candidates.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: H.mobile ? 18 : 16) {
            if !H.mobile { TalariaMark(size: 40).frame(maxWidth: .infinity) }
            VStack(spacing: 8) {
                Text("Choose your Home").hierarchyFont(H.mobile ? 22 : 15, .semibold)
                Text("Home is your ongoing conversation with \(model.endpoint?.name ?? "Hermes"). Choose a conversation, or start fresh.")
                    .hierarchyFont(H.mobile ? 15 : 12).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
            TelegramTopicImportButton(model: model, onNavigate: onNavigate)
                .frame(maxWidth: .infinity)
            if candidates.count > 8 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a conversation", text: $query).textFieldStyle(.plain)
                }.hierarchyFont(H.mobile ? 15 : 12).padding(.horizontal, 10)
                    .frame(minHeight: H.mobile ? 44 : 28).hierarchyCard(opacity: 0.55, radius: 8)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(visibleCandidates) { session in
                        choiceRow(session.displayTitle, selected: choice == session.id && !fresh) {
                            choice = session.id; fresh = false
                        }
                        Hairline()
                    }
                    choiceRow("Start a new conversation", selected: fresh) { fresh = true; choice = nil }
                }
            }
            .frame(height: min(CGFloat(visibleCandidates.count + 1) * (H.mobile ? 56 : 40), H.mobile ? 280 : 320))
            .hierarchyCard(opacity: 0.7, radius: H.mobile ? 18 : 10)
            Text("One Home per profile. You can change it later.")
                .hierarchyFont(H.mobile ? 13 : 11).foregroundStyle(.secondary).lineSpacing(3)
            HStack {
                if !H.mobile {
                    Button("Not now") { onNavigate(.workspaces) }.buttonStyle(HierarchyCapsuleStyle())
                    Spacer()
                }
                Button("Use as Home") {
                    saving = true
                    Task {
                        if fresh { await model.startFreshHome() }
                        else if let choice { await model.chooseHome(choice) }
                        saving = false
                        onNavigate(.home)
                    }
                }
                .buttonStyle(HierarchyCapsuleStyle(prominent: true))
                .frame(maxWidth: H.mobile ? .infinity : nil)
                .disabled(saving || !model.isConnected || (!fresh && !candidates.contains { $0.id == choice }))
            }
        }
        .frame(maxWidth: H.mobile ? .infinity : 460)
        .frame(maxWidth: .infinity).padding(.top, H.mobile ? 0 : 32)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? TalariaStyle.accent : .secondary)
                Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .hierarchyFont(H.mobile ? 15 : 12)
            .padding(.horizontal, 14).frame(minHeight: H.mobile ? 56 : 40)
            .background(selected ? TalariaStyle.accentTint.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct HierarchyHomeUnavailableNotice: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var choose = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Home is unavailable. ").fontWeight(.semibold)
                + Text("Its conversation could not be found. Your cached conversation stays here until you choose another Home.")
            } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
            .hierarchyFont(H.mobile ? 14 : 12)
            HStack {
                Button("Choose another…") { choose = true }
                Button("Start fresh") { Task { await model.startFreshHome(); onNavigate(.home) } }
            }.buttonStyle(.plain).hierarchyFont(H.mobile ? 14 : 11.5, .semibold).foregroundStyle(TalariaStyle.accent)
                .disabled(!model.isConnected)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: H.mobile ? 18 : 10))
        .overlay(RoundedRectangle(cornerRadius: H.mobile ? 18 : 10).strokeBorder(.red.opacity(0.2), lineWidth: 1))
        .sheet(isPresented: $choose) {
            HierarchyHomeChooserSheet(model: model, onNavigate: onNavigate)
        }
    }
}

struct HierarchyHomeChooserSheet: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsSheet("Choose Home", width: 500) {
            Group {
                HierarchyHomeSelection(model: model) { destination in dismiss(); onNavigate(destination) }
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

struct HierarchyWorkspaces: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if H.mobile {
                Text("Workspaces").hierarchyFont(28, .bold).tracking(-0.4).accessibilityAddTraits(.isHeader)
            }
            TelegramTopicImportButton(model: model, onNavigate: onNavigate)
            if model.workspaces.isEmpty {
                VStack(spacing: 4) {
                    HierarchyEmptyState(title: "No workspaces yet", detail: "Create a workspace for a distinct problem, and choose the conversations that belong to it.")
                    Button("New workspace") { creating = true }.buttonStyle(HierarchyCapsuleStyle(prominent: true))
                }
            } else {
                workspaceSection("Active", archived: false)
                workspaceSection("Archived", archived: true)
            }
            if H.mobile && !model.otherConversations.isEmpty {
                HierarchyOtherConversations(model: model, onNavigate: onNavigate, showTitle: false)
            }
            if !model.archivedConversations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HierarchySectionLabel(title: "Archived conversations")
                    ForEach(model.archivedConversations) { session in
                        HStack {
                            Text(session.displayTitle).hierarchyFont(H.mobile ? 16 : 12, .medium).lineLimit(1)
                            Spacer()
                            Button("Restore") { model.archiveConversation(session.id, archived: false) }
                                .buttonStyle(.plain).hierarchyFont(H.meta).foregroundStyle(TalariaStyle.accent)
                                .frame(minHeight: H.mobile ? 44 : 26)
                        }.padding(.horizontal, 12).padding(.vertical, 5).hierarchyCard(dashed: true)
                    }
                }
            }
        }
        .sheet(isPresented: $creating) { HierarchyWorkspaceEditor(model: model, onNavigate: onNavigate) }
    }

    @ViewBuilder private func workspaceSection(_ title: String, archived: Bool) -> some View {
        let rows = model.workspaces.filter { $0.isArchived == archived }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HierarchySectionLabel(title: title)
                ForEach(rows) { workspace in
                    HierarchyWorkspaceCard(model: model, workspace: workspace, onNavigate: onNavigate)
                }
            }
        }
    }
}

struct HierarchyWorkspaceCard: View {
    @Bindable var model: HermesAppModel
    let workspace: TalariaWorkspace
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var pendingCount: Int {
        model.mobilePendingInputs.filter { item in
            item.sessionID.map { workspace.sessionIDs.contains($0) } == true
        }.count
    }
    private var working: Bool { workspace.sessionIDs.contains { model.conversations[$0]?.isRunning == true } }

    var body: some View {
        Group {
            if workspace.isArchived { archivedCard }
            else { activeCard }
        }
        .contextMenu {
            Button(workspace.isArchived ? "Restore" : "Archive") {
                model.archiveWorkspace(workspace.id, archived: !workspace.isArchived)
            }
        }
    }

    private var archivedCard: some View {
        HStack(spacing: 10) {
            Button { onNavigate(.workspace(workspace.id)) } label: {
                HStack(spacing: 8) {
                    HierarchySwatch(color: workspace.swatch)
                    Text(workspace.name).hierarchyFont(H.mobile ? 16 : 13, .medium).lineLimit(1)
                    Spacer()
                    if H.mobile { Image(systemName: "chevron.right").hierarchyFont(12) }
                }.frame(minHeight: H.mobile ? 44 : 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !H.mobile {
                Button("Restore") { model.archiveWorkspace(workspace.id, archived: false) }
                    .buttonStyle(.plain).hierarchyFont(11).foregroundStyle(TalariaStyle.accent)
            }
        }
        .padding(.horizontal, H.mobile ? 16 : 14).padding(.vertical, H.mobile ? 6 : 8)
        .foregroundStyle(.secondary).hierarchyCard(dashed: true)
        .accessibilityAction(named: "Restore") { model.archiveWorkspace(workspace.id, archived: false) }
    }

    private var activeCard: some View {
        Button { onNavigate(.workspace(workspace.id)) } label: {
            VStack(alignment: .leading, spacing: H.mobile ? 6 : 8) {
                HStack(spacing: 8) {
                    HierarchySwatch(color: workspace.swatch)
                    Text(workspace.name).hierarchyFont(H.mobile ? 16 : 13, .semibold).lineLimit(1)
                    Spacer(minLength: 6)
                    if pendingCount > 0 {
                        HierarchyNeedsYouTag()
                    } else if working {
                        Label("Working", systemImage: "circle.fill").hierarchyFont(H.mobile ? 13 : 11)
                            .foregroundStyle(TalariaStyle.accent)
                    }
                }
            if !workspace.purpose.isEmpty {
                Text(workspace.purpose).hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(.secondary).lineSpacing(4)
            }
            if let topic = model.telegramTopic(for: workspace.id) {
                Label("\(topic.groupName) · \(topic.displayLabel)", systemImage: "bubble.left.and.bubble.right")
                    .hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(1)
                if let session = model.sessions.first(where: { $0.id == topic.currentSessionID }),
                   session.displayTitle != workspace.name {
                    Text(session.displayTitle).hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack {
                Text("\(workspace.sessionIDs.count) \(workspace.sessionIDs.count == 1 ? "conversation" : "conversations")")
                if pendingCount > 0 {
                    Text("· \(pendingCount) \(pendingCount == 1 ? "needs you" : "need you")").foregroundStyle(TalariaStyle.attention)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }.hierarchyFont(H.meta).foregroundStyle(.secondary)
            }
            .padding(.horizontal, H.mobile ? 16 : 14).padding(.vertical, H.mobile ? 14 : 12)
            .hierarchyCard(opacity: 0.65).contentShape(RoundedRectangle(cornerRadius: H.radius))
        }
        .buttonStyle(.plain)
    }
}

struct HierarchyOtherConversations: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    var showTitle = true
    private var sessions: [SessionSummary] { model.otherConversations.filter { !model.isChannelSession($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChannelSections(model: model, onNavigate: onNavigate)
            if showTitle && H.mobile { Text("Other conversations").hierarchyFont(28, .bold).tracking(-0.4) }
            HierarchySectionLabel(title: "Other conversations · \(sessions.count)")
            if sessions.isEmpty {
                Text("No other conversations.").hierarchyFont(H.body).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ForEach(sessions) { session in
                Button { onNavigate(.conversation(session.id)) } label: {
                    HStack {
                        Text(session.displayTitle).hierarchyFont(H.mobile ? 16 : 12, .medium).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").hierarchyFont(H.mobile ? 12 : 9).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: H.mobile ? 44 : 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct HierarchyConversationNotice: View {
    @Bindable var model: HermesAppModel
    let sessionID: StoredSessionID
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var makingWorkspace = false
    @State private var adding = false
    var body: some View {
        if sessionID != model.homeSessionID, model.workspace(for: sessionID) == nil,
           !model.runs.contains(where: { $0.sessionID == sessionID }) { notice }
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("This conversation isn't part of Home, a workspace or an automation yet.", systemImage: "circle.dotted")
                .hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button("Make it a workspace") { makingWorkspace = true }
                    Menu("Add to…") {
                        ForEach(model.workspaces.filter { !$0.isArchived }) { workspace in
                            Button(workspace.name) { model.assignSession(sessionID, to: workspace.id); onNavigate(.workspace(workspace.id)) }
                        }
                    }.disabled(model.workspaces.filter { !$0.isArchived }.isEmpty)
                    Button("Use as Home") { Task { await model.chooseHome(sessionID); onNavigate(.home) } }
                    Button("Archive") { model.archiveConversation(sessionID, archived: true); onNavigate(.workspaces) }
                }.buttonStyle(.plain).hierarchyFont(H.mobile ? 13 : 11, .semibold).foregroundStyle(TalariaStyle.accent)
                    .frame(minHeight: H.mobile ? 44 : 24)
            }
        }
        .padding(12).hierarchyCard(opacity: 0.55, radius: H.mobile ? 18 : 10)
        .sheet(isPresented: $makingWorkspace) {
            HierarchyWorkspaceEditor(model: model, sessionID: sessionID, onNavigate: onNavigate)
        }
    }
}

struct HierarchyWorkspaceEditor: View {
    @Bindable var model: HermesAppModel
    var sessionID: StoredSessionID? = nil
    /// Captured by an explicit "New workspace" action in Home, never by
    /// inspecting whichever conversation happens to remain selected later.
    var startedFromHome: StoredSessionID? = nil
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var purpose = ""
    @State private var swatch = "#3B7DDD"
    private let colors = ["#3B7DDD", "#A88CCD", "#5A9386", "#C78291", "#8295AD", "#858985"]

    var body: some View {
        SettingsSheet("New workspace") {
            Group {
                SettingsSection("Workspace", footer: "Organisation is saved for this profile. Conversations only move here when you choose them.") {
                    SettingsRow("Name") { ValueField(text: $name, mono: false) }
                    SettingsRow("Purpose", tall: true) {
                        TextField("What are you working on?", text: $purpose, axis: .vertical)
                            .textFieldStyle(.plain).hierarchyFont(H.mobile ? 15 : 12.5).lineLimit(2...4)
                    }
                    SettingsRow("Colour") {
                        HStack(spacing: 9) {
                            ForEach(colors, id: \.self) { color in
                                Button { swatch = color } label: {
                                    Circle().fill(H.swatch(color).opacity(0.65)).frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(swatch == color ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                                        .frame(minWidth: H.mobile ? 30 : 18, minHeight: H.mobile ? 44 : 22)
                                }.buttonStyle(.plain).accessibilityLabel("Workspace colour \(color)")
                                    .accessibilityAddTraits(swatch == color ? .isSelected : [])
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create") {
                if let id = model.createWorkspace(name: name, purpose: purpose, swatch: swatch, sessionID: sessionID) {
                    dismiss()
                    if sessionID == nil, let parent = startedFromHome {
                        Task { await model.newConversation(in: id, startedFrom: parent); onNavigate(.workspace(id)) }
                    } else { onNavigate(.workspace(id)) }
                }
            }.buttonStyle(.borderedProminent).tint(TalariaStyle.prominentAccent)
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
