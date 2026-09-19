import SwiftUI
import HermesCore

struct HierarchyActivity: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var reviewing: MobilePendingInput?
    @State private var answering: String?
    private var requests: [MobilePendingInput] { model.mobilePendingInputs }
    private var updates: [MobileRun] { model.runs.filter { !$0.isActive && $0.status.isTerminal } }

    var body: some View {
        VStack(alignment: .leading, spacing: H.mobile ? 20 : 22) {
            if H.mobile { Text("Activity").hierarchyFont(28, .bold).tracking(-0.4) }
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HierarchySectionLabel(title: "Needs you", attention: true)
                    ForEach(requests) { request in requestRow(request) }
                }
            }
            if !updates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HierarchySectionLabel(title: "Updates")
                    ForEach(updates) { run in updateRow(run) }
                }
            }
            if requests.isEmpty && updates.isEmpty && !model.isLoadingMobileActivity {
                HierarchyEmptyState(title: "All caught up", detail: "Nothing needs you.", symbol: "checkmark.circle")
            }
        }
        .sheet(item: $reviewing) { request in
            HierarchyRequestSheet(model: model, request: request, onNavigate: onNavigate)
        }
    }

    private func requestRow(_ request: MobilePendingInput) -> some View {
        VStack(alignment: .leading, spacing: H.mobile ? 12 : 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(request.input.method == "clarify" ? "?" : "!")
                    .hierarchyFont(H.mobile ? 18 : 14, .bold).foregroundStyle(TalariaStyle.attention)
                    .frame(width: H.mobile ? 34 : 26, height: H.mobile ? 34 : 26)
                    .background(TalariaStyle.attentionTint, in: RoundedRectangle(cornerRadius: H.mobile ? 10 : 8))
                Button { openOrigin(request) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.input.params["description"]?.stringValue ?? (request.input.method == "approval" ? "Allow a command?" : "Hermes needs your answer"))
                            .hierarchyFont(H.mobile ? 15 : 12.5, .semibold).lineLimit(3)
                        Text(origin(request)).hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !H.mobile {
                    if offersOnce(request) { allowOnce(request) }
                    Button(request.input.method == "approval" ? "Review" : "Answer ›") { reviewing = request }
                        .buttonStyle(HierarchyCapsuleStyle())
                }
            }
            if H.mobile, let command = request.input.params["command"]?.stringValue, !command.isEmpty {
                Text(command).hierarchyFont(13).monospaced().lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            if H.mobile {
                HStack {
                    if offersOnce(request) { allowOnce(request) }
                    Button(request.input.method == "approval" ? "Review choices" : "Answer ›") { reviewing = request }
                        .buttonStyle(HierarchyCapsuleStyle(prominent: !offersOnce(request)))
                }
            }
        }
        .padding(H.mobile ? 14 : 14).hierarchyCard(opacity: H.mobile ? 0.85 : 0.8)
    }

    private func origin(_ request: MobilePendingInput) -> String {
        guard let id = request.sessionID else { return request.title }
        if id == model.homeSessionID { return "Home" }
        if let workspace = model.workspaces.first(where: { $0.sessionIDs.contains(id) }) {
            return workspace.name == request.title ? workspace.name : workspace.name + " › " + request.title
        }
        if let run = model.runs.first(where: { $0.sessionID == id }),
           let automation = model.automations.first(where: { $0.id == run.automationID }) {
            return automation.name + " › " + HierarchyRunPresentation.title(run)
        }
        return request.title
    }

    private func openOrigin(_ request: MobilePendingInput) {
        guard request.sessionID != nil else { reviewing = request; return }
        Task { await model.openActivityInput(request); onNavigate(model.hierarchyDestination) }
    }

    private func offersOnce(_ request: MobilePendingInput) -> Bool {
        guard request.input.method == "approval" else { return false }
        // Only expose this shortcut when the host explicitly supplied it.
        return request.input.params["choices"]?.arrayValue?.compactMap(\.stringValue).contains("once") == true
    }

    private func allowOnce(_ request: MobilePendingInput) -> some View {
        Button("Allow once") {
            answering = request.id
            Task { _ = await model.answer(request.input, result: .object(["choice": .string("once")])); answering = nil }
        }.buttonStyle(HierarchyCapsuleStyle(prominent: true)).disabled(answering != nil || !model.isConnected)
    }

    private func updateRow(_ run: MobileRun) -> some View {
        let status = model.runDetails[run.id]?.status ?? run.status
        let unread = model.isRunUnread(run)
        let name = model.automations.first { $0.id == run.automationID }?.name ?? run.title
        return HStack(alignment: .top, spacing: 10) {
            Button { onNavigate(.run(run.id)) } label: {
                HStack(alignment: .top, spacing: 10) {
                Image(systemName: status == .failed ? "xmark" : "clock")
                    .hierarchyFont(H.mobile ? 16 : 13).foregroundStyle(status == .failed ? .red : .secondary)
                    .frame(width: H.mobile ? 34 : 26, height: H.mobile ? 34 : 26)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: H.mobile ? 10 : 8))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(name + (status == .failed ? " failed" : " ran"))
                            .hierarchyFont(H.mobile ? 15 : 12.5, .semibold).lineLimit(1)
                        if unread { Circle().fill(TalariaStyle.prominentAccent).frame(width: H.mobile ? 7 : 6, height: H.mobile ? 7 : 6).accessibilityLabel("Unread") }
                    }
                    Text(run.summary.isEmpty ? status.rawValue : HierarchyRunPresentation.preview(run.summary))
                        .hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 3) {
                if let date = run.startedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day()).hierarchyFont(H.meta).foregroundStyle(.secondary)
                }
                if status == .failed {
                    Button("Retry") { Task { await model.rerunAutomation(run.automationID) } }
                        .buttonStyle(.plain).hierarchyFont(H.meta, .semibold).foregroundStyle(TalariaStyle.accent)
                        .frame(minHeight: H.mobile ? 44 : 24)
                        .disabled(!model.isConnected || model.automations.first(where: { $0.id == run.automationID })?.enabled != true || model.automationActionIDs.contains(run.automationID))
                        .help("Enable this automation before running it.")
                } else {
                    Button("Read ›") { onNavigate(.run(run.id)) }
                        .buttonStyle(.plain).hierarchyFont(H.meta, .semibold).foregroundStyle(TalariaStyle.accent)
                        .frame(minHeight: H.mobile ? 44 : 24)
                }
            }
        }.padding(14).hierarchyCard(opacity: unread ? 0.65 : 0.45)
    }
}

private struct HierarchyRequestSheet: View {
    @Bindable var model: HermesAppModel
    let request: MobilePendingInput
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsSheet("Needs you", width: 560) {
            Group {
                InputRequestView(input: request.input) { result in
                    let answered = await model.answer(request.input, result: result)
                    if answered { dismiss() }
                    return answered
                }
            }
        } footer: {
            if let id = request.sessionID {
                Button("Open conversation") { dismiss(); onNavigate(.conversation(id)) }.buttonStyle(.plain)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }
}

struct HierarchyDiscussSheet: View {
    @Bindable var model: HermesAppModel
    let run: MobileRun
    let detail: AutomationRunDetail
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: HierarchyDestination = .home
    @State private var includeResult = true
    @State private var includeBacklink = true
    @State private var includeSources = false
    @State private var includeExecution = false
    @State private var preparing = false
    @State private var newConversation = false
    private var sources: [InspectorSource] { InspectorSnapshot(input: InspectorInput(messages: detail.messages)).sources }

    private var buttonTitle: String {
        if newConversation { return "Start conversation" }
        if case .workspace(let id) = destination,
           let workspace = model.workspaces.first(where: { $0.id == id }) { return "Open in \(workspace.name)" }
        return "Open in Home"
    }
    private var cannotPrepare: Bool {
        preparing || !model.isConnected || (!includeResult && !includeBacklink && !includeSources && !includeExecution)
            || (!newConversation && destination == .home && model.homeSessionID == nil)
    }

    var body: some View {
        Group {
            #if os(iOS)
            mobileSheet
            #else
            desktopSheet
            #endif
        }
        .onAppear { if model.homeSessionID == nil { newConversation = true } }
    }

    private var desktopSheet: some View {
        SettingsSheet("Discuss this result", width: 440) {
            discussionSections
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(buttonTitle) { prepare() }
                .buttonStyle(.borderedProminent).tint(TalariaStyle.prominentAccent).keyboardShortcut(.defaultAction)
                .disabled(cannotPrepare)
        }
    }

    #if os(iOS)
    private var mobileSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.iosFont(16).foregroundStyle(TalariaStyle.accent)
                Spacer()
                Text("Discuss this result").iosFont(17, .semibold)
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }.padding(.horizontal, 16).frame(height: 56).padding(.top, 10)
            SettingsPage { discussionSections }
            Button(action: prepare) {
                Text(buttonTitle).iosFont(17, .semibold).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(minHeight: 50)
                    .background(TalariaStyle.prominentAccent, in: Capsule())
            }.buttonStyle(.plain).disabled(cannotPrepare).opacity(cannotPrepare ? 0.45 : 1)
                .padding(.horizontal, 16).padding(.bottom, 18)
        }
        .background(TalariaStyle.solidControlSurface)
        .presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(30)
    }
    #endif

    private var discussionSections: some View {
        Group {
            SettingsSection("WHERE") {
                destinationRow("Home", selected: !newConversation && destination == .home) {
                    destination = .home; newConversation = false
                }.disabled(model.homeSessionID == nil || model.homeAvailability == .unavailable)
                ForEach(model.workspaces.filter { !$0.isArchived && !$0.sessionIDs.isEmpty }) { workspace in
                    destinationRow(workspace.name, selected: !newConversation && destination == .workspace(workspace.id)) {
                        destination = .workspace(workspace.id); newConversation = false
                    }
                }
                destinationRow("New conversation", selected: newConversation) { newConversation = true }
            }
            SettingsSection("WHAT \((model.endpoint?.name ?? "Hermes").uppercased()) WILL SEE", footer: "Only the selected context is added to the destination's draft. Review it there, then send when you're ready.") {
                checkboxRow("The result", value: $includeResult)
                checkboxRow("Link back to this run", value: $includeBacklink)
                checkboxRow("Sources it read", value: $includeSources, detail: "\(sources.count)").disabled(sources.isEmpty)
                checkboxRow("Execution transcript", value: $includeExecution, detail: "\(detail.toolCallCount) tool calls")
                    .disabled(!detail.executionAvailable)
            }
        }
    }

    private func destinationRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: H.mobile ? 12 : 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .hierarchyFont(H.mobile ? 22 : 14)
                    .foregroundStyle(selected ? TalariaStyle.accent : .secondary)
                Text(title).hierarchyFont(H.mobile ? 16 : 13).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: H.mobile ? 48 : 34).contentShape(Rectangle())
            .background(selected ? TalariaStyle.accentTint.opacity(0.4) : .clear)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func checkboxRow(_ title: String, value: Binding<Bool>, detail: String? = nil) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: H.mobile ? 12 : 10) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .hierarchyFont(H.mobile ? 22 : 14)
                    .foregroundStyle(value.wrappedValue ? TalariaStyle.prominentAccent : .secondary)
                Text(title).hierarchyFont(H.mobile ? 16 : 13)
                Spacer(minLength: 0)
                if let detail { Text(detail).hierarchyFont(H.meta).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).frame(minHeight: H.mobile ? 48 : 34).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(value.wrappedValue ? "Selected" : "Not selected")
    }

    private func prepare() {
        preparing = true
        Task {
            var target = destination
            let targetID: StoredSessionID
            if newConversation {
                guard let id = await model.createConversationForDiscussion() else { preparing = false; return }
                target = .conversation(id); targetID = id
            } else {
                switch destination {
                case .home:
                    guard let id = model.homeSessionID else { preparing = false; return }
                    targetID = id
                case .workspace(let id):
                    guard let id = model.workspace(id: id)?.sessionIDs.first else { preparing = false; return }
                    targetID = id
                case .conversation(let id): targetID = id
                default: preparing = false; return
                }
            }
            var result = includeResult ? detail.result : ""
            if includeSources {
                let sourceText = sources.map { "- [\($0.title)](\($0.url.absoluteString))" }.joined(separator: "\n")
                result += (result.isEmpty ? "" : "\n\n") + "Sources\n" + sourceText
            }
            if includeExecution {
                let transcript = detail.messages.map {
                    [$0.role.rawValue.uppercased(), $0.toolName, $0.toolInput, $0.text].compactMap { $0 }.joined(separator: "\n")
                }.joined(separator: "\n\n")
                result += (result.isEmpty ? "" : "\n\n") + "Execution transcript\n" + transcript
            }
            let staged = await model.stageResultDiscussion(result: result, runID: run.id, destination: targetID,
                                                          includeResult: includeResult || includeSources || includeExecution,
                                                          includeBacklink: includeBacklink)
            preparing = false
            if staged { dismiss(); onNavigate(target) }
        }
    }
}
