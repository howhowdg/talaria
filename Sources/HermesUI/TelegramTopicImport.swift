import SwiftUI
import HermesCore

struct TelegramTopicImportButton: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label("Import from Telegram…", systemImage: "bubble.left.and.bubble.right")
        }
        .buttonStyle(HierarchyCapsuleStyle())
        .disabled(!model.isConnected)
        .sheet(isPresented: $showing) { TelegramTopicImportSheet(model: model, onNavigate: onNavigate) }
    }
}

struct TelegramTopicImportSheet: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var home: TelegramTopicIdentity?
    @State private var selected = Set<TelegramTopicIdentity>()
    @State private var importing = false

    var body: some View {
        SettingsSheet("Import from Telegram", width: 540) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose a topic for Home and the topics to add as Workspaces. Each Workspace opens its Telegram conversation.")
                    .hierarchyFont(H.body).foregroundStyle(.secondary)
                if model.isLoadingTelegramTopics { ProgressView("Reading Telegram topics…") }
                else if let error = model.telegramTopicsError { HierarchyNotice(text: error, isError: true) }
                else if model.telegramTopics.isEmpty {
                    Text("Hermes hasn't recorded any Telegram topics for this profile.").hierarchyFont(H.body)
                } else {
                    Picker("Home", selection: $home) {
                        Text("Keep current Home").tag(nil as TelegramTopicIdentity?)
                        ForEach(model.telegramTopics) { topic in
                            Text("\(topic.displayLabel) · \(topic.groupName)").tag(Optional(topic.id))
                        }
                    }.hierarchyFont(H.body)
                    HStack {
                        Text("Workspaces").hierarchyFont(H.body, .semibold)
                        Spacer()
                        Button("Select all") { selected = Set(model.telegramTopics.map(\.id)) }
                        Button("Clear") { selected = [] }
                    }.buttonStyle(.plain).hierarchyFont(H.meta).foregroundStyle(TalariaStyle.accent)
                    ForEach(model.telegramTopics) { topic in
                        Toggle(isOn: Binding(get: { selected.contains(topic.id) && home != topic.id }, set: {
                            if $0 { selected.insert(topic.id) } else { selected.remove(topic.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(topic.displayLabel).hierarchyFont(H.body, .medium)
                                Text(home == topic.id ? "Home · \(topic.groupName)" : topic.groupName)
                                    .hierarchyFont(H.meta).foregroundStyle(.secondary)
                                if let session = model.sessions.first(where: { $0.id == topic.currentSessionID }),
                                   session.displayTitle != topic.displayLabel {
                                    Text("Conversation: \(session.displayTitle)")
                                        .hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .disabled(home == topic.id)
                        .toggleStyle(.switch)
                        Hairline()
                    }
                    Text("Topic names are shown when Hermes has saved them. Otherwise, the Telegram topic number is used. You can rename Workspaces later.")
                        .hierarchyFont(H.meta).foregroundStyle(.secondary)
                    Text("Organisation is stored on this device. Importing does not send messages to Telegram.")
                        .hierarchyFont(H.meta).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Button("Refresh") { Task { await model.refreshTelegramTopics() } }
                .disabled(importing || model.isLoadingTelegramTopics)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Import") {
                importing = true
                Task {
                    var workspaces = selected
                    if let home { workspaces.remove(home) }
                    if await model.importTelegramTopics(home: home, asWorkspaces: workspaces) {
                        dismiss(); onNavigate(home == nil ? .workspaces : .home)
                    }
                    importing = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(importing || model.isLoadingTelegramTopics || model.telegramTopicsError != nil || (home == nil && selected.isEmpty))
        }
        .task {
            await model.refreshTelegramTopics()
            // Opening this review does not classify anything. Import is explicit.
            selected = Set(model.telegramTopics.map(\.id))
        }
        #if os(macOS)
        .frame(height: 600)
        #endif
    }
}
