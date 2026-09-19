import SwiftUI
import HermesCore

struct HierarchyAutomations: View {
    @Bindable var model: HermesAppModel
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if H.mobile {
                Text("Automations").hierarchyFont(28, .bold).tracking(-0.4).padding(.bottom, 6)
            }
            if model.automations.isEmpty && !model.isLoadingMobileActivity {
                HierarchyEmptyState(title: "No automations yet", detail: "Automations created in Hermes appear here with their runs and results.", symbol: "clock")
            }
            ForEach(model.automations) { automation in
                HierarchyAutomationCard(model: model, automation: automation, onNavigate: onNavigate)
            }
            if !model.automations.isEmpty {
                Text("Automations are standing instructions. Each run keeps its own result and execution transcript.")
                    .hierarchyFont(H.meta).foregroundStyle(.secondary).lineSpacing(3).padding(.top, 8)
            }
        }
    }
}

struct HierarchyAutomationCard: View {
    @Bindable var model: HermesAppModel
    let automation: MobileSchedule
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var latest: MobileRun? { model.runs.first { $0.automationID == automation.id } }

    var body: some View {
        Button { onNavigate(.automation(automation.id)) } label: {
            VStack(alignment: .leading, spacing: H.mobile ? 8 : 6) {
                HStack(spacing: 8) {
                    Image(systemName: "clock").hierarchyFont(H.mobile ? 15 : 12).foregroundStyle(.secondary)
                    Text(automation.name).hierarchyFont(H.mobile ? 16 : 13, .semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    HierarchyAutomationTag(enabled: automation.enabled)
                }
                if !automation.schedule.isEmpty {
                    Text(automation.schedule).hierarchyFont(H.mobile ? 14 : 11).foregroundStyle(.secondary)
                }
                if !automation.promptPreview.isEmpty {
                    Text(automation.promptPreview).hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(.secondary)
                        .lineLimit(2).lineSpacing(3)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let latest {
                        HierarchyRunState(status: model.runDetails[latest.id]?.status ?? latest.status, compact: true)
                        if let date = latest.startedAt { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                        if model.isRunUnread(latest) { Circle().fill(TalariaStyle.prominentAccent).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                    } else { Text("No runs loaded") }
                    Spacer(minLength: 6)
                    if !automation.enabled { Text("Won't run while paused") }
                    else if let next = automation.nextRunAt { Text("Next \(next.formatted(.dateTime.month(.abbreviated).day().hour().minute()))") }
                }.hierarchyFont(H.meta).foregroundStyle(.secondary)
            }
            .padding(H.mobile ? 16 : 14)
            .hierarchyCard(opacity: automation.enabled ? 0.65 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: H.radius))
        }.buttonStyle(.plain)
    }
}

struct HierarchyAutomationTag: View {
    let enabled: Bool
    var body: some View {
        Text(enabled ? "Enabled" : "Paused").hierarchyFont(H.mobile ? 12 : 10, .semibold)
            .foregroundStyle(enabled ? TalariaStyle.accent : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(enabled ? TalariaStyle.accentTint.opacity(0.65) : .primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct HierarchyAutomationDetail: View {
    @Bindable var model: HermesAppModel
    let automation: MobileSchedule
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var runs: [MobileRun] { model.runs.filter { $0.automationID == automation.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: H.mobile ? 18 : 20) {
            if H.mobile {
                VStack(alignment: .leading, spacing: 6) {
                    Label(automation.name, systemImage: "clock").hierarchyFont(22, .bold).tracking(-0.3)
                    Text(automation.schedule).hierarchyFont(13).foregroundStyle(.secondary)
                }
            }
            if !automation.promptPreview.isEmpty {
                Text(automation.promptPreview).hierarchyFont(H.mobile ? 14 : 12).foregroundStyle(.secondary).lineSpacing(4)
            }
            if H.mobile { HStack {
                Text("Enabled").hierarchyFont(H.mobile ? 15 : 12)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { automation.enabled }, set: { enabled in
                    Task { await model.setAutomationEnabled(automation.id, enabled: enabled) }
                })).labelsHidden().toggleStyle(.switch).controlSize(H.mobile ? .regular : .mini)
                    .disabled(!model.isConnected || model.automationActionIDs.contains(automation.id))
            }
            .padding(H.mobile ? 16 : 12).hierarchyCard(opacity: 0.6)
            HStack(spacing: 8) {
                Button("Run now") { Task { await model.rerunAutomation(automation.id) } }
                    .buttonStyle(HierarchyCapsuleStyle())
                    .disabled(!model.isConnected || !automation.enabled || model.automationActionIDs.contains(automation.id))
                if !automation.enabled { Text("Enable this automation before running it.").hierarchyFont(H.meta).foregroundStyle(.secondary) }
                // The edit action is intentionally absent until a verified host
                // endpoint can apply it; prompt text is never edited locally.
            } }
            if runs.isEmpty {
                Text("No runs loaded for this automation.").hierarchyFont(H.body).foregroundStyle(.secondary)
            } else {
                runSection("Today", today: true)
                runSection("Earlier", today: false)
            }
        }.task(id: automation.id) { await model.refreshAutomationRuns(automation.id) }
    }

    @ViewBuilder private func runSection(_ title: String, today: Bool) -> some View {
        let subset = runs.filter { run in run.startedAt.map { Calendar.current.isDateInToday($0) } == today }
        if !subset.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HierarchySectionLabel(title: title)
                ForEach(subset) { run in
                    HierarchyRunRow(model: model, run: run, onNavigate: onNavigate)
                }
            }
        }
    }
}

struct HierarchyRunState: View {
    let status: AutomationRunStatus
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            if !compact { Text(status == .noOutput ? "Nothing to report" : status.rawValue) }
        }.hierarchyFont(H.meta, status == .waitingForInput ? .semibold : .regular).foregroundStyle(color)
            .accessibilityLabel(status.rawValue)
    }
    private var symbol: String {
        switch status {
        case .working: "circle.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .waitingForInput: "exclamationmark.circle.fill"
        case .noOutput, .unavailable: "circle"
        }
    }
    private var color: Color {
        switch status {
        case .working, .completed: TalariaStyle.accent
        case .waitingForInput: TalariaStyle.attention
        case .failed: .red
        case .noOutput, .unavailable: .secondary
        }
    }
}

struct HierarchyRunRow: View {
    @Bindable var model: HermesAppModel
    let run: MobileRun
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    private var status: AutomationRunStatus { model.runDetails[run.id]?.status ?? run.status }
    var body: some View {
        Button { onNavigate(.run(run.id)) } label: {
            HStack(alignment: .top, spacing: H.mobile ? 12 : 10) {
                HierarchyRunState(status: status, compact: true).frame(width: 16).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(HierarchyRunPresentation.title(run)).hierarchyFont(H.mobile ? 15 : 12.5, .medium)
                        if model.isRunUnread(run) { Circle().fill(TalariaStyle.prominentAccent).frame(width: 6, height: 6).accessibilityLabel("Unread") }
                    }
                    Text(run.summary.isEmpty ? status.rawValue : HierarchyRunPresentation.preview(run.summary))
                        .hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if status == .noOutput { Text("No output").hierarchyFont(H.meta).foregroundStyle(.secondary) }
                else { Image(systemName: "chevron.right").hierarchyFont(H.mobile ? 12 : 9).foregroundStyle(.secondary).padding(.top, 3) }
            }
            .padding(H.mobile ? 16 : 12).hierarchyCard(opacity: model.isRunUnread(run) ? 0.7 : 0.5)
        }.buttonStyle(.plain)
    }
}

struct HierarchyRunDetail: View {
    @Bindable var model: HermesAppModel
    let run: MobileRun
    let onNavigate: @MainActor (HierarchyDestination) -> Void
    @State private var discussing = false
    private var detail: AutomationRunDetail? { model.runDetails[run.id] }
    private var automation: MobileSchedule? { model.automations.first { $0.id == run.automationID } }
    private var status: AutomationRunStatus { detail?.status ?? run.status }

    var body: some View {
        VStack(alignment: .leading, spacing: H.mobile ? 16 : 14) {
            if H.mobile {
                VStack(alignment: .leading, spacing: 5) {
                    Text(HierarchyRunPresentation.title(run)).hierarchyFont(22, .bold).tracking(-0.3)
                    HStack(spacing: 5) {
                        HierarchyRunState(status: status)
                        if let duration = HierarchyRunPresentation.duration(run) { Text("· \(duration)") }
                        if let automation { Text("· run of \(automation.name)").lineLimit(1) }
                    }.hierarchyFont(13).foregroundStyle(.secondary)
                }
            }
            resultContent
            if H.mobile, let detail, !detail.result.isEmpty, detail.status == .completed {
                Button("Discuss this result") { discussing = true }
                    .buttonStyle(HierarchyCapsuleStyle(prominent: true))
                    .frame(maxWidth: H.mobile ? .infinity : nil)
            }
            if H.mobile, let automation {
                HStack {
                    Button("Rerun") { Task { await model.rerunAutomation(automation.id) } }
                        .buttonStyle(HierarchyCapsuleStyle())
                        .disabled(!model.isConnected || !automation.enabled || model.automationActionIDs.contains(automation.id))
                    if !automation.enabled { Text("Enable this automation before running it.").hierarchyFont(H.meta).foregroundStyle(.secondary) }
                }
            }
            if let detail {
                HStack(spacing: 4) {
                    let sourceCount = InspectorSnapshot(input: InspectorInput(messages: detail.messages)).sources.count
                    if sourceCount > 0 { Text("\(sourceCount) sources ·") }
                    Text("\(detail.toolCallCount) tool \(detail.toolCallCount == 1 ? "call" : "calls")")
                    if let duration = HierarchyRunPresentation.duration(run) { Text("· \(duration)") }
                }.hierarchyFont(H.meta).foregroundStyle(.secondary)
                HierarchyExecutionDisclosure(model: model, run: run, detail: detail)
            } else if model.loadingRunIDs.contains(run.id) {
                HierarchySkeletonRows(count: 2)
            } else {
                HierarchyNotice(text: "Execution details no longer available")
                Button("Try again") { Task { await model.loadRunDetail(run.id) } }.buttonStyle(HierarchyCapsuleStyle())
            }
        }
        .task(id: run.id) { await model.observeRun(run.id) }
        #if DEBUG
        .onChange(of: detail?.runID, initial: true) { _, id in
            if ProcessInfo.processInfo.environment["TALARIA_DESIGN_PREVIEW"] == "1",
               ProcessInfo.processInfo.environment["TALARIA_DESIGN_DESTINATION"] == "discuss", id != nil {
                discussing = true
            }
        }
        #endif
        .sheet(isPresented: $discussing) {
            if let detail {
                HierarchyDiscussSheet(model: model, run: run, detail: detail, onNavigate: onNavigate)
            }
        }
    }

    @ViewBuilder private var resultContent: some View {
        if let detail, !detail.result.isEmpty, status == .completed {
            let presentation = HierarchyRunPresentation.result(detail.result)
            VStack(alignment: .leading, spacing: H.mobile ? 12 : 10) {
                if let title = presentation.title {
                    Text(HierarchyRunPresentation.preview(title)).hierarchyFont(H.mobile ? 17 : 14, .semibold)
                } else if let date = run.startedAt {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .hierarchyFont(H.mobile ? 17 : 14, .semibold)
                }
                MarkdownMessage(text: presentation.body).hierarchyFont(H.mobile ? 15 : 12.5).lineSpacing(5)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .hierarchyCard(opacity: H.mobile ? 0.85 : 0.8, radius: H.mobile ? 22 : 12)
        } else if status == .failed {
            VStack(alignment: .leading, spacing: 10) {
                Label("This run failed.", systemImage: "xmark.circle").hierarchyFont(H.body, .semibold)
                if let error = detail?.messages.last(where: { $0.isError })?.text {
                    Text(error).hierarchyFont(H.body).textSelection(.enabled)
                }
                Button("Retry") { Task { await model.rerunAutomation(run.automationID) } }
                    .buttonStyle(HierarchyCapsuleStyle()).disabled(!model.isConnected || automation?.enabled != true || model.automationActionIDs.contains(run.automationID))
                if automation?.enabled == false { Text("Enable this automation before running it.").hierarchyFont(H.meta).foregroundStyle(.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: H.radius))
        } else if status == .waitingForInput {
            ForEach(model.mobilePendingInputs.filter { $0.sessionID == run.sessionID }) { request in
                InputRequestView(input: request.input) { await model.answer(request.input, result: $0) }
            }
        } else if status == .working {
            HierarchyNotice(text: "Working. The result will appear here when this run completes.")
        } else if detail != nil {
            Text(status == .noOutput ? "Nothing to report" : "A completed result is not available for this run.")
                .hierarchyFont(H.mobile ? 15 : 12).foregroundStyle(.secondary).padding(.vertical, 16)
        }
    }
}

struct HierarchyExecutionDisclosure: View {
    @Bindable var model: HermesAppModel
    let run: MobileRun
    let detail: AutomationRunDetail
    @State private var expanded = false
    private var sources: [InspectorSource] { InspectorSnapshot(input: InspectorInput(messages: detail.messages)).sources }
    private var persistenceKey: String {
        "talaria.execution." + (model.endpoint?.id.uuidString ?? "none") + "." + (model.endpoint?.profile ?? "") + "." + run.id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                expanded.toggle(); UserDefaults.standard.set(expanded, forKey: persistenceKey)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").hierarchyFont(H.mobile ? 10 : 8)
                    Text("Execution transcript").hierarchyFont(H.mobile ? 15 : 12, .medium)
                    Text(H.mobile ? "tools · sources · instructions" : "tools, sources and the automation's instructions")
                        .hierarchyFont(H.meta).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.frame(minHeight: H.mobile ? 48 : 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                if !detail.executionAvailable {
                    Text("Execution details no longer available").hierarchyFont(H.body).foregroundStyle(.secondary)
                } else {
                    #if !os(macOS)
                    ToolActivityCard(messages: detail.messages)
                    #endif
                    if !sources.isEmpty {
                        HierarchySectionLabel(title: "Sources")
                        ForEach(sources) { source in
                            Link(destination: source.url) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.title).hierarchyFont(H.body, .medium)
                                    Text(source.url.host ?? source.url.absoluteString).hierarchyFont(H.meta).foregroundStyle(.secondary)
                                }
                            }.foregroundStyle(TalariaStyle.accent)
                        }
                    }
                    #if os(macOS)
                    macExecutionTranscript
                    #else
                    ForEach(detail.messages.filter { $0.role != .tool }) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HierarchySectionLabel(title: message.role == .user || message.role == .system ? "Instructions" : "Hermes")
                            if message.role == .assistant {
                                MarkdownMessage(text: message.text).hierarchyFont(H.mobile ? 14 : 12.5)
                            } else {
                                Text(message.text).hierarchyFont(H.mobile ? 13 : 11).monospaced()
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    #endif
                    if detail.isHistoryTruncated {
                        Text("Showing the available history page. Earlier execution details may not be included.")
                            .hierarchyFont(H.meta).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(H.mobile ? 16 : 12).hierarchyCard(opacity: H.mobile ? 0.5 : 0.4, radius: H.mobile ? 18 : 10)
            .onAppear { expanded = UserDefaults.standard.bool(forKey: persistenceKey) }
    }

    #if os(macOS)
    /// Keep system instructions in their original position without presenting
    /// them as a person speaking. Conversation chunks share the Mac renderer,
    /// including the tool cards attached to their assistant turn.
    private struct TranscriptSection: Identifiable {
        var messages: [ChatMessage]
        var id: String { messages[0].id }
        var isSystem: Bool { messages[0].role == .system }
    }

    private var transcriptSections: [TranscriptSection] {
        var sections: [TranscriptSection] = []
        for message in detail.messages {
            if let last = sections.last, last.isSystem == (message.role == .system) {
                sections[sections.count - 1].messages.append(message)
            } else {
                sections.append(TranscriptSection(messages: [message]))
            }
        }
        return sections
    }

    private var macExecutionTranscript: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(transcriptSections) { section in
                if section.isSystem {
                    ForEach(section.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HierarchySectionLabel(title: "Instructions")
                            Text(message.text).hierarchyFont(11).monospaced()
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else {
                    MacTranscriptMessages(
                        messages: section.messages,
                        assistantName: model.endpoint?.name ?? "Hermes",
                        userLabel: "INSTRUCTIONS"
                    )
                }
            }
        }
    }
    #endif
}

enum HierarchyRunPresentation {
    /// A supplied Markdown heading becomes the card's title instead of showing
    /// the same heading twice at the transcript's larger heading size. The raw
    /// result stays intact for execution and explicitly shared context.
    static func result(_ text: String) -> (title: String?, body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return (nil, text) }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        let marks = first.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), first.dropFirst(marks).first?.isWhitespace == true else { return (nil, text) }
        let title = first.dropFirst(marks).trimmingCharacters(in: .whitespaces)
        return (title, lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .newlines))
    }
    static func preview(_ markdown: String) -> String {
        // Full Markdown parsing stores paragraph/list breaks in presentation
        // metadata, not the characters. Preserve those boundaries explicitly
        // when making a single-line excerpt for rows and the inspector.
        markdown.components(separatedBy: .newlines).compactMap { line -> String? in
            var content = line.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            let marks = content.prefix { $0 == "#" }.count
            if (1...6).contains(marks), content.dropFirst(marks).first?.isWhitespace == true {
                content = content.dropFirst(marks).trimmingCharacters(in: .whitespaces)
            } else if let first = content.first, ["-", "+", "*", ">"].contains(first),
                      content.dropFirst().first?.isWhitespace == true {
                content = content.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            guard let attributed = try? AttributedString(markdown: content, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return content }
            return String(attributed.characters)
        }.joined(separator: " ")
    }
    static func title(_ run: MobileRun) -> String {
        guard let date = run.startedAt else { return "Run" }
        let day = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.month(.abbreviated).day())
        return day + " · " + date.formatted(.dateTime.hour().minute())
    }
    static func duration(_ run: MobileRun) -> String? {
        guard let start = run.startedAt, let end = run.endedAt, end >= start else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
