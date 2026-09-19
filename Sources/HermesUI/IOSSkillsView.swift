#if os(iOS)
import SwiftUI
import HermesCore

/// Installed skills reported by Hermes. Management remains on the host.
struct IOSSkillsView: View {
    @Bindable var model: HermesAppModel
    var topInset: CGFloat = 118
    var bottomInset: CGFloat = 90
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Skills").iosFont(28, .bold, relativeTo: .title).tracking(-0.4)
                    .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
                searchField
                if model.isLoadingMobileActivity && model.mobileActivity.skills.isEmpty {
                    ProgressView("Loading skills…").iosFont(15)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if skills.isEmpty {
                    emptyState
                } else {
                    Text("Installed on \(model.endpoint?.name ?? "Hermes")")
                        .iosFont(13, .semibold, relativeTo: .footnote)
                        .foregroundStyle(.secondary).padding(.horizontal, 4)
                    ForEach(skills) { skill in skillRow(skill) }
                }
                if let error = model.mobileActivityError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .iosFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .iosCard(radius: 18, opacity: 0.55)
                }
                ForEach(Array(model.mobileActivity.notices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "info.circle")
                        .iosFont(13, relativeTo: .footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .iosCard(radius: 18, opacity: 0.55)
                }
            }
            .padding(.horizontal, 16).padding(.top, topInset).padding(.bottom, bottomInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refreshMobileActivity() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").iosFont(16).foregroundStyle(.secondary)
            TextField("Search skills", text: $query).iosFont(16)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 44)
        .iosCard(radius: 22, opacity: 0.55)
    }

    private func skillRow(_ skill: MobileSkill) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles").iosFont(20)
                .foregroundStyle(TalariaStyle.accent).frame(width: 44, height: 44)
                .background(TalariaStyle.accentTint, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name).iosFont(16, .medium)
                    .fixedSize(horizontal: false, vertical: true)
                if !skill.category.isEmpty {
                    Text(skill.category).iosFont(14).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .iosCard(radius: 18, opacity: 0.55)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(query.isEmpty ? "Skills extend Hermes" : "No matching skills")
                .iosFont(17, .semibold)
            Text(query.isEmpty
                 ? (model.isConnected ? "Skills installed on your Hermes host will appear here."
                    : "Connect to your Mac to see its installed skills.")
                 : "Try another name or category.")
                .iosFont(15).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isConnected {
                Button("Connect to Hermes") { model.showConnection = true }
                    .talariaProminentButton()
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .iosCard(radius: 18, opacity: 0.55)
    }

    private var skills: [MobileSkill] {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.mobileActivity.skills.filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
                || $0.category.localizedCaseInsensitiveContains(filter)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
