import Foundation
import XCTest
import HermesCore
import HermesProtocol
@testable import HermesTransport

private actor AppModelHTTP: GatewayHTTPTransport {
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        GatewayHTTPResponse(data: Data(#"{"auth_required":false}"#.utf8), status: 200)
    }
}

private actor AppModelSocket: GatewaySocket {
    private var frames = [#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":false}}}"#]
    private var reader: CheckedContinuation<String, Error>?
    private var closed = false
    private var holdInventory = false
    private var heldInventory: JSONValue?
    private(set) var methods: [String] = []
    func holdNextInventory() { holdInventory = true }
    func isHoldingInventory() -> Bool { heldInventory != nil }
    func send(_ text: String) async throws {
        guard !closed else { throw URLError(.networkConnectionLost) }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard let method = frame["method"]?.stringValue, let id = frame["id"] else { return }
        methods.append(method)
        let profile = frame["params"]?["profile"]?.stringValue ?? "default"
        let result: JSONValue
        switch method {
        case "client.capabilities": result = .object(["server_requests": .bool(true)])
        case "session.list": result = .object(["sessions": .array([.object(["id": .string("stored-\(profile)"), "title": .string(profile)])])])
        case "session.create", "session.resume":
            result = .object(["session_id": .string("runtime-\(profile)"), "stored_session_id": .string("stored-\(profile)"),
                              "messages": .array([]), "running": .bool(false), "info": .object(["model": .string("fixture"), "title": .string(profile)])])
        case "profiles.list": result = .object(["profiles": .array(["default", "research"].map { .object(["name": .string($0)]) })])
        case "config.get": result = .object(["value": .string(frame["params"]?["key"] == .string("fast") ? "normal" : "medium")])
        case "model.options":
            result = .object(["provider": .string("fixture"), "model": .string("model-\(profile)"), "providers": .array([
                .object(["slug": .string("fixture"), "name": .string("Fixture"), "models": .array([.string("model-\(profile)")]), "authenticated": .bool(true)])
            ])])
        default: result = .object([:])
        }
        let response = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        if method == "model.options", holdInventory { heldInventory = response; holdInventory = false; return }
        try push(response)
    }
    func releaseInventory() throws {
        if let heldInventory { try push(heldInventory); self.heldInventory = nil }
    }
    func receive() async throws -> String {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func close() async {
        closed = true
        let previous = reader; reader = nil
        previous?.resume(throwing: URLError(.cancelled))
    }
    private func push(_ value: JSONValue) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        if let reader { self.reader = nil; reader.resume(returning: text) }
        else { frames.append(text) }
    }
}

@MainActor
private final class AppModelClientFactory {
    var sockets: [AppModelSocket] = []
    func make() -> GatewayClient {
        let socket = AppModelSocket(); sockets.append(socket)
        return GatewayClient(http: AppModelHTTP(), socketFactory: { _ in socket })
    }
}

@MainActor
final class HermesAppModelTests: XCTestCase {
    private func fixture() throws -> (HermesAppModel, AppModelClientFactory, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talaria-model-tests-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "talaria-model-tests-\(UUID().uuidString)"))
        let factory = AppModelClientFactory()
        let model = HermesAppModel(defaults: defaults, draftStore: DraftStore(directory: directory), clientFactory: { factory.make() })
        return (model, factory, directory, defaults)
    }
    private func endpoint(id: UUID = UUID(), profile: String = "default") -> GatewayEndpoint {
        GatewayEndpoint(id: id, name: "Fixture", baseURL: URL(string: "http://127.0.0.1:8642")!, profile: profile)
    }
    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "Expected the ordered update stream to settle")
    }

    func testProfileRoundTripRestoresEachScopedDraftAndSelection() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture-token")
        await model.newConversation()
        await settle { model.selectedID?.rawValue == "stored-default" }
        model.draft = "Default draft"
        await model.loadSettings()
        let firstSwitch = await model.selectProfile("research")
        XCTAssertTrue(firstSwitch)
        XCTAssertNil(model.selectedID)
        await model.newConversation()
        await settle { model.selectedID?.rawValue == "stored-research" }
        model.draft = "Research draft"
        await model.loadSettings()
        let secondSwitch = await model.selectProfile("default")
        XCTAssertTrue(secondSwitch)
        await settle { model.selectedID?.rawValue == "stored-default" }
        XCTAssertEqual(model.draft, "Default draft")
        XCTAssertEqual(model.composerScope?.profile, "default")
        XCTAssertEqual(model.composerScope?.connectionID, connection.id)
        let thirdSwitch = await model.selectProfile("research")
        XCTAssertTrue(thirdSwitch)
        await settle { model.selectedID?.rawValue == "stored-research" }
        XCTAssertEqual(model.draft, "Research draft")
        XCTAssertEqual(factory.sockets.count, 5, "Initialization plus a new client for every connection generation")
        await model.disconnect()
    }

    func testLateSettingsFromOldConnectionCannotReplaceNewProfile() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture-token")
        await model.newConversation()
        await settle { model.conversation != nil }
        let oldSocket = try XCTUnwrap(factory.sockets.last)
        await oldSocket.holdNextInventory()
        let oldLoad = Task { await model.loadSettings() }
        for _ in 0..<100 {
            if await oldSocket.isHoldingInventory() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        var secondary = connection; secondary.profile = "research"
        await model.connect(to: secondary, token: nil)
        await model.newConversation()
        await settle { model.selectedID?.rawValue == "stored-research" }
        await model.loadSettings()
        try await oldSocket.releaseInventory()
        await oldLoad.value
        XCTAssertEqual(model.settingsSnapshot?.models.model, "model-research")
        XCTAssertNil(model.settingsError)
        XCTAssertFalse(model.isLoadingSettings)
        XCTAssertTrue(model.isConnected)
        await model.disconnect()
    }

    func testConnectionIdentitySeparatesSameNamedProfileAndSessionDrafts() async throws {
        let (model, _, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = endpoint(), second = endpoint()
        await model.connect(to: first, token: "fixture-token")
        await model.newConversation()
        await settle { model.conversation != nil }
        model.draft = "First connection"
        await model.connect(to: second, token: "second-token")
        await model.newConversation()
        await settle { model.conversation != nil }
        XCTAssertEqual(model.draft, "")
        model.draft = "Second connection"
        await model.connect(to: first, token: "fixture-token")
        await settle { model.conversation != nil }
        XCTAssertEqual(model.draft, "First connection")
        await model.disconnect()
    }
}
