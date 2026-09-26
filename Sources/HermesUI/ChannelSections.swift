import SwiftUI
import HermesCore

struct ChannelSections: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var renaming: SessionSummary?
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pinnedChannelSessions.isEmpty {
                HierarchySectionLabel(title: "Pinned")
                ForEach(model.pinnedChannelSessions) { row($0) }
            }
            ForEach(model.channelGroups, id: \.source) { group in
                Button { model.toggleChannelCollapsed(group.source) } label: {
                    HStack {
                        Label(group.label, systemImage: group.symbol)
                        Spacer()
                        Image(systemName: model.isChannelCollapsed(group.source) ? "chevron.right" : "chevron.down")
                    }.hierarchyFont(H.mobile ? 15 : 11, .semibold)
                        .frame(minHeight: H.mobile ? 44 : 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(group.label), \(model.isChannelCollapsed(group.source) ? "collapsed" : "expanded")")
                if !model.isChannelCollapsed(group.source) {
                    ForEach(group.sessions) { row($0) }
                    if group.hasMore {
                        Button("Show more") { Task { await model.loadMoreChannels(source: group.source) } }
                            .buttonStyle(.plain).hierarchyFont(H.meta).disabled(model.isLoadingChannels)
                            .frame(minHeight: H.mobile ? 44 : 26)
                    }
                }
            }
            if model.channelDiscoveryHasMore {
                Button("More channels") { Task { await model.loadMoreChannelSources() } }
                    .buttonStyle(.plain).hierarchyFont(H.meta).disabled(model.isLoadingChannels || !model.isConnected)
                    .frame(minHeight: H.mobile ? 44 : 26)
            }
            if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Search channel history") { Task { await model.searchChannelHistory() } }
                    .buttonStyle(.plain).hierarchyFont(H.meta).disabled(model.isSearchingChannels || !model.isConnected)
                    .frame(minHeight: H.mobile ? 44 : 26)
                ForEach(model.channelSearchResults) { row($0) }
                if let error = model.channelSearchError { HierarchyNotice(text: error, isError: true) }
            }
            if model.isLoadingChannels || model.isSearchingChannels { ProgressView().controlSize(.small) }
            if let error = model.channelError {
                HierarchyNotice(text: error, isError: true)
                Button("Retry") { Task { await model.refreshChannels() } }.buttonStyle(.plain)
            }
        }
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let session = renaming { Task { await model.renameChannel(id: session.id, title: title) } }
                renaming = nil
            }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        Button { onNavigate(.conversation(session.id)) } label: {
            HStack(spacing: 7) {
                Image(systemName: session.channelSymbol).foregroundStyle(.secondary)
                Text(session.displayTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if model.isChannelUnread(session) {
                    Circle().fill(TalariaStyle.accent).frame(width: 5, height: 5).accessibilityLabel("Unread")
                }
                if let date = session.activityAt { Text(date, style: .relative).foregroundStyle(.secondary).lineLimit(1) }
            }.hierarchyFont(H.mobile ? 15 : 11)
                .frame(minHeight: H.mobile ? 44 : 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu {
                Button(model.isChannelPinned(session.id) ? "Unpin" : "Pin") { model.toggleChannelPin(session.id) }
                Button("Rename…") { title = session.title; renaming = session }
                if session.id != model.homeSessionID && model.workspace(for: session.id) == nil {
                    let archived = model.hierarchyClassification.archivedSessionIDs.contains(session.id)
                    Button(archived ? "Restore" : "Archive") { model.archiveConversation(session.id, archived: !archived) }
                }
            }
    }
}

struct ChannelHistoryControls: View {
    @Bindable var model: HermesAppModel
    @State private var showsHandoff = false
    @State private var handoffDestination: String?

    var body: some View {
        if model.isViewingChannel {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { controls }
                    VStack(alignment: .leading) { controls }
                }
                if let error = model.channelHistoryError { HierarchyNotice(text: error, isError: true) }
            }.hierarchyFont(H.meta).buttonStyle(HierarchyCapsuleStyle())
                .sheet(isPresented: $showsHandoff) {
                    SettingsSheet("Move to channel", width: 440) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transfers this conversation to the configured home channel.")
                            ForEach(model.channelHandoffDestinations) { destination in
                                Button { handoffDestination = destination.id } label: {
                                    HStack {
                                        Image(systemName: handoffDestination == destination.id ? "largecircle.fill.circle" : "circle")
                                        Text(destination.label)
                                        Spacer()
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!destination.isAvailable || model.isLoadingChannelHandoff)
                            }
                            if model.channelHandoffDestinations.isEmpty && !model.isLoadingChannelHandoff {
                                Text("No configured home channels").foregroundStyle(.secondary)
                            }
                            if model.isLoadingChannelHandoff { ProgressView() }
                            if let status = model.channelHandoffStatus { Text(status).foregroundStyle(.secondary) }
                        }
                        .task { await model.loadChannelHandoffDestinations() }
                    } footer: {
                        Button("Cancel", role: .cancel) { showsHandoff = false }
                        Spacer()
                        Button("Transfer") {
                            if let destination = handoffDestination {
                                Task { await model.handoffChannel(to: destination); showsHandoff = false }
                            }
                        }.disabled(!canHandoff || !model.channelHandoffDestinations.contains { $0.id == handoffDestination && $0.isAvailable })
                    }
                }
        }
    }

    private var canHandoff: Bool {
        let status = model.channelHandoffStatus ?? ""
        return !model.isPassiveChannel && model.isConnected && model.conversation?.isRunning != true
            && !model.isSubmitting && !model.isLoadingChannelHandoff
            && !["pending", "running"].contains(status.lowercased()) && !status.hasPrefix("Transfer status unavailable")
    }

    @ViewBuilder private var controls: some View {
        if model.channelHistoryHasMore {
            Button("Load older") { Task { await model.loadOlderChannelMessages() } }
                .disabled(model.isLoadingChannelHistory || !model.isConnected)
        }
        Button("Refresh") { Task { await model.refreshChannelHistory() } }
            .disabled(model.isLoadingChannelHistory || !model.isConnected)
        if model.isPassiveChannel {
            Button("Continue in Talaria") { Task { await model.continueChannelInTalaria() } }
                .disabled(model.isLoadingChannelHistory || !model.isConnected)
        }
        if !model.isPassiveChannel {
            Button("Move to channel…") { handoffDestination = nil; showsHandoff = true }.disabled(!canHandoff)
        }
        if let status = model.channelHandoffStatus { Text(status).foregroundStyle(.secondary) }
        if model.isLoadingChannelHistory { ProgressView().controlSize(.small) }
    }
}
