#if os(iOS)
import SwiftUI
import HermesCore

/// Scheduled-run activity and live requests, never mock results or inferred IDs.
struct IOSUpdatesView: View {
    @Bindable var model: HermesAppModel
    let onOpen: @MainActor (StoredSessionID) -> Void
    var topInset: CGFloat = 118
    var bottomInset: CGFloat = 90
    @State private var showsSchedules = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.mobilePendingInputs.isEmpty {
                    heading("Needs you")
                    ForEach(model.mobilePendingInputs) { request in
                        pendingRow(request)
                        separator
                    }
                }
                if model.isLoadingMobileActivity && model.mobileActivity.runs.isEmpty {
                    ProgressView("Checking for updates…")
                        .iosFont(15).frame(maxWidth: .infinity).padding(.vertical, 28)
                } else if groups.isEmpty && model.mobilePendingInputs.isEmpty {
                    emptyState
                }
                ForEach(groups, id: \.title) { group in
                    heading(group.title)
                    ForEach(group.runs) { run in
                        runRow(run)
                        separator
                    }
                }
                if let error = model.mobileActivityError {
                    notice(error, symbol: "exclamationmark.arrow.triangle.2.circlepath")
                }
                if !model.mobileActivity.schedules.isEmpty { scheduleList }
                ForEach(Array(model.mobileActivity.notices.enumerated()), id: \.offset) { _, text in
                    notice(text, symbol: "info.circle")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
        }
        .refreshable { await model.refreshMobileActivity() }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                IOSWorkspaceNotice(text: banner) { model.banner = nil }
                    .padding(.horizontal, 16).padding(.top, topInset)
            }
        }
        .onAppear { model.markMobileRunsSeen() }
        .onChange(of: model.mobileActivity.runs) { _, _ in model.markMobileRunsSeen() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).iosFont(28, .bold, relativeTo: .title).tracking(-0.4)
            .padding(.horizontal, 4).padding(.bottom, 18)
            .accessibilityAddTraits(.isHeader)
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
            .padding(.bottom, 18).accessibilityHidden(true)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).iosFont(20)
            .foregroundStyle(TalariaStyle.accent)
            .frame(width: 44, height: 44)
            .background(TalariaStyle.accentTint, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }

    private func runRow(_ run: MobileRun) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon(run.isActive ? "ellipsis" : "clock")
            VStack(alignment: .leading, spacing: 5) {
                Text(run.title).iosFont(17, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if !run.summary.isEmpty {
                    Text(run.summary).iosFont(15).foregroundStyle(.secondary)
                        .lineSpacing(4).lineLimit(6)
                } else {
                    Text(run.isActive ? "Hermes is working on this scheduled run."
                         : "Open the conversation to read this run’s result.")
                        .iosFont(15).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { onOpen(run.sessionID) } label: {
                    Text("Open chat").iosFont(14, .medium)
                        .foregroundStyle(TalariaStyle.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open chat for \(run.title)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4).padding(.bottom, 18)
    }

    private func pendingRow(_ pending: MobilePendingInput) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon(pending.input.method == "approval" ? "folder" : "questionmark.bubble")
            VStack(alignment: .leading, spacing: 5) {
                Text(pending.title).iosFont(17, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pendingDescription(pending.input))
                    .iosFont(15).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let sessionID = pending.sessionID {
                    Button { onOpen(sessionID) } label: {
                        Text(pending.input.method == "approval" ? "Review request" : "Reply in chat")
                            .iosFont(14, .semibold)
                    }
                    .talariaProminentButton()
                    .padding(.top, 8)
                    .disabled(!model.isConnected || model.isLoadingSession)
                    .accessibilityHint("Opens the conversation to review and answer this request")
                } else {
                    Text("This request is waiting for its conversation to load.")
                        .iosFont(12.5, relativeTo: .footnote)
                        .foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4).padding(.bottom, 18)
    }

    private func pendingDescription(_ input: PendingInput) -> String {
        switch input.method {
        case "approval":
            let description = input.params["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.flatMap { $0.isEmpty ? nil : $0 } ?? "Hermes needs your permission before continuing."
        case "clarify": return "Hermes has a question before it can continue."
        case "sudo": return "Hermes needs an administrator password on your Mac."
        default: return "Hermes needs a private response before continuing."
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updates").iosFont(28, .bold, relativeTo: .title).tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 14) {
                icon("clock")
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isConnected
                         ? (model.mobileActivityError == nil ? "No updates yet" : "Updates couldn’t load")
                         : "Keep up with Hermes")
                        .iosFont(17, .semibold)
                    Text(model.isConnected
                         ? (model.mobileActivityError == nil
                            ? "Results from scheduled runs will appear here. Pull down to check again."
                            : "Pull down to try again. Your saved conversations are still in Sessions.")
                         : "Connect to your Mac to see scheduled runs and requests that need you.")
                        .iosFont(15).foregroundStyle(.secondary).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.isConnected {
                        Button("Connect to Hermes") { model.showConnection = true }
                            .talariaProminentButton().padding(.top, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 24)
    }

    private var scheduleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showsSchedules.toggle() } label: {
                HStack {
                    Text("Schedules").iosFont(17, .semibold)
                    Text("\(model.mobileActivity.schedules.count)").iosFont(14)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showsSchedules ? "chevron.up" : "chevron.down")
                        .iosFont(12, .semibold).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityValue(showsSchedules ? "Expanded" : "Collapsed")
            if showsSchedules {
                ForEach(model.mobileActivity.schedules) { schedule in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(schedule.name).iosFont(16, .medium)
                            Spacer()
                            if !schedule.enabled {
                                Text("Paused").iosFont(12, relativeTo: .caption).foregroundStyle(.secondary)
                            }
                        }
                        if !schedule.schedule.isEmpty {
                            Text(schedule.schedule).iosFont(14).foregroundStyle(.secondary)
                        }
                        if let next = schedule.nextRunAt, schedule.enabled {
                            Text("Next: \(next.formatted(date: .abbreviated, time: .shortened))")
                                .iosFont(12.5, relativeTo: .footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .iosCard(radius: 18, opacity: 0.55)
                }
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 16)
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .iosFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .iosCard(radius: 18, opacity: 0.55).padding(.bottom, 12)
    }

    private var groups: [IOSRunGroup] {
        let calendar = Calendar.current
        let sorted = model.mobileActivity.runs.sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        return ["Today", "This morning", "Yesterday", "Earlier", "Recent runs"].compactMap { title in
            let runs = sorted.filter { run in
                guard let date = run.startedAt else { return title == "Recent runs" }
                if calendar.isDateInToday(date) {
                    return title == (calendar.component(.hour, from: date) < 12 ? "This morning" : "Today")
                }
                if calendar.isDateInYesterday(date) { return title == "Yesterday" }
                return title == "Earlier"
            }
            return runs.isEmpty ? nil : IOSRunGroup(title: title, runs: runs)
        }
    }
}

private struct IOSRunGroup {
    let title: String
    let runs: [MobileRun]
}
#endif
