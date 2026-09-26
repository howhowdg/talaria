import Foundation
import XCTest
@testable import HermesCore
import HermesProtocol
@testable import HermesTransport

private actor AppModelHTTP: GatewayHTTPTransport {
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        GatewayHTTPResponse(data: Data(#"{"auth_required":false}"#.utf8), status: 200)
    }
}

private actor TelegramModelFixture {
    var suffix = "old"
    var missing = false
    var suspended: CheckedContinuation<Void, Never>?
    var shouldHold = false
    func setSuffix(_ value: String) { suffix = value }
    func setMissing() { missing = true }
    func holdNext() { shouldHold = true }
    func isHolding() -> Bool { suspended != nil }
    func release() { suspended?.resume(); suspended = nil }
    func load(_ profile: String) async -> JSONValue {
        if shouldHold { shouldHold = false; await withCheckedContinuation { suspended = $0 } }
        return .object(["schema_version": .number(1), "profile": .string(profile), "topics": .array(missing ? [] : ["1", "42"].map { thread in
            .object(["chat_id": .string("-100"), "thread_id": .string(thread),
                "session_key": .string("telegram:-100:\(thread)"),
                "current_session_id": .string("\(profile)-\(thread)-\(suffix)"),
                "chat_type": .string("group"), "chat_name": .string("Fixture group"),
                "topic_name": thread == "1" ? .string("General") : .null,
                "binding_source": .string("gateway_routing")])
        })])
    }
}

private actor AppModelSocket: GatewaySocket {
    private var frames = [#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":false}}}"#]
    private var reader: CheckedContinuation<String, Error>?
    private var closed = false
    private var holdInventory = false
    private var resumeError: JSONRPCError?
    private var nextCreatedID: String?
    func createNextSession(as id: String) { nextCreatedID = id }
    private var holdResume = false
    private var heldResume: JSONValue?
    func holdNextResume() { holdResume = true }
    func isHoldingResume() -> Bool { heldResume != nil }
    func releaseResume() throws {
        if let heldResume { try push(heldResume); self.heldResume = nil }
    }
    func failResume(_ error: JSONRPCError?) { resumeError = error }
    private var heldInventory: JSONValue?
    private(set) var methods: [String] = []
    func holdNextInventory() { holdInventory = true }
    func isHoldingInventory() -> Bool { heldInventory != nil }
    func send(_ text: String) async throws {
        guard !closed else { throw URLError(.networkConnectionLost) }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard let method = frame["method"]?.stringValue, let id = frame["id"] else { return }
        methods.append(method)
        if method == "session.resume", let resumeError {
            try push(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                "code": .number(Double(resumeError.code)), "message": .string(resumeError.message)])]))
            return
        }
        let profile = frame["params"]?["profile"]?.stringValue ?? "default"
        let result: JSONValue
        switch method {
        case "client.capabilities": result = .object(["server_requests": .bool(true)])
        case "session.list": result = .object(["sessions": .array([.object(["id": .string("stored-\(profile)"), "title": .string(profile)])])])
        case "session.create", "session.resume":
            result = .object(["session_id": .string("runtime-\(profile)"), "stored_session_id": .string(method == "session.resume" ? frame["params"]?["session_id"]?.stringValue ?? "stored-\(profile)" : nextCreatedID ?? "stored-\(profile)"),
                              "messages": .array([]), "running": .bool(false), "info": .object(["model": .string("fixture"), "title": .string(profile)])])
        case "profiles.list": result = .object(["profiles": .array(["default", "research"].map { .object(["name": .string($0)]) })])
        case "config.get": result = .object(["value": .string(frame["params"]?["key"] == .string("fast") ? "normal" : "medium")])
        case "model.options":
            result = .object(["provider": .string("fixture"), "model": .string("model-\(profile)"), "providers": .array([
                .object(["slug": .string("fixture"), "name": .string("Fixture"), "models": .array([.string("model-\(profile)")]), "authenticated": .bool(true)])
            ])])
        default: result = .object([:])
        }
        if method == "session.create" { nextCreatedID = nil }
        let response = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        if method == "session.resume", holdResume { heldResume = response; holdResume = false; return }
        if method == "model.options", holdInventory { heldInventory = response; holdInventory = false; return }
        try push(response)
    }
    func releaseInventory() throws {
        if let heldInventory { try push(heldInventory); self.heldInventory = nil }
    }
    func injectSecret(sessionID: String) throws {
        try push(.object(["jsonrpc": .string("2.0"), "id": .string("secret-fixture"), "method": .string("secret"),
            "params": .object(["session_id": .string(sessionID), "description": .string("sensitive prompt text")])]))
    }
    func injectClarification(sessionID: String) throws {
        try push(.object(["jsonrpc": .string("2.0"), "id": .string("clarify-fixture"), "method": .string("clarify"),
            "params": .object(["session_id": .string(sessionID), "question": .string("Which option?")])]))
    }
    func injectApproval(sessionID: String) throws {
        try push(.object(["jsonrpc": .string("2.0"), "id": .string("approval-fixture"), "method": .string("approval"),
            "params": .object(["session_id": .string(sessionID), "request_id": .string("approval-fixture"),
                               "description": .string("Review this command"), "command": .string("echo fixture")])]))
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
    private func fixture(loader: MobileActivityLoader? = nil, runLoader: AutomationRunDetailLoader? = nil, automationRunsLoader: AutomationRunsLoader? = nil,
                         telegramLoader: @escaping TelegramTopicsLoader = { _, _ in throw GatewayTransportError.httpStatus(404) }) throws -> (HermesAppModel, AppModelClientFactory, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talaria-model-tests-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "talaria-model-tests-\(UUID().uuidString)"))
        let factory = AppModelClientFactory()
        let model = HermesAppModel(defaults: defaults, draftStore: DraftStore(directory: directory),
            mobileActivityLoader: loader, runDetailLoader: runLoader, automationRunsLoader: automationRunsLoader,
            telegramTopicsLoader: telegramLoader, clientFactory: { factory.make() })
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

    func testSSHConnectionKeepsStableEndpointAcrossReconnect() async throws {
        let (model, _, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configured = GatewayEndpoint(name: "Mini", baseURL: URL(string: "http://127.0.0.1:9119")!,
            ssh: GatewaySSHDestination(host: "mini.example"))
        var active = configured; active.baseURL = URL(string: "http://127.0.0.1:23456")!
        await model.connect(to: active, configuredEndpoint: configured, token: "fixture")
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.endpoint, configured)
        await model.sshTunnelExited()
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.desiredConnection)
        XCTAssertEqual(model.endpoint, configured)
        model.setSSHReconnectHandler {
            var next = configured; next.baseURL = URL(string: "http://127.0.0.1:34567")!
            return (next, "fresh-fixture")
        }
        await model.reconnect()
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.endpoint, configured)
        await model.disconnect()
    }

    func testTelegramDiscoveryRequiresImportAndFollowsOnlyExplicitTopicBindings() async throws {
        let topics = TelegramModelFixture()
        let (model, factory, directory, _) = try fixture(telegramLoader: { endpoint, _ in await topics.load(endpoint.profile) })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        XCTAssertEqual(model.telegramTopics.count, 2)
        XCTAssertTrue(model.hierarchyFeatures.telegramBindings)
        XCTAssertNil(model.homeSessionID)
        XCTAssertTrue(model.workspaces.isEmpty)
        let home = try XCTUnwrap(model.telegramTopics.first).id
        let workspace = try XCTUnwrap(model.telegramTopics.last).id
        let imported = await model.importTelegramTopics(home: home, asWorkspaces: [workspace])
        XCTAssertTrue(imported)
        XCTAssertEqual(model.homeSessionID?.rawValue, "default-1-old")
        XCTAssertEqual(model.selectedID, model.homeSessionID)
        let workspaceID = try XCTUnwrap(model.workspaces.first?.id)
        model.updateWorkspace(workspaceID, name: "My chosen name", purpose: "", swatch: "#4F6AF2")
        await topics.setSuffix("reset")
        await model.navigate(to: .conversation(.init(rawValue: "default-42-old")))
        XCTAssertEqual(model.hierarchyDestination, .workspace(workspaceID))
        XCTAssertEqual(model.selectedID?.rawValue, "default-42-reset")
        XCTAssertEqual(model.workspaces.first?.name, "My chosen name")
        XCTAssertEqual(model.homeSessionID?.rawValue, "default-1-reset")
        await topics.setMissing()
        await model.navigate(to: .home)
        XCTAssertEqual(model.homeAvailability, .unavailable)
        model.draft = "Do not send"
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.homeSessionID?.rawValue, "default-1-reset")
        let methods = await factory.sockets.last!.methods
        XCTAssertFalse(methods.contains("prompt.submit"))
        XCTAssertFalse(methods.contains("session.create"))
        await model.disconnect()
    }

    func testTelegramDiscoveryFromPreviousProfileCannotPopulateNewOwner() async throws {
        let topics = TelegramModelFixture()
        let (model, _, directory, _) = try fixture(telegramLoader: { endpoint, _ in await topics.load(endpoint.profile) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = endpoint()
        await model.connect(to: first, token: "fixture")
        await topics.holdNext()
        let stale = Task { await model.refreshTelegramTopics() }
        for _ in 0..<100 {
            if await topics.isHolding() { break }
            await Task.yield()
        }
        let held = await topics.isHolding(); XCTAssertTrue(held)
        await model.connect(to: endpoint(id: first.id, profile: "research"), token: "fixture")
        await topics.release(); await stale.value
        XCTAssertTrue(model.telegramTopics.allSatisfy { $0.currentSessionID.rawValue.hasPrefix("research-") })
        XCTAssertTrue(model.workspaces.isEmpty)
        XCTAssertNil(model.homeSessionID)
        await model.disconnect()
    }

    func testDisconnectOnlyOffersConversationRestorationWhenAConversationExists() async throws {
        for hasConversation in [false, true] {
            let (model, factory, directory, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            await model.connect(to: endpoint(), token: "fixture-token")
            if hasConversation { await model.newConversation() }
            let socket = try XCTUnwrap(factory.sockets.last)
            await socket.close()
            await settle { !model.isConnected && model.banner != nil }
            XCTAssertEqual(model.banner?.contains("Reconnect to restore the conversation."), hasConversation)
            await model.disconnect()
        }
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

    func testLateActivityCannotRestoreOldProfileOrLoadingState() async throws {
        let activity = HeldActivityLoader()
        let (model, _, directory, _) = try fixture(loader: { _, endpoint, _ in try await activity.load(endpoint.profile) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture-token")
        let oldLoad = Task { await model.refreshMobileActivity() }
        for _ in 0..<100 {
            if await activity.isHolding() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        var secondary = connection; secondary.profile = "research"
        await model.connect(to: secondary, token: nil)
        await model.refreshMobileActivity()
        XCTAssertEqual(model.mobileActivity.runs.first?.title, "research")
        await activity.release()
        await oldLoad.value
        XCTAssertEqual(model.mobileActivity.runs.first?.title, "research")
        XCTAssertFalse(model.isLoadingMobileActivity)
        XCTAssertNil(model.mobileActivityError)
        await model.disconnect()
        XCTAssertEqual(model.mobileActivity.runs.first?.title, "research", "Disconnection keeps only this owner's last loaded content")
    }

    func testSeenRunsPersistPerConnectionAndProfile() async throws {
        let (model, _, directory, _) = try fixture(loader: { _, endpoint, _ in activitySnapshot(endpoint.profile) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture-token")
        await model.refreshMobileActivity()
        XCTAssertEqual(model.unreadMobileRunCount, 1)
        model.markMobileRunsSeen()
        XCTAssertEqual(model.unreadMobileRunCount, 0)
        var other = connection; other.profile = "research"
        await model.connect(to: other, token: nil)
        await model.refreshMobileActivity()
        XCTAssertEqual(model.unreadMobileRunCount, 1, "Same run ID in another profile is independently unread")
        await model.connect(to: connection, token: nil)
        await model.refreshMobileActivity()
        XCTAssertEqual(model.unreadMobileRunCount, 0)
        await model.connect(to: endpoint(), token: "another-token")
        await model.refreshMobileActivity()
        XCTAssertEqual(model.unreadMobileRunCount, 1, "Connection IDs also fence seen state")
        await model.disconnect()
    }

    func testGlobalPendingInputDoesNotGuessStoredIDAndClearsAfterAnswer() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture-token")
        let socket = try XCTUnwrap(factory.sockets.last)
        try await socket.injectApproval(sessionID: "runtime-default")
        await settle { model.mobilePendingInputs.count == 1 }
        XCTAssertNil(model.mobilePendingInputs.first?.sessionID)
        await model.newConversation()
        await settle { model.mobilePendingInputs.first?.sessionID?.rawValue == "stored-default" }
        let input = try XCTUnwrap(model.mobilePendingInputs.first?.input)
        let answered = await model.answer(input, result: .object(["choice": .string("deny")]))
        XCTAssertTrue(answered)
        XCTAssertTrue(model.mobilePendingInputs.isEmpty)
        await model.disconnect()
    }
}

private func activitySnapshot(_ profile: String) -> MobileActivitySnapshot {
    let schedule = MobileSchedule(json: .object(["id": .string("job"), "name": .string(profile)]))!
    var run = MobileRun(json: .object(["id": .string("same-run"), "title": .string(profile),
        "started_at": .number(1_800_000_000)]), schedule: schedule, profile: profile)!
    run.summary = "Actual result"; run.status = .completed
    return MobileActivitySnapshot(schedules: [schedule], runs: [run])
}

private actor HeldActivityLoader {
    private var continuation: CheckedContinuation<MobileActivitySnapshot, Never>?
    func load(_ profile: String) async throws -> MobileActivitySnapshot {
        if profile != "default" { return activitySnapshot(profile) }
        // Deliberately ignores cancellation to model a late transport completion.
        return await withCheckedContinuation { continuation = $0 }
    }
    func isHolding() -> Bool { continuation != nil }
    func release() { continuation?.resume(returning: activitySnapshot("default")); continuation = nil }
}

extension HermesAppModelTests {
    func testHomeNotFoundPreservesExplicitAssignmentAndCachedTranscript() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        let owner = try XCTUnwrap(model.currentHierarchyOwner)
        let home = StoredSessionID(rawValue: "chosen-home")
        model.classificationStore.update(for: owner) {
            $0.homeSessionID = home
            $0.cachedHomeMessages = [ChatMessage(role: .assistant, text: "Cached answer")]
        }
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.failResume(JSONRPCError(code: 4007, message: "session not found"))
        await model.navigate(to: .home)
        XCTAssertEqual(model.homeAvailability, .unavailable)
        XCTAssertEqual(model.homeSessionID, home)
        XCTAssertEqual(model.cachedHomeMessages.map(\.text), ["Cached answer"])
        // A list containing another conversation must never replace Home.
        await model.refreshSessions()
        XCTAssertEqual(model.homeSessionID, home)
        await socket.failResume(JSONRPCError(code: -32603, message: "temporarily unavailable"))
        await model.navigate(to: .home)
        if case .failed = model.homeAvailability {} else { XCTFail("Transport/server errors are not Home deletion") }
        XCTAssertEqual(model.homeSessionID, home)
        await model.disconnect()
    }

    func testExplicitClassificationAndDiscussionDoNotSendOrInferFromTitles() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        XCTAssertNil(model.homeSessionID)
        XCTAssertEqual(model.otherConversations.count, 1)
        await model.newConversation()
        let session = try XCTUnwrap(model.selectedID)
        let workspace = try XCTUnwrap(model.createWorkspace(name: "Focused", sessionID: session))
        XCTAssertEqual(model.workspace(for: session)?.id, workspace)
        await model.chooseHome(session)
        XCTAssertNil(model.workspace(for: session), "Explicit Home moves it out of Workspace classification")
        XCTAssertEqual(model.homeAvailability, .available, "Cached fast path must settle loading")
        model.draft = "My existing draft"
        let staged = await model.stageResultDiscussion(result: "Final answer\nSecond line", runID: "run/1", destination: session,
                                                      includeResult: true, includeBacklink: false)
        XCTAssertTrue(staged)
        XCTAssertEqual(model.draft, "My existing draft\n\n> Final answer\n> Second line")
        XCTAssertFalse(model.draft.contains("talaria://"))
        let socket = try XCTUnwrap(factory.sockets.last)
        let methods = await socket.methods
        XCTAssertFalse(methods.contains("prompt.submit"), "Discussion is an explicit destination draft, not an implicit send")
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testRapidNavigationEventuallyOpensLatestRequestedConversation() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.holdNextResume()
        let first = StoredSessionID(rawValue: "first")
        let second = StoredSessionID(rawValue: "second")
        let firstNavigation = Task { await model.navigate(to: .conversation(first)) }
        for _ in 0..<100 {
            if await socket.isHoldingResume() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let secondNavigation = Task { await model.navigate(to: .conversation(second)) }
        await settle { model.hierarchyDestination == .conversation(second) }
        try await socket.releaseResume()
        await firstNavigation.value; await secondNavigation.value
        XCTAssertEqual(model.hierarchyDestination, .conversation(second))
        XCTAssertEqual(model.selectedID, second)
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testPendingNavigationCannotOpenOldSessionInNewProfile() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture")
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.holdNextResume()
        let firstNavigation = Task { await model.navigate(to: .conversation(.init(rawValue: "old-first"))) }
        for _ in 0..<100 {
            if await socket.isHoldingResume() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let secondNavigation = Task { await model.navigate(to: .conversation(.init(rawValue: "old-second"))) }
        await settle { model.hierarchyDestination == .conversation(.init(rawValue: "old-second")) }
        await model.connect(to: endpoint(id: connection.id, profile: "research"), token: "fixture")
        await firstNavigation.value; await secondNavigation.value
        XCTAssertEqual(model.endpoint?.profile, "research")
        XCTAssertEqual(model.hierarchyDestination, .home)
        XCTAssertNil(model.selectedID)
        let newSocket = try XCTUnwrap(factory.sockets.last)
        let methods = await newSocket.methods
        XCTAssertFalse(methods.contains("session.resume"))
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testComposerAnswersOnlySingleClarificationAndPreservesEditedDraft() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.newConversation()
        let socket = try XCTUnwrap(factory.sockets.last)
        try await socket.injectApproval(sessionID: "runtime-default")
        await settle { model.mobilePendingInputs.count == 1 }
        XCTAssertFalse(model.canAnswerPendingText)
        let refused = await model.answerPendingText("yes")
        XCTAssertFalse(refused, "Free text cannot grant a tool permission")
        if let input = model.conversation?.pendingInputs.first { _ = await model.answer(input, result: .object(["choice": .string("deny")])) }
        try await socket.injectClarification(sessionID: "runtime-default")
        await settle { model.canAnswerPendingText }
        model.draft = "New draft typed since submission began"
        let sent = await model.answerPendingText("Earlier answer")
        XCTAssertTrue(sent)
        XCTAssertEqual(model.draft, "New draft typed since submission began")
        try await socket.injectClarification(sessionID: "runtime-default")
        await settle { model.canAnswerPendingText }
        model.draft = "Current answer"
        _ = await model.answerPendingText("Current answer")
        XCTAssertEqual(model.draft, "")
        await model.disconnect()
    }
}

private actor ChangingRunFixture {
    private var completed = false
    func finish() { completed = true }
    func snapshot() -> MobileActivitySnapshot {
        let automation = MobileSchedule(json: .object(["id": .string("automation")]))!
        var fields: [String: JSONValue] = ["id": .string("run"), "is_active": .bool(!completed)]
        if completed { fields["ended_at"] = .number(1_800_000_010); fields["end_reason"] = .string("cron_complete") }
        let run = MobileRun(json: .object(fields), schedule: automation, profile: "default")!
        return MobileActivitySnapshot(schedules: [automation], runs: [run])
    }
    static func transcript(_ endpoint: GatewayEndpoint, _ session: GatewaySession, _ run: AutomationRun) async throws -> JSONValue {
        .object(["session_id": .string(run.id), "profile": .string(endpoint.profile), "messages": .array([
            .object(["role": .string("user"), "content": .string("Do work")]),
            .object(["role": .string("assistant"), "content": .string(run.isActive ? "Partial output" : "Final output")])])])
    }
}

extension HermesAppModelTests {
    func testOpeningWorkingRunDoesNotReadItsFutureResultAndRefreshInvalidatesPartialCache() async throws {
        let changing = ChangingRunFixture()
        let (model, _, directory, _) = try fixture(loader: { _, _, _ in await changing.snapshot() }, runLoader: ChangingRunFixture.transcript)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.refreshMobileActivity()
        await model.navigate(to: .run("run"))
        XCTAssertEqual(model.runDetails["run"]?.status, .working)
        XCTAssertFalse(model.hierarchyClassification.readRunIDs.contains("run"))
        await model.navigate(to: .home)
        await changing.finish()
        await model.refreshMobileActivity()
        XCTAssertNil(model.runDetails["run"], "The previous partial result must not override newly completed metadata")
        XCTAssertTrue(model.isRunUnread("run"))
        await model.navigate(to: .run("run"))
        XCTAssertEqual(model.runDetails["run"]?.result, "Final output")
        XCTAssertEqual(model.runDetails["run"]?.status, .completed)
        XCTAssertFalse(model.isRunUnread("run"))
        await model.disconnect()
    }

    func testRefreshReloadsVisibleRunAfterCompletion() async throws {
        let changing = ChangingRunFixture()
        let (model, _, directory, _) = try fixture(loader: { _, _, _ in await changing.snapshot() }, runLoader: ChangingRunFixture.transcript)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.refreshMobileActivity()
        await model.navigate(to: .run("run"))
        await changing.finish()
        await model.refreshMobileActivity()
        XCTAssertEqual(model.runDetails["run"]?.status, .completed)
        XCTAssertEqual(model.runDetails["run"]?.result, "Final output")
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testRunWaitingStateClearsWhenItsRequestIsAnswered() async throws {
        let changing = ChangingRunFixture()
        let (model, factory, directory, _) = try fixture(loader: { _, _, _ in await changing.snapshot() }, runLoader: ChangingRunFixture.transcript)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.refreshMobileActivity()
        await model.openSession(.init(rawValue: "run"))
        await model.loadRunDetail("run")
        let socket = try XCTUnwrap(factory.sockets.last)
        try await socket.injectApproval(sessionID: "runtime-default")
        await settle { model.runDetails["run"]?.status == .waitingForInput }
        let input = try XCTUnwrap(model.mobilePendingInputs.first?.input)
        _ = await model.answer(input, result: .object(["choice": .string("deny")]))
        XCTAssertEqual(model.runDetails["run"]?.status, .working)
        XCTAssertEqual(model.runs.first?.status, .working)
        XCTAssertTrue(model.mobilePendingInputs.isEmpty)
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testColdConnectionAndProfileSwitchUseOnlyEachExplicitHomeAssignment() async throws {
        let (model, _, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        let defaultHome = StoredSessionID(rawValue: "explicit-default-home")
        let researchHome = StoredSessionID(rawValue: "explicit-research-home")
        model.classificationStore.update(for: .init(connectionID: connection.id, profile: "default")) { $0.homeSessionID = defaultHome }
        model.classificationStore.update(for: .init(connectionID: connection.id, profile: "research")) { $0.homeSessionID = researchHome }
        await model.connect(to: connection, token: "fixture")
        XCTAssertEqual(model.homeSessionID, defaultHome)
        XCTAssertEqual(model.selectedID, defaultHome)
        XCTAssertEqual(model.hierarchyDestination, .home)
        XCTAssertEqual(model.homeAvailability, .available)
        XCTAssertFalse(model.sessions.contains { $0.id == defaultHome }, "Bounded session-list omission is not unavailability")
        await model.connect(to: endpoint(id: connection.id, profile: "research"), token: "fixture")
        XCTAssertEqual(model.homeSessionID, researchHome)
        XCTAssertEqual(model.selectedID, researchHome)
        await model.connect(to: endpoint(), token: "fixture")
        XCTAssertNil(model.homeSessionID)
        XCTAssertEqual(model.homeAvailability, .unselected)
        XCTAssertEqual(model.hierarchyDestination, .home)
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testSuccessfulRequestReceiptsAreSafeAndScopedToTheirAuthoritativeConversation() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture")
        await model.newConversation()
        let socket = try XCTUnwrap(factory.sockets.last)
        try await socket.injectApproval(sessionID: "runtime-default")
        await settle { model.mobilePendingInputs.count == 1 }
        let approval = try XCTUnwrap(model.mobilePendingInputs.first?.input)
        _ = await model.answer(approval, result: .object(["choice": .string("once")]))
        let session = StoredSessionID(rawValue: "stored-default")
        XCTAssertEqual(model.requestReceipts(for: session).map(\.summary), ["You chose once"])
        try await socket.injectSecret(sessionID: "runtime-default")
        await settle { model.mobilePendingInputs.count == 1 }
        let secret = try XCTUnwrap(model.mobilePendingInputs.first?.input)
        _ = await model.answer(secret, result: .object(["value": .string("never-retain-this-secret")]))
        let summaries = model.requestReceipts(for: session).map(\.summary)
        XCTAssertEqual(summaries, ["You chose once", "You responded securely"])
        XCTAssertFalse(summaries.joined().contains("secret"))
        XCTAssertFalse(summaries.joined().contains("sensitive"))
        await model.connect(to: endpoint(id: connection.id, profile: "research"), token: "fixture")
        XCTAssertTrue(model.requestReceipts(for: session).isEmpty)
        await model.disconnect()
    }
}

private actor ScopedAutomationRunFixture {
    private(set) var calls: [(String, String)] = []
    private var held: CheckedContinuation<JSONValue, Never>?
    var shouldHold = false
    func hold() { shouldHold = true }
    func isHolding() -> Bool { held != nil }
    func load(_ endpoint: GatewayEndpoint, _ session: GatewaySession, _ id: String) async -> JSONValue {
        calls.append((endpoint.profile, id))
        if shouldHold { return await withCheckedContinuation { held = $0 } }
        return response(profile: endpoint.profile, id: id)
    }
    func release() { held?.resume(returning: response(profile: "default", id: "automation-19")); held = nil }
    private func response(profile: String, id: String) -> JSONValue {
        .object(["runs": .array([.object(["id": .string("run-for-\(id)"), "profile": .string(profile),
            "is_active": .bool(true)])])])
    }
    static func overview(_ profile: String) -> MobileActivitySnapshot {
        MobileActivitySnapshot(schedules: (0..<20).compactMap { MobileSchedule(json: .object([
            "id": .string("automation-\($0)"), "profile": .string(profile)])) })
    }
}

extension HermesAppModelTests {
    func testAutomationOutsideOverviewFanoutLoadsItsOwnRunsWithExplicitOwner() async throws {
        let reader = ScopedAutomationRunFixture()
        let (model, _, directory, _) = try fixture(loader: { _, endpoint, _ in ScopedAutomationRunFixture.overview(endpoint.profile) },
            automationRunsLoader: { await reader.load($0, $1, $2) })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(profile: "research"), token: "fixture")
        await model.refreshMobileActivity()
        XCTAssertTrue(model.runs.isEmpty)
        await model.navigate(to: .automation("automation-19"))
        XCTAssertEqual(model.automationRuns("automation-19").map(\.id), ["run-for-automation-19"])
        let calls = await reader.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "research")
        XCTAssertEqual(calls.first?.1, "automation-19")
        await model.disconnect()
    }

    func testLateAutomationRunListCannotPopulateAnotherProfile() async throws {
        let reader = ScopedAutomationRunFixture()
        await reader.hold()
        let (model, _, directory, _) = try fixture(loader: { _, endpoint, _ in ScopedAutomationRunFixture.overview(endpoint.profile) },
            automationRunsLoader: { await reader.load($0, $1, $2) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture")
        await model.refreshMobileActivity()
        let task = Task { await model.refreshAutomationRuns("automation-19") }
        for _ in 0..<100 {
            if await reader.isHolding() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await model.connect(to: endpoint(id: connection.id, profile: "research"), token: "fixture")
        await reader.release(); await task.value
        XCTAssertTrue(model.runs.isEmpty)
        XCTAssertTrue(model.loadingAutomationRunIDs.isEmpty)
        await model.disconnect()
    }

    func testVisibleRunObservationStopsWhenCancelledWithoutInterruptingHost() async throws {
        let changing = ChangingRunFixture()
        let (model, factory, directory, _) = try fixture(loader: { _, _, _ in await changing.snapshot() }, runLoader: ChangingRunFixture.transcript)
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.refreshMobileActivity()
        await model.navigate(to: .run("run"))
        let observation = Task { await model.observeRun("run") }
        await Task.yield()
        observation.cancel(); await observation.value
        let socket = try XCTUnwrap(factory.sockets.last)
        let methods = await socket.methods
        XCTAssertFalse(methods.contains("session.interrupt"))
        await model.disconnect()
    }

    func testRerunCannotSilentlyEnablePausedAutomation() async throws {
        let (model, _, directory, _) = try fixture(loader: { _, _, _ in
            MobileActivitySnapshot(schedules: [MobileSchedule(json: .object(["id": .string("paused"), "enabled": .bool(false)]))!])
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.refreshMobileActivity()
        await model.rerunAutomation("paused")
        XCTAssertEqual(model.hierarchyError, "Enable this automation before running it.")
        XCTAssertFalse(model.automations.first?.enabled ?? true)
        XCTAssertTrue(model.automationActionIDs.isEmpty)
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testCachedHomeCannotBypassAnAuthoritativeNotFound() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.newConversation()
        let home = try XCTUnwrap(model.selectedID)
        await model.chooseHome(home)
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.failResume(JSONRPCError(code: 4007, message: "session not found"))
        await model.openSession(home, force: true)
        XCTAssertEqual(model.homeAvailability, .unavailable)
        XCTAssertTrue(model.conversations[home]?.requiresHydration == true)
        await model.navigate(to: .home)
        XCTAssertEqual(model.homeAvailability, .unavailable, "A cached transcript cannot revive a confirmed missing session")
        XCTAssertEqual(model.homeSessionID, home)
        await model.disconnect()
    }

    func testWorkspaceLineageRecordsOnlyExplicitCreationOriginAsBranch() async throws {
        let (model, factory, directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint(), token: "fixture")
        await model.newConversation()
        let home = try XCTUnwrap(model.selectedID)
        await model.chooseHome(home)
        let workspace = try XCTUnwrap(model.createWorkspace(name: "Explicit workspace"))
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.createNextSession(as: "explicit-child")
        await model.newConversation(in: workspace, startedFrom: home)
        XCTAssertEqual(model.hierarchyClassification.lineage.count, 1)
        let lineage = try XCTUnwrap(model.hierarchyClassification.lineage.first)
        XCTAssertEqual(lineage.kind, .branch)
        XCTAssertEqual(lineage.parentSessionID, home)
        XCTAssertEqual(lineage.childSessionID.rawValue, "explicit-child")
        XCTAssertEqual(model.homeSessionID, home)
        await socket.createNextSession(as: "no-origin-child")
        await model.newConversation(in: workspace)
        XCTAssertEqual(model.hierarchyClassification.lineage.count, 1, "Current selection must not imply lineage or delegation")
        await model.disconnect()
    }
}

extension HermesAppModelTests {
    func testDisconnectKeepsLoadedListsButChangingOwnerClearsThem() async throws {
        let (model, factory, directory, _) = try fixture(loader: { _, endpoint, _ in activitySnapshot(endpoint.profile) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = endpoint()
        await model.connect(to: connection, token: "fixture")
        await model.refreshMobileActivity()
        model.markAllActivityRead()
        let loaded = model.mobileActivity
        let sessions = model.sessions
        let socket = try XCTUnwrap(factory.sockets.last)
        await socket.close()
        await settle { !model.isConnected }
        XCTAssertEqual(model.mobileActivity, loaded)
        XCTAssertEqual(model.sessions, sessions)
        XCTAssertEqual(model.unreadMobileRunCount, 0)
        await model.disconnect()
        XCTAssertEqual(model.mobileActivity, loaded)
        await model.connect(to: endpoint(id: connection.id, profile: "research"), token: "fixture")
        XCTAssertTrue(model.mobileActivity.runs.isEmpty, "Offline cache must never leak into another owner")
        XCTAssertTrue(model.mobileActivity.schedules.isEmpty)
        await model.disconnect()
    }
}

private actor BasicModelHTTP: GatewayHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var loginWaiter: CheckedContinuation<Void, Never>?
    var holdLogin = false
    func holdNextLogin() { holdLogin = true }
    func isHoldingLogin() -> Bool { loginWaiter != nil }
    func releaseLogin() { loginWaiter?.resume(); loginWaiter = nil }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path.hasSuffix("/api/status") {
            return GatewayHTTPResponse(data: Data(#"{"auth_required":true,"auth_providers":["basic"]}"#.utf8), status: 200)
        }
        if path.hasSuffix("/auth/password-login") {
            if holdLogin { await withCheckedContinuation { loginWaiter = $0 } }
            return GatewayHTTPResponse(data: Data(#"{"ok":true}"#.utf8), status: 200,
                headers: ["Set-Cookie": "hermes_session_at=fixture-cookie; Path=/; HttpOnly"])
        }
        if path.hasSuffix("/api/auth/me") {
            let authorized = request.value(forHTTPHeaderField: "Cookie")?.contains("fixture-cookie") == true
            return GatewayHTTPResponse(data: Data(#"{"provider":"basic","expires_at":4102444800}"#.utf8), status: authorized ? 200 : 401)
        }
        if path.hasSuffix("/api/auth/ws-ticket") {
            return GatewayHTTPResponse(data: Data(#"{"ticket":"fixture-ticket","ttl_seconds":30}"#.utf8), status: 200)
        }
        return GatewayHTTPResponse(data: Data("{}".utf8), status: path.hasSuffix("/auth/logout") ? 302 : 404)
    }
}

extension HermesAppModelTests {
    func testBasicSessionRoutesReadersReconnectsAndExplicitDisconnectClearsIntent() async throws {
        let http = BasicModelHTTP()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = HermesAppModel(defaults: defaults, draftStore: DraftStore(directory: directory),
            clientFactory: { GatewayClient(http: http, socketFactory: { _ in AppModelSocket() }) })
        let target = GatewayEndpoint(name: "Basic fixture", baseURL: URL(string: "http://127.0.0.1:8642")!, authentication: .basic)
        await model.connect(to: target, username: "fixture-user", password: "fixture-password", remember: false)
        XCTAssertTrue(model.isConnected, model.banner ?? "")
        XCTAssertTrue(model.desiredConnection)
        XCTAssertFalse(model.remembersSignIn)
        await model.reconnect()
        XCTAssertTrue(model.isConnected, model.banner ?? "")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/auth/password-login") }.count, 1)
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/api/auth/ws-ticket") }.count, 2)
        let reads = requests.filter { $0.url!.path.contains("telegram") }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("fixture-cookie") == true })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil })
        await model.signOut()
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.desiredConnection)
        XCTAssertFalse(model.remembersSignIn)
        let loggedOut = await http.requests.contains { $0.url!.path.hasSuffix("/auth/logout") }
        XCTAssertTrue(loggedOut)
        let restarted = HermesAppModel(defaults: defaults)
        XCTAssertFalse(restarted.remembersSignIn)
    }

    func testCancelBasicLoginCannotConnectAfterResponseArrives() async throws {
        let http = BasicModelHTTP(); await http.holdNextLogin()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = HermesAppModel(defaults: defaults,
            clientFactory: { GatewayClient(http: http, socketFactory: { _ in AppModelSocket() }) })
        let target = GatewayEndpoint(name: "Basic fixture", baseURL: URL(string: "http://127.0.0.1:8642")!, authentication: .basic)
        let login = Task { await model.connect(to: target, username: "user", password: "password", remember: false) }
        for _ in 0..<100 {
            if await http.isHoldingLogin() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let holding = await http.isHoldingLogin(); XCTAssertTrue(holding)
        await model.disconnect()
        await http.releaseLogin()
        await login.value
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isConnecting)
        XCTAssertFalse(model.desiredConnection)
        let ticketRequested = await http.requests.contains { $0.url!.path.hasSuffix("/api/auth/ws-ticket") }
        XCTAssertFalse(ticketRequested)
    }
}

extension HermesAppModelTests {
    func testRememberedBasicRestoreOptOutAndLegacyTokenBinding() async throws {
        let http = BasicModelHTTP()
        let store = CredentialStore(service: "talaria-auth-tests." + UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let target = GatewayEndpoint(name: "Basic fixture", baseURL: URL(string: "http://127.0.0.1:8642")!, authentication: .basic)
        defer { try? store.deleteSession(for: target); try? store.deleteToken(for: target) }
        func model() -> HermesAppModel {
            HermesAppModel(defaults: defaults, credentials: store,
                clientFactory: { GatewayClient(http: http, socketFactory: { _ in AppModelSocket() }) })
        }
        let first = model()
        await first.connect(to: target, username: "user", password: "password", remember: true)
        XCTAssertTrue(first.isConnected, first.banner ?? "")
        XCTAssertNotNil(try store.readSession(for: target))
        await first.disconnect()
        XCTAssertNotNil(try store.readSession(for: target))
        let restored = model()
        XCTAssertTrue(restored.remembersSignIn)
        await restored.connect(to: target, username: "", password: "", remember: false)
        XCTAssertTrue(restored.isConnected, restored.banner ?? "")
        XCTAssertNil(try store.readSession(for: target))
        await restored.disconnect()
        XCTAssertFalse(model().remembersSignIn)
        var legacy = target; legacy.authentication = .sessionToken
        try store.save("legacy-fixture", account: legacy.id.uuidString)
        XCTAssertEqual(try store.readToken(for: legacy, legacyEndpoint: legacy), "legacy-fixture")
        var changed = legacy; changed.baseURL = URL(string: "http://127.0.0.1:8643")!
        XCTAssertNil(try store.readToken(for: changed, legacyEndpoint: legacy))
        try store.saveToken("bound-fixture", for: legacy)
        XCTAssertNil(try store.read(account: legacy.id.uuidString))
        XCTAssertEqual(try store.readToken(for: legacy, legacyEndpoint: legacy), "bound-fixture")
        XCTAssertNil(try store.readToken(for: changed, legacyEndpoint: legacy))
    }
}
