import SwiftUI
import HermesCore

public struct SessionSettingsViewState: Equatable, Sendable {
    public let snapshot: GatewaySettingsSnapshot?
    public let profile: String
    public let sessionID: String?
    public let workingDirectory: String?
    public let isLoading: Bool
    public let isApplying: Bool
    public let errorMessage: String?
    public init(snapshot: GatewaySettingsSnapshot? = nil, profile: String, sessionID: String? = nil,
                isLoading: Bool = false, isApplying: Bool = false, errorMessage: String? = nil, workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
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
    @State private var browsingModels = false

    public init(state: SessionSettingsViewState,
                onRefresh: @escaping @MainActor () async -> Void,
                onSelectModel: @escaping @MainActor (GatewayModelSelection, Bool) async -> GatewaySettingChange?,
                onSelectProfile: @escaping @MainActor (String) async -> Bool) {
        self.state = state; self.onRefresh = onRefresh; self.onSelectModel = onSelectModel
        self.onSelectProfile = onSelectProfile
    }

    public var body: some View {
        Group {
            #if os(macOS)
            macSettings
            #else
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
            #endif
        }
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

    #if os(macOS)
    private var macSettings: some View {
        SettingsSheet("Conversation settings", content: {
            if state.isLoading { ProgressView("Loading settings…").font(T.f(12)) }
            if let error = state.errorMessage { Text(error).font(T.f(11.5)).foregroundStyle(T.failed) }
            if let notice { Text(notice).font(T.f(11.5)).foregroundStyle(T.ink2) }
            if let snapshot = state.snapshot {
                SettingsSection("Model", footer: state.sessionID == nil
                    ? "Open a conversation to choose its model. Changes apply to that conversation only."
                    : "Pick a listed model or type a model ID this provider accepts. Changes apply to this conversation only — finish or stop the current run first.") {
                    SettingsRow("Provider") {
                        Picker("Provider", selection: Binding(get: { provider }, set: { newValue in
                            provider = newValue
                            if let row = snapshot.models.providers.first(where: { $0.slug == newValue }) {
                                model = row.matches(snapshot.models.provider) ? snapshot.models.model
                                    : row.models.first(where: { !row.unavailableModels.contains($0) }) ?? ""
                            }
                            reasoning = ""
                        })) {
                            if provider.isEmpty { Text("Choose a provider").tag("") }
                            ForEach(snapshot.models.providers) { Text($0.name).tag($0.slug) }
                        }.pickerStyle(.menu).controlSize(.small)
                    }
                    SettingsRow("Model") {
                        ValueField(text: $model, action: ("Browse", "list.bullet", { browsingModels = true }))
                            .frame(maxWidth: 280)
                            .popover(isPresented: $browsingModels) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(selectedProvider?.models ?? [], id: \.self) { item in
                                            Button(item) { model = item; reasoning = ""; browsingModels = false }
                                                .buttonStyle(.plain).font(T.f(12.5)).padding(.vertical, 4)
                                                .disabled(selectedProvider?.unavailableModels.contains(item) == true)
                                        }
                                    }.padding(14)
                                }.frame(width: 320, height: 300)
                            }
                    }
                    if let capabilities = selectedProvider?.capabilities[model], capabilities.reasoning {
                        SettingsRow("Reasoning") {
                            Picker("Reasoning", selection: $reasoning) {
                                Text("Model default").tag("")
                                ForEach(GatewayReasoningEffort.allCases.filter(capabilities.supports)) { Text($0.label).tag($0.rawValue) }
                            }.pickerStyle(.menu).controlSize(.small)
                        }
                    }
                }.disabled(busy || state.sessionID == nil || profile != state.profile)
                SettingsSection("Hermes profile", footer: "Switching changes the profile used by this connection. Your other conversations keep their own profiles.") {
                    SettingsRow("Profile") {
                        Picker("Profile", selection: $profile) {
                            if !snapshot.profiles.contains(where: { $0.name == state.profile }) { Text(state.profile).tag(state.profile) }
                            ForEach(snapshot.profiles) { Text($0.label).tag($0.name) }
                        }.pickerStyle(.menu).controlSize(.small)
                    }
                    if let cwd = state.workingDirectory, !cwd.isEmpty {
                        SettingsRow("Working directory", tall: true) {
                            Text(cwd).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(T.ink2)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }.disabled(busy)
                if let warning = selectedProvider?.warning { Text(warning).font(T.f(11.5)).foregroundStyle(T.ink2) }
                ForEach(snapshot.notices, id: \.self) { Text($0).font(T.f(11.5)).foregroundStyle(T.ink2) }
            } else if !state.isLoading {
                Text("Refresh to read settings from the connected Hermes host.").font(T.f(12)).foregroundStyle(T.ink2)
            }
        }, footer: {
            Button { Task { await refresh() } } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(T.ink2).disabled(busy)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply") { Task { await applySettings() } }
                .buttonStyle(.borderedProminent).tint(T.fill).keyboardShortcut(.defaultAction).disabled(!canApply)
        }).frame(height: 450)
    }
    private var canApply: Bool {
        guard !busy, let snapshot = state.snapshot else { return false }
        if profile != state.profile { return snapshot.profiles.contains { $0.name == profile } }
        guard state.sessionID != nil, let selectedProvider, selectedProvider.isAvailable,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedProvider.unavailableModels.contains(model) else { return false }
        return provider != snapshot.models.currentProvider?.slug || model != snapshot.models.model
            || reasoning != (snapshot.reasoningEffort ?? "")
    }
    private func applySettings() async {
        guard canApply else { return }
        if profile != state.profile {
            operationInFlight = true
            let selected = profile
            let changed = await onSelectProfile(selected)
            operationInFlight = false
            if changed { dismiss() }
        } else {
            let effort = GatewayReasoningEffort(rawValue: reasoning)
            let supported = effort.flatMap { selectedProvider?.capabilities[model]?.supports($0) == true ? $0 : nil }
            await apply(GatewayModelSelection(provider: provider, model: model.trimmingCharacters(in: .whitespacesAndNewlines), reasoningEffort: supported), confirmed: false)
        }
    }
    #endif

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
