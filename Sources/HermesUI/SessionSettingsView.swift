import SwiftUI
import HermesCore

public struct SessionSettingsViewState: Equatable, Sendable {
    public let snapshot: GatewaySettingsSnapshot?
    public let profile: String
    public let sessionID: String?
    public let isLoading: Bool
    public let isApplying: Bool
    public let errorMessage: String?
    public init(snapshot: GatewaySettingsSnapshot? = nil, profile: String, sessionID: String? = nil,
                isLoading: Bool = false, isApplying: Bool = false, errorMessage: String? = nil) {
        self.snapshot = snapshot; self.profile = profile; self.sessionID = sessionID
        self.isLoading = isLoading; self.isApplying = isApplying; self.errorMessage = errorMessage
    }
}

/// The owner supplies immutable connection/session state and fences the callbacks to that owner.
/// No credentials, persistence, gateway instance, or profile activation live in this sheet.
@MainActor
public struct SessionSettingsView: View {
    private let state: SessionSettingsViewState
    private let onRefresh: @MainActor () async -> Void
    private let onSelectModel: @MainActor (GatewayModelSelection, Bool) async -> GatewaySettingChange?
    private let onSelectProfile: @MainActor (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var provider = ""
    @State private var model = ""
    @State private var reasoning = ""
    @State private var profile = ""
    @State private var operationInFlight = false
    @State private var notice: String?
    @State private var confirmation: Confirmation?

    public init(state: SessionSettingsViewState,
                onRefresh: @escaping @MainActor () async -> Void,
                onSelectModel: @escaping @MainActor (GatewayModelSelection, Bool) async -> GatewaySettingChange?,
                onSelectProfile: @escaping @MainActor (String) async -> Bool) {
        self.state = state; self.onRefresh = onRefresh; self.onSelectModel = onSelectModel
        self.onSelectProfile = onSelectProfile
    }

    public var body: some View {
        NavigationStack {
            Form {
                if state.isLoading { ProgressView("Loading settings…") }
                if let error = state.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                }
                if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                if let snapshot = state.snapshot {
                    modelSection(snapshot)
                    profileSection(snapshot)
                    ForEach(snapshot.notices, id: \.self) { Text($0).font(TalariaTypography.footnote).foregroundStyle(.secondary) }
                } else if !state.isLoading {
                    ContentUnavailableView("Settings unavailable", systemImage: "slider.horizontal.3",
                                           description: Text("Refresh to read settings from the connected Hermes host."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Conversation settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .automatic) {
                    Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(busy)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 520, idealHeight: 650)
        #endif
        .onAppear { seed() }
        .onChange(of: state.snapshot) { _, _ in seed() }
        .onChange(of: state.sessionID) { _, _ in confirmation = nil; notice = nil; seed() }
        .onChange(of: state.profile) { _, _ in confirmation = nil; notice = nil; seed() }
        .alert("Confirm model selection", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { pending in
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button("Use model") {
                confirmation = nil
                guard pending.sessionID == state.sessionID, pending.profile == state.profile else { return }
                Task { await apply(pending.selection, confirmed: true) }
            }
        } message: { Text($0.message) }
    }

    @ViewBuilder private func modelSection(_ snapshot: GatewaySettingsSnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text("Current model").font(TalariaTypography.subheadline).foregroundStyle(.secondary)
                Text(snapshot.models.model.isEmpty ? "Not selected" : snapshot.models.model)
                    .font(TalariaTypography.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if state.sessionID == nil {
                Text("Open a conversation to choose its model. These controls apply to that conversation.")
                    .font(TalariaTypography.footnote).foregroundStyle(.secondary)
            }
            if snapshot.models.providers.isEmpty {
                Text("No configured providers are available. Configure a provider on the Hermes host, then refresh.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: Binding(get: { provider }, set: { newValue in
                    provider = newValue
                    if let row = snapshot.models.providers.first(where: { $0.slug == newValue }) {
                        model = row.matches(snapshot.models.provider) ? snapshot.models.model
                            : row.models.first(where: { !row.unavailableModels.contains($0) }) ?? ""
                    }
                    reasoning = ""
                })) {
                    if provider.isEmpty { Text("Choose a provider").tag("") }
                    ForEach(snapshot.models.providers) { item in
                        Text(item.name + (item.isAvailable ? "" : " — unavailable")).tag(item.slug)
                    }
                }
                if let selectedProvider {
                    if let warning = selectedProvider.warning, !warning.isEmpty {
                        Text(warning).font(TalariaTypography.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model ID").font(TalariaTypography.subheadline).foregroundStyle(.secondary)
                        TextField("Model ID", text: $model)
                            .labelsHidden()
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 44)
                            #endif
                        Menu {
                            ForEach(selectedProvider.models, id: \.self) { item in
                                Button(item) { model = item; reasoning = "" }
                                    .disabled(selectedProvider.unavailableModels.contains(item))
                            }
                        } label: {
                            Label("Browse models", systemImage: "list.bullet")
                        }
                        .talariaSecondaryButton()
                        .disabled(selectedProvider.models.isEmpty)
                    }
                    Text("Choose a listed model or enter a custom model ID for this provider.")
                        .font(TalariaTypography.footnote).foregroundStyle(.secondary)
                    if let capabilities = selectedProvider.capabilities[model], capabilities.reasoning {
                        Picker("Reasoning", selection: $reasoning) {
                            Text("Model default").tag("")
                            ForEach(GatewayReasoningEffort.allCases.filter(capabilities.supports)) { effort in
                                Text(effort.label).tag(effort.rawValue)
                            }
                        }
                    }
                    Button("Apply to conversation") {
                        let effort = GatewayReasoningEffort(rawValue: reasoning)
                        let supported = effort.flatMap { selectedProvider.capabilities[model]?.supports($0) == true ? $0 : nil }
                        let selection = GatewayModelSelection(provider: provider, model: model.trimmingCharacters(in: .whitespacesAndNewlines), reasoningEffort: supported)
                        Task { await apply(selection, confirmed: false) }
                    }
                    .talariaProminentButton()
                    .disabled(busy || state.sessionID == nil || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || !selectedProvider.isAvailable || selectedProvider.unavailableModels.contains(model))
                }
                if snapshot.models.currentCapabilities?.fast == true {
                    LabeledContent("Fast mode", value: snapshot.fastMode == "fast" ? "On" : (snapshot.fastMode == nil ? "Unknown" : "Off"))
                    Text("Fast mode is read-only for existing conversations until the host supports a safe session-only change.")
                        .font(TalariaTypography.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Model") }
        footer: { Text("Model changes affect this conversation. Finish or stop the current work before changing its model.") }
        .disabled(busy)
    }

    @ViewBuilder private func profileSection(_ snapshot: GatewaySettingsSnapshot) -> some View {
        Section {
            if snapshot.profiles.isEmpty {
                LabeledContent("Current profile", value: state.profile)
            } else {
                Picker("Profile", selection: $profile) {
                    if !snapshot.profiles.contains(where: { $0.name == state.profile }) {
                        Text(state.profile).tag(state.profile)
                    }
                    ForEach(snapshot.profiles) { item in
                        Text(item.label).tag(item.name)
                    }
                }
                if let selected = snapshot.profiles.first(where: { $0.name == profile }), !selected.description.isEmpty {
                    Text(selected.description).font(TalariaTypography.footnote).foregroundStyle(.secondary)
                }
                Button("Use profile") {
                    Task {
                        operationInFlight = true
                        defer { operationInFlight = false }
                        if await onSelectProfile(profile) { dismiss() }
                    }
                }
                .talariaSecondaryButton()
                .disabled(busy || profile == state.profile || !snapshot.profiles.contains(where: { $0.name == profile }))
            }
        } header: { Text("Hermes profile") }
        footer: { Text("Switch the profile used by this connection. Your other conversations keep their own profiles.") }
        .disabled(busy)
    }

    private var selectedProvider: GatewayProvider? { state.snapshot?.models.providers.first { $0.slug == provider } }
    private var busy: Bool { state.isLoading || state.isApplying || operationInFlight }
    private func seed() {
        guard let snapshot = state.snapshot else { profile = state.profile; return }
        provider = snapshot.models.currentProvider?.slug ?? ""
        model = snapshot.models.model
        reasoning = snapshot.reasoningEffort ?? ""
        if let effort = GatewayReasoningEffort(rawValue: reasoning), snapshot.models.currentCapabilities?.supports(effort) != true {
            reasoning = ""
        }
        profile = state.profile
    }
    private func refresh() async {
        operationInFlight = true
        defer { operationInFlight = false }
        await onRefresh()
    }
    private func apply(_ selection: GatewayModelSelection, confirmed: Bool) async {
        guard !operationInFlight else { return }
        operationInFlight = true; notice = nil
        defer { operationInFlight = false }
        let sessionID = state.sessionID, profile = state.profile
        guard let result = await onSelectModel(selection, confirmed) else { return }
        guard state.sessionID == sessionID, state.profile == profile else { return }
        if let message = result.confirmationMessage {
            confirmation = Confirmation(selection: selection, message: message, sessionID: sessionID, profile: profile)
        } else {
            notice = result.deferred ? "Model selected for the next turn." : "Conversation model updated."
            if let warning = result.warning { notice = (notice ?? "") + " " + warning }
        }
    }
    private struct Confirmation {
        let selection: GatewayModelSelection
        let message: String
        let sessionID: String?
        let profile: String
    }
}
