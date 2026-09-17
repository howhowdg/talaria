import Foundation
import HermesProtocol
import HermesTransport

public enum GatewayReasoningEffort: String, CaseIterable, Sendable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max, ultra
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "Off"
        case .xhigh: "Extra high"
        default: rawValue.capitalized
        }
    }
}

public struct GatewayModelCapabilities: Equatable, Sendable {
    public let fast: Bool
    public let reasoning: Bool
    public let canDisableReasoning: Bool?
    public init(fast: Bool, reasoning: Bool, canDisableReasoning: Bool? = nil) {
        self.fast = fast; self.reasoning = reasoning; self.canDisableReasoning = canDisableReasoning
    }
    public func supports(_ effort: GatewayReasoningEffort) -> Bool {
        reasoning && (effort != .none || canDisableReasoning == true)
    }
}

public struct GatewayProvider: Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String
    public let models: [String]
    public let aliases: [String]
    public let authenticated: Bool?
    public let warning: String?
    public let unavailableModels: Set<String>
    public let capabilities: [String: GatewayModelCapabilities]
    public var id: String { slug }
    public var isAvailable: Bool { authenticated != false }
    public func matches(_ provider: String) -> Bool {
        slug == provider || name == provider || aliases.contains(provider)
    }
    public init(slug: String, name: String, models: [String], aliases: [String] = [],
                authenticated: Bool? = nil, warning: String? = nil, unavailableModels: Set<String> = [],
                capabilities: [String: GatewayModelCapabilities] = [:]) {
        self.slug = slug; self.name = name; self.models = models; self.aliases = aliases
        self.authenticated = authenticated; self.warning = warning
        self.unavailableModels = unavailableModels; self.capabilities = capabilities
    }
}

public struct GatewayModelOptions: Equatable, Sendable {
    public let providers: [GatewayProvider]
    public let model: String
    public let provider: String
    public var currentProvider: GatewayProvider? { providers.first { $0.matches(provider) } }
    public var currentCapabilities: GatewayModelCapabilities? { currentProvider?.capabilities[model] }
    public init(providers: [GatewayProvider], model: String, provider: String) {
        self.providers = providers; self.model = model; self.provider = provider
    }
    public init(json: JSONValue) throws {
        guard let rows = json["providers"]?.arrayValue else { throw GatewaySettingsError.invalidResponse }
        var seen = Set<String>()
        providers = rows.compactMap { row in
            guard let slug = row["slug"]?.stringValue, !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            var modelsSeen = Set<String>()
            let models = (row["models"]?.arrayValue ?? []).compactMap(\.stringValue)
                .filter { !$0.isEmpty && modelsSeen.insert($0).inserted }
            let capabilities = (row["capabilities"]?.objectValue ?? [:]).compactMapValues { value -> GatewayModelCapabilities? in
                guard let fast = value["fast"]?.boolValue, let reasoning = value["reasoning"]?.boolValue else { return nil }
                return GatewayModelCapabilities(fast: fast, reasoning: reasoning,
                                                canDisableReasoning: value["can_disable_reasoning"]?.boolValue)
            }
            return GatewayProvider(slug: slug, name: row["name"]?.stringValue ?? slug, models: models,
                aliases: (row["aliases"]?.arrayValue ?? []).compactMap(\.stringValue),
                authenticated: row["authenticated"]?.boolValue, warning: row["warning"]?.stringValue,
                unavailableModels: Set((row["unavailable_models"]?.arrayValue ?? []).compactMap(\.stringValue)),
                capabilities: capabilities)
        }
        model = json["model"]?.stringValue ?? ""
        provider = json["provider"]?.stringValue ?? ""
    }
}

public struct GatewayProfile: Equatable, Sendable, Identifiable {
    public let name: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let model: String?
    public let provider: String?
    public var id: String { name }
    public var label: String { displayName.isEmpty ? name : displayName }
    public init(name: String, displayName: String = "", description: String = "", isDefault: Bool = false,
                model: String? = nil, provider: String? = nil) {
        self.name = name; self.displayName = displayName; self.description = description
        self.isDefault = isDefault; self.model = model; self.provider = provider
    }
    public static func parse(_ json: JSONValue) throws -> [GatewayProfile] {
        guard let rows = json["profiles"]?.arrayValue else { throw GatewaySettingsError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty, seen.insert(name).inserted else { return nil }
            return GatewayProfile(name: name, displayName: row["display_name"]?.stringValue ?? "",
                description: row["description"]?.stringValue ?? "", isDefault: row["is_default"]?.boolValue ?? false,
                model: row["model"]?.stringValue, provider: row["provider"]?.stringValue)
        }
    }
}

public struct GatewaySettingsSnapshot: Equatable, Sendable {
    public let models: GatewayModelOptions
    public let profiles: [GatewayProfile]
    public let reasoningEffort: String?
    public let fastMode: String?
    public let notices: [String]
    public init(models: GatewayModelOptions, profiles: [GatewayProfile] = [], reasoningEffort: String? = nil,
                fastMode: String? = nil, notices: [String] = []) {
        self.models = models; self.profiles = profiles; self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode; self.notices = notices
    }
}

public struct GatewayModelSelection: Equatable, Sendable {
    public let provider: String
    public let model: String
    public let reasoningEffort: GatewayReasoningEffort?
    public init(provider: String, model: String, reasoningEffort: GatewayReasoningEffort? = nil) {
        self.provider = provider; self.model = model; self.reasoningEffort = reasoningEffort
    }
}

public struct GatewaySettingChange: Equatable, Sendable {
    public let value: String
    public let warning: String?
    public let confirmationMessage: String?
    public let deferred: Bool
    public let scope: String
    public var requiresConfirmation: Bool { confirmationMessage != nil }
    public init(value: String, warning: String? = nil, confirmationMessage: String? = nil,
                deferred: Bool = false, scope: String = "session") {
        self.value = value; self.warning = warning; self.confirmationMessage = confirmationMessage
        self.deferred = deferred; self.scope = scope
    }
    public init(json: JSONValue) throws {
        guard let value = json["value"]?.stringValue else { throw GatewaySettingsError.invalidResponse }
        self.value = value
        warning = json["warning"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if json["confirm_required"]?.boolValue == true {
            confirmationMessage = json["confirm_message"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? warning ?? "Hermes asks you to confirm this model selection."
        } else { confirmationMessage = nil }
        deferred = json["deferred"]?.boolValue ?? false
        scope = json["scope"]?.stringValue ?? "session"
    }
}

public enum GatewaySettingsError: Error, LocalizedError, Sendable, Equatable {
    case invalidResponse, liveSessionRequired, invalidIdentifier, unavailableSelection, unsupportedReasoning
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Hermes returned an invalid settings response. Refresh and try again."
        case .liveSessionRequired: "Open a conversation before changing its model."
        case .invalidIdentifier: "Enter a single model ID without spaces or command flags."
        case .unavailableSelection: "This provider or model is unavailable. Configure it on the Hermes host, then refresh."
        case .unsupportedReasoning: "This model does not advertise support for that reasoning setting."
        }
    }
}

/// Reads are profile-scoped. Every mutation names a live runtime and explicitly pins --session.
/// Fast-mode writes are intentionally absent: this upstream setter falls back to a global write
/// when a supplied runtime ID has expired. Reasoning travels through the safe model setter instead.
public struct GatewaySettingsService: Sendable {
    public typealias Request = @Sendable (String, JSONValue, TimeInterval) async throws -> JSONValue
    private let request: Request
    public init(client: GatewayClient) {
        request = { method, params, timeout in try await client.request(method, params: params, timeout: timeout) }
    }
    public init(request: @escaping Request) { self.request = request }

    public func load(profile: String, sessionID: String? = nil, refresh: Bool = false) async throws -> GatewaySettingsSnapshot {
        let context = Self.context(profile: profile, sessionID: sessionID)
        async let inventory = modelOptions(profile: profile, sessionID: sessionID, refresh: refresh)
        async let profilesResult = optionalRead("profiles.list", params: .object([
            "profile": .string(profile), "include_sessions": .bool(false)
        ]))
        async let reasoningResult = optionalRead("config.get", params: .object(context.merging(["key": .string("reasoning")]) { _, rhs in rhs }))
        async let fastResult = optionalRead("config.get", params: .object(context.merging(["key": .string("fast")]) { _, rhs in rhs }))
        let models = try await inventory
        let (profilesJSON, reasoningJSON, fastJSON) = await (profilesResult, reasoningResult, fastResult)
        let profiles = profilesJSON.flatMap { try? GatewayProfile.parse($0) }
        let reasoning = reasoningJSON?["value"]?.stringValue
        let fast = fastJSON?["value"]?.stringValue
        var notices: [String] = []
        if profiles == nil { notices.append("Profiles could not be loaded. Refresh to try again.") }
        if reasoning == nil { notices.append("The current reasoning setting could not be read.") }
        if fast == nil { notices.append("The current fast-mode setting could not be read.") }
        try Task.checkCancellation()
        return GatewaySettingsSnapshot(models: models, profiles: profiles ?? [], reasoningEffort: reasoning,
                                       fastMode: fast, notices: notices)
    }

    public func modelOptions(profile: String, sessionID: String? = nil, refresh: Bool = false) async throws -> GatewayModelOptions {
        var params = Self.context(profile: profile, sessionID: sessionID)
        params.merge(["explicit_only": .bool(true), "include_unconfigured": .bool(false), "refresh": .bool(refresh)]) { _, rhs in rhs }
        return try GatewayModelOptions(json: await request("model.options", .object(params), refresh ? 90 : 45))
    }

    public func selectModel(_ selection: GatewayModelSelection, profile: String, sessionID: String,
                            confirmed: Bool = false) async throws -> GatewaySettingChange {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GatewaySettingsError.liveSessionRequired }
        guard Self.validIdentifier(selection.model), Self.validIdentifier(selection.provider) else {
            throw GatewaySettingsError.invalidIdentifier
        }
        let inventory = try await modelOptions(profile: profile, sessionID: sessionID)
        guard let provider = inventory.providers.first(where: { $0.matches(selection.provider) }), provider.isAvailable,
              !provider.unavailableModels.contains(selection.model) else { throw GatewaySettingsError.unavailableSelection }
        if let effort = selection.reasoningEffort,
           provider.capabilities[selection.model]?.supports(effort) != true { throw GatewaySettingsError.unsupportedReasoning }
        // Model IDs not in the catalog are valid custom choices. The gateway validates them.
        var value = "\(selection.model) --provider \(selection.provider) --session"
        if let effort = selection.reasoningEffort { value += " --reasoning \(effort.rawValue)" }
        var params = Self.context(profile: profile, sessionID: sessionID)
        params.merge(["key": .string("model"), "value": .string(value), "confirm_expensive_model": .bool(confirmed)]) { _, rhs in rhs }
        return try GatewaySettingChange(json: await request("config.set", .object(params), 90))
    }

    private func optionalRead(_ method: String, params: JSONValue) async -> JSONValue? {
        try? await request(method, params, 45)
    }
    private static func context(profile: String, sessionID: String?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["profile": .string(profile)]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = .string(sessionID) }
        return params
    }
    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && !["-", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}"].contains(where: value.hasPrefix)
            && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
}
