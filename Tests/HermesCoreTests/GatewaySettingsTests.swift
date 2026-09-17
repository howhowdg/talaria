import Foundation
import XCTest
import HermesCore
import HermesProtocol

private actor SettingsFixture {
    struct Call: Sendable {
        let method: String
        let params: JSONValue
    }
    private(set) var calls: [Call] = []
    var failedMethods = Set<String>()
    var switchResult: JSONValue = .object(["key": .string("model"), "value": .string("fixture-model"), "scope": .string("session")])
    var stale = false
    let catalog: JSONValue
    init(catalog: JSONValue = GatewaySettingsTests.catalog) { self.catalog = catalog }
    func fail(_ method: String) { failedMethods.insert(method) }
    func setSwitchResult(_ value: JSONValue) { switchResult = value }
    func setStale() { stale = true }
    func request(_ method: String, _ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        if failedMethods.contains(method) { throw JSONRPCError(code: 5000, message: "Fixture unavailable") }
        switch method {
        case "model.options": return catalog
        case "profiles.list": return .object(["profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true), "path": .string("/private/profile")]),
            .object(["name": .string("research"), "display_name": .string("Research"), "description": .string("Isolated work"), "provider": .null, "model": .null])
        ])])
        case "config.get": return .object(["value": params["key"] == .string("reasoning") ? .string("medium") : .string("normal")])
        case "config.set":
            if stale { throw JSONRPCError(code: 4001, message: "session not found") }
            return switchResult
        default: throw JSONRPCError(code: -32601, message: "Unknown method")
        }
    }
}

@MainActor
final class GatewaySettingsTests: XCTestCase {
    nonisolated static let catalog: JSONValue = .object([
        "provider": .string("custom:local"), "model": .string("fixture-model"), "future": .bool(true),
        "providers": .array([
            .object(["slug": .string("local"), "name": .string("Local model"), "aliases": .array([.string("custom:local")]),
                     "authenticated": .bool(true), "models": .array([.string("fixture-model"), .string("paid-model")]),
                     "unavailable_models": .array([.string("paid-model")]), "capabilities": .object([
                        "fixture-model": .object(["fast": .bool(true), "reasoning": .bool(true), "can_disable_reasoning": .bool(false)])
                     ])]),
            .object(["slug": .string("locked"), "name": .string("Missing credentials"), "models": .array([.string("saved")]),
                     "authenticated": .bool(false), "warning": .string("Configure on the host")])
        ])
    ])
    private func service(_ fixture: SettingsFixture) -> GatewaySettingsService {
        GatewaySettingsService { method, params, timeout in try await fixture.request(method, params, timeout) }
    }

    func testParsesProviderAliasesCapabilitiesAndUnavailableModels() throws {
        let options = try GatewayModelOptions(json: Self.catalog)
        XCTAssertEqual(options.currentProvider?.slug, "local")
        XCTAssertEqual(options.currentCapabilities?.fast, true)
        XCTAssertEqual(options.currentCapabilities?.supports(.none), false)
        XCTAssertEqual(options.currentCapabilities?.supports(.high), true)
        XCTAssertEqual(options.providers.last?.isAvailable, false)
        XCTAssertTrue(options.currentProvider!.unavailableModels.contains("paid-model"))
    }

    func testLoadUsesRealReadOnlyScopedContracts() async throws {
        let fixture = SettingsFixture()
        let snapshot = try await service(fixture).load(profile: "research", sessionID: "runtime-a", refresh: true)
        XCTAssertEqual(snapshot.models.model, "fixture-model")
        XCTAssertEqual(snapshot.reasoningEffort, "medium")
        XCTAssertEqual(snapshot.fastMode, "normal")
        XCTAssertEqual(snapshot.profiles.map(\.name), ["default", "research"])
        XCTAssertEqual(snapshot.profiles.last?.label, "Research")
        XCTAssertTrue(snapshot.notices.isEmpty)
        let calls = await fixture.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.params["profile"] == .string("research") })
        let inventory = try XCTUnwrap(calls.first { $0.method == "model.options" })
        XCTAssertEqual(inventory.params["explicit_only"], .bool(true))
        XCTAssertEqual(inventory.params["include_unconfigured"], .bool(false))
        XCTAssertEqual(inventory.params["refresh"], .bool(true))
        XCTAssertEqual(inventory.params["session_id"], .string("runtime-a"))
        let profiles = try XCTUnwrap(calls.first { $0.method == "profiles.list" })
        XCTAssertEqual(profiles.params["include_sessions"], .bool(false), "Avoid canonical-session recovery mutations during profile discovery")
        XCTAssertNil(profiles.params["session_id"])
    }

    func testOptionalReadsFailWithoutHidingTheModelCatalog() async throws {
        let fixture = SettingsFixture()
        await fixture.fail("profiles.list")
        await fixture.fail("config.get")
        let snapshot = try await service(fixture).load(profile: "default")
        XCTAssertEqual(snapshot.models.providers.count, 2)
        XCTAssertTrue(snapshot.profiles.isEmpty)
        XCTAssertNil(snapshot.reasoningEffort)
        XCTAssertNil(snapshot.fastMode)
        XCTAssertEqual(snapshot.notices.count, 3)
        let calls = await fixture.calls
        XCTAssertTrue(calls.allSatisfy { $0.params["session_id"] == nil })
    }

    func testInventoryFailurePropagates() async throws {
        let fixture = SettingsFixture()
        await fixture.fail("model.options")
        do { _ = try await service(fixture).load(profile: "default"); XCTFail("Expected failed catalog") }
        catch { XCTAssertEqual((error as? JSONRPCError)?.code, 5000) }
    }

    func testCustomModelSelectionPreservesProviderAndSessionScope() async throws {
        let fixture = SettingsFixture()
        _ = try await service(fixture).selectModel(GatewayModelSelection(provider: "local", model: "new/model:v2"),
                                                  profile: "research", sessionID: "runtime-a")
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.method), ["model.options", "config.set"])
        let params = try XCTUnwrap(calls.last?.params)
        XCTAssertEqual(params["value"], .string("new/model:v2 --provider local --session"))
        XCTAssertEqual(params["profile"], .string("research"))
        XCTAssertEqual(params["session_id"], .string("runtime-a"))
        XCTAssertEqual(params["confirm_expensive_model"], .bool(false))
    }

    func testReasoningUsesSessionValidatedModelSwitch() async throws {
        let fixture = SettingsFixture()
        _ = try await service(fixture).selectModel(GatewayModelSelection(provider: "custom:local", model: "fixture-model", reasoningEffort: .high),
                                                  profile: "research", sessionID: "runtime-a")
        let calls = await fixture.calls
        let mutation = try XCTUnwrap(calls.last)
        XCTAssertEqual(mutation.params["key"], .string("model"))
        XCTAssertEqual(mutation.params["value"], .string("fixture-model --provider custom:local --session --reasoning high"))
        XCTAssertFalse(calls.contains { $0.params["key"] == .string("fast") || $0.params["key"] == .string("reasoning") })
    }

    func testUnsupportedReasoningAndUnavailableModelsNeverMutate() async throws {
        let selections: [(GatewayModelSelection, GatewaySettingsError)] = [
            (GatewayModelSelection(provider: "local", model: "fixture-model", reasoningEffort: GatewayReasoningEffort.none), .unsupportedReasoning),
            (GatewayModelSelection(provider: "local", model: "custom", reasoningEffort: .high), .unsupportedReasoning),
            (GatewayModelSelection(provider: "local", model: "paid-model"), .unavailableSelection),
            (GatewayModelSelection(provider: "locked", model: "saved"), .unavailableSelection),
            (GatewayModelSelection(provider: "unknown", model: "saved"), .unavailableSelection)
        ]
        for (selection, expected) in selections {
            let fixture = SettingsFixture()
            do { _ = try await service(fixture).selectModel(selection, profile: "default", sessionID: "runtime-a"); XCTFail("Expected refusal") }
            catch { XCTAssertEqual(error as? GatewaySettingsError, expected) }
            let calls = await fixture.calls
            XCTAssertFalse(calls.contains { $0.method == "config.set" })
        }
    }

    func testEmptyRuntimeAndEmbeddedScopeFlagsAreRejectedBeforeNetwork() async throws {
        let fixture = SettingsFixture()
        do { _ = try await service(fixture).selectModel(GatewayModelSelection(provider: "local", model: "ok"), profile: "default", sessionID: " "); XCTFail("Expected missing session") }
        catch { XCTAssertEqual(error as? GatewaySettingsError, .liveSessionRequired) }
        for model in ["model --global", "--global", "model\n--provider other", "—global", "\u{2012}global", "\u{2015}once", "model\t--once"] {
            do { _ = try await service(fixture).selectModel(GatewayModelSelection(provider: "local", model: model), profile: "default", sessionID: "runtime-a"); XCTFail("Expected invalid ID") }
            catch { XCTAssertEqual(error as? GatewaySettingsError, .invalidIdentifier) }
        }
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testConfirmationIsReturnedWithoutAutomaticRetry() async throws {
        let fixture = SettingsFixture()
        await fixture.setSwitchResult(.object(["value": .string("fixture-model"), "confirm_required": .bool(true), "confirm_message": .string("Higher cost. Continue?")]))
        let selection = GatewayModelSelection(provider: "local", model: "fixture-model")
        let result = try await service(fixture).selectModel(selection, profile: "default", sessionID: "runtime-a")
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertEqual(result.confirmationMessage, "Higher cost. Continue?")
        var calls = await fixture.calls
        XCTAssertEqual(calls.filter { $0.method == "config.set" }.count, 1)
        await fixture.setSwitchResult(.object(["value": .string("fixture-model"), "deferred": .bool(true), "scope": .string("session")]))
        let confirmed = try await service(fixture).selectModel(selection, profile: "default", sessionID: "runtime-a", confirmed: true)
        XCTAssertTrue(confirmed.deferred)
        XCTAssertFalse(confirmed.requiresConfirmation)
        calls = await fixture.calls
        XCTAssertEqual(calls.last?.params["confirm_expensive_model"], .bool(true))
    }

    func testStaleRuntimeFailureIsNotRetriedWithoutSession() async throws {
        let fixture = SettingsFixture()
        await fixture.setStale()
        do { _ = try await service(fixture).selectModel(GatewayModelSelection(provider: "local", model: "fixture-model", reasoningEffort: .high), profile: "research", sessionID: "expired"); XCTFail("Expected stale runtime") }
        catch { XCTAssertEqual((error as? JSONRPCError)?.code, 4001) }
        let calls = await fixture.calls
        XCTAssertEqual(calls.filter { $0.method == "config.set" }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.params["session_id"] == .string("expired") })
    }
}
