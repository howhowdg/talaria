#if os(iOS)
import SwiftUI
import HermesCore

/// Screen 1b. Only stored IDs cross the navigation boundary; running state and
/// folder membership come from conversations hydrated for this connection.
struct IOSSessionsView: View {
    @Bindable var model: HermesAppModel
    let onOpen: @MainActor (StoredSessionID) -> Void
    let onNew: @MainActor () -> Void
    var topInset: CGFloat = 66
    var bottomInset: CGFloat = 90
    @State private var expandedFolders = Set<String>()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("Sessions")
                    .iosFont(28, .bold, relativeTo: .title)
                    .tracking(-0.4)
                    .padding(.horizontal, 4).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                searchField.padding(.bottom, 12)
                if sessionItems.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.title) { group in
                        sectionLabel(group.title)
                        ForEach(group.items) { item in
                            IOSSessionRow(model: model, item: item, onOpen: onOpen)
                        }
                    }
                }
                if !folders.isEmpty {
                    sectionLabel("Folders").padding(.top, 8)
                    ForEach(folders, id: \.self) { path in
                        folderRow(path)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset + 80)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refreshSessions() }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                IOSWorkspaceNotice(text: banner) { model.banner = nil }
                    .padding(.horizontal, 16).padding(.top, topInset)
            }
        }
        .overlay(alignment: .bottom) {
            connectionCard
                .padding(.horizontal, 16)
                .padding(.bottom, bottomInset)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").iosFont(16)
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText)
                .iosFont(16).autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search sessions")
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 44)
        .iosCard(radius: 22, opacity: 0.55)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.searchText.isEmpty ? "A place for your conversations" : "No matching sessions")
                .iosFont(17, .semibold)
            Text(model.searchText.isEmpty
                 ? (model.isConnected ? "Start a conversation with Hermes. Your sessions will appear here."
                    : "Connect to Hermes on your Mac to see your sessions.")
                 : "Try a different title or a word from the conversation.")
                .iosFont(15).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.searchText.isEmpty {
                Button(model.isConnected ? "New conversation" : "Connect to Hermes") {
                    if model.isConnected { onNew() } else { model.showConnection = true }
                }
                .talariaProminentButton()
                .disabled(model.isConnecting || model.isLoadingSession)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .iosCard(radius: 18, opacity: 0.55)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).iosFont(13, .semibold, relativeTo: .footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func folderRow(_ path: String) -> some View {
        let expanded = expandedFolders.contains(path)
        let items = sessionItems.filter { $0.state?.cwd == path }
        return VStack(spacing: 2) {
            Button {
                if expanded { expandedFolders.remove(path) } else { expandedFolders.insert(path) }
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(TalariaStyle.prominentAccent.opacity(0.45))
                        .frame(width: 18, height: 14)
                    Text(folderName(path)).iosFont(16).lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .iosFont(12, .semibold).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(folderName(path)), \(items.count) loaded sessions")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(path)
            if expanded {
                Text(path).iosFont(12, relativeTo: .caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).textSelection(.enabled)
                ForEach(items) { item in
                    IOSSessionRow(model: model, item: item, onOpen: onOpen)
                        .padding(.leading, 12)
                }
            }
        }
    }

    private var connectionCard: some View {
        Button { model.showConnection = true } label: {
            HStack(spacing: 10) {
                Circle().fill(model.isConnected ? TalariaStyle.prominentAccent : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connectionTitle).iosFont(14, .semibold).lineLimit(1)
                    Text(connectionSubtitle).iosFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .iosFont(12).foregroundStyle(.secondary)
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .talariaGlass(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens gateway connection settings")
    }

    private var connectionTitle: String {
        guard let endpoint = model.endpoint ?? model.savedEndpoint else { return "Connect to Hermes" }
        return "\(endpoint.profile == "default" ? "Personal" : endpoint.profile) · \(endpoint.name)"
    }

    private var connectionSubtitle: String {
        let status = model.isConnecting ? "Connecting…" : model.isConnected ? "Connected" : "Disconnected"
        guard let host = (model.endpoint ?? model.savedEndpoint)?.baseURL.host else { return "Your Mac, wherever you are" }
        return "\(status) · \(host)"
    }

    private var owner: SessionOwner? {
        model.endpoint.map { SessionOwner(connectionID: $0.id, profile: $0.profile) }
    }

    private var sessionItems: [IOSSessionItem] {
        var items = model.sessions.map { session in
            let state = model.conversations[session.id].flatMap { $0.owner == owner ? $0 : nil }
            return IOSSessionItem(id: session.id, title: state?.title ?? session.displayTitle,
                                  preview: session.preview, startedAt: session.startedAt, state: state)
        }
        let storedIDs = Set(items.map(\.id))
        for state in model.conversations.values where state.owner == owner && !storedIDs.contains(state.storedID) {
            items.append(IOSSessionItem(id: state.storedID, title: state.title, preview: "",
                                        startedAt: nil, state: state))
        }
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.preview.localizedCaseInsensitiveContains(query) }
    }

    private var groups: [IOSSessionGroup] {
        let calendar = Calendar.current
        return ["Today", "Yesterday", "Earlier", "Conversations"].compactMap { title in
            let items = sessionItems.filter { item in
                guard let date = item.startedAt else { return title == "Conversations" }
                if calendar.isDateInToday(date) { return title == "Today" }
                if calendar.isDateInYesterday(date) { return title == "Yesterday" }
                return title == "Earlier"
            }
            return items.isEmpty ? nil : IOSSessionGroup(title: title, items: items)
        }
    }

    private var folders: [String] {
        Array(Set(sessionItems.compactMap { $0.state?.cwd }.filter { !$0.isEmpty })).sorted()
    }

    private func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

private struct IOSSessionGroup {
    let title: String
    let items: [IOSSessionItem]
}

private struct IOSSessionItem: Identifiable {
    let id: StoredSessionID
    let title: String
    let preview: String
    let startedAt: Date?
    let state: ConversationState?
}

private struct IOSSessionRow: View {
    @Bindable var model: HermesAppModel
    let item: IOSSessionItem
    let onOpen: @MainActor (StoredSessionID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isSelected: Bool { model.selectedID == item.id }
    private var pending: PendingInput? { item.state?.pendingInputs.first }
    private var subtitle: String {
        if pending != nil { return pending?.method == "approval" ? "Waiting for your approval" : "Waiting for your answer" }
        if let state = item.state, state.isRunning { return state.status }
        return item.preview
    }

    var body: some View {
        Button { onOpen(item.id) } label: {
            if isSelected {
                contents.iosCard(radius: 18, opacity: 0.75)
            } else {
                contents
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ios-session-\(item.id.rawValue)")
        .disabled(!model.isConnected || model.isLoadingSession)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.title).iosFont(16, isSelected ? .semibold : .medium)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if let pending {
                    Text(pending.method == "approval" ? "APPROVE" : "REPLY")
                        .iosFont(11, .bold, relativeTo: .caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(minHeight: 22)
                        .background(TalariaStyle.prominentAccent, in: Capsule())
                } else if item.state?.isRunning == true {
                    Circle().fill(TalariaStyle.prominentAccent).frame(width: 8, height: 8)
                        .opacity(reduceMotion ? 1 : pulse ? 1 : 0.35)
                        .onAppear {
                            guard !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                        }
                        .accessibilityLabel("Working")
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle).iosFont(14, relativeTo: .subheadline)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
#endif
