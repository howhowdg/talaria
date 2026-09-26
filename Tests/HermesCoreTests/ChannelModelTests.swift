import Foundation
import XCTest
@testable import HermesCore
import HermesProtocol
@testable import HermesTransport

private actor ChannelHTTP: GatewayHTTPTransport {
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        GatewayHTTPResponse(data: Data(#"{"auth_required":false}"#.utf8), status: 200)
    }
}

private actor ChannelSocket: GatewaySocket {
    var frames = [#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"heartbeat":false}}}"#]
    var waiter: CheckedContinuation<String, Error>?
    var closed = false
    private(set) var methods: [String] = []
    func send(_ text: String) async throws {
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard let method = frame["method"]?.stringValue, let id = frame["id"] else { return }
        methods.append(method)
        let profile = frame["params"]?["profile"]?.stringValue ?? "default"
        let result: JSONValue
        switch method {
        case "session.list": result = .object(["sessions": .array([])])
        case "profiles.list": result = .object(["profiles": .array(["default", "research"].map { .object(["name": .string($0)]) })])
        case "session.resume": result = .object(["session_id": .string("runtime-" + profile), "stored_session_id": frame["params"]?["session_id"] ?? .string("missing"), "messages": .array([]), "running": .bool(false), "info": .object(["title": .string("Channel")])])
        default: result = .object([:])
        }
        let response = String(decoding: try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])), as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: response) } else { frames.append(response) }
    }
    func event(_ type: String, sessionID: String, payload: JSONValue) throws {
        let event = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object(["type": .string(type), "session_id": .string(sessionID), "payload": payload])])
        let text = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: text) } else { frames.append(text) }
    }
    func receive() async throws -> String {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: URLError(.cancelled)); waiter = nil }
}

private actor ChannelFixture {
    var messageCount = 2
    var persistedRows: [(role: String, text: String)]?
    func persist(_ rows: [(role: String, text: String)]) { persistedRows = rows; messageCount = rows.count }
    var sessionCount = 601
    var deletedIDs = Set<String>()
    private(set) var detailIDs: [String] = []
    func setSessions(_ count: Int) { sessionCount = count }
    func delete(_ id: String) { deletedIDs.insert(id) }
    var error: GatewayTransportError?
    var hold = false
    var suspended: CheckedContinuation<Void, Never>?
    func setCount(_ count: Int) { messageCount = count }
    func fail(_ error: GatewayTransportError?) { self.error = error }
    func holdNext() { hold = true }
    func isHolding() -> Bool { suspended != nil }
    func release() { suspended?.resume(); suspended = nil }
    func read(_ endpoint: GatewayEndpoint, _ resource: GatewayReadEndpoint) async throws -> JSONValue {
        if hold { hold = false; await withCheckedContinuation { suspended = $0 } }
        if let error { throw error }
        let profile = endpoint.profile
        switch resource {
        case .channelSessions(let source, let limit, let offset):
            let total = source == nil || source == "telegram" ? sessionCount : 0
            let rows = (min(offset, total)..<min(offset + limit, total)).map { index in
                JSONValue.object(["id": .string("\(profile)-\(index)"), "source": .string("telegram"), "profile": .string(profile), "title": .string("Thread \(index)"), "last_active": .number(Double(1000 + index))])
            }
            return .object(["sessions": .array(rows), "total": .number(Double(total))])
        case .channelSession(let id):
            detailIDs.append(id)
            if deletedIDs.contains(id) { throw GatewayTransportError.httpStatus(404) }
            return .object(["id": .string(id), "profile": .string(profile), "source": .string("telegram"), "title": .string("Saved " + id)])
        case .channelMessages(let id, let limit, let offset):
            let end = max(0, messageCount - offset), start = max(0, end - limit)
            let rows = (start..<end).map { index in JSONValue.object(["id": .number(Double(index + 1)), "session_id": .string(id), "role": .string(persistedRows?[index].role ?? "assistant"), "content": .string(persistedRows?[index].text ?? "Reply \(index)")]) }
            return .object(["profile": .string(profile), "session_id": .string(id), "messages": .array(rows), "pagination": .object(["offset": .number(Double(offset)), "limit": .number(Double(limit)), "returned": .number(Double(rows.count)), "order": .string("latest")])])
        default: return .object([:])
        }
    }
}

@MainActor
final class ChannelModelTests: XCTestCase {
    private func fixture(saved: ((inout HierarchyClassification) -> Void)? = nil) throws -> (HermesAppModel, ChannelFixture, URL, GatewayEndpoint, @MainActor () -> [ChannelSocket]) {
        let reader = ChannelFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var sockets: [ChannelSocket] = []
        let model = HermesAppModel(defaults: defaults, draftStore: DraftStore(directory: directory),
            telegramTopicsLoader: { _, _ in throw GatewayTransportError.httpStatus(404) },
            channelReader: { session, resource in try await reader.read(session.endpoint, resource) },
            clientFactory: { let socket = ChannelSocket(); sockets.append(socket); return GatewayClient(http: ChannelHTTP(), socketFactory: { _ in socket }) })
        let endpoint = GatewayEndpoint(name: "Fixture", baseURL: URL(string: "http://127.0.0.1:8642")!, profile: "default")
        if let saved { model.classificationStore.update(for: SessionOwner(connectionID: endpoint.id, profile: endpoint.profile), saved) }
        return (model, reader, directory, endpoint, { sockets })
    }

    private func assertChannelSnapshot(_ model: HermesAppModel, file: StaticString = #filePath, line: UInt = #line) {
        let ids = model.channelSessionIDs
        let probes = ids.union(model.sessions.map(\.id)).union([
            StoredSessionID(rawValue: "unknown"), StoredSessionID(rawValue: "default-500"),
            StoredSessionID(rawValue: "default-0"), StoredSessionID(rawValue: "deleted-pin")
        ])
        for id in probes {
            XCTAssertEqual(ids.contains(id), model.isChannelSession(id), id.rawValue, file: file, line: line)
        }
    }

    func testChannelFilterSnapshotBenchmark() async throws {
        let (model, _, directory, endpoint, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        for _ in 0..<6 { await model.loadMoreChannels(source: "telegram") }
        XCTAssertEqual(model.otherConversations.count, 601)
        let clock = ContinuousClock()
        var oldIDs: [StoredSessionID] = []
        let oldDuration = clock.measure {
            for _ in 0..<10 {
                oldIDs = model.otherConversations.filter { !model.isChannelSession($0.id) }.map(\.id)
            }
        }
        var snapshotIDs: [StoredSessionID] = []
        let snapshotDuration = clock.measure {
            for _ in 0..<10 {
                let channelIDs = model.channelSessionIDs
                snapshotIDs = model.otherConversations.filter { !channelIDs.contains($0.id) }.map(\.id)
            }
        }
        XCTAssertEqual(snapshotIDs, oldIDs)
        print("Channel filter, 601 channels / 10 iterations: old=\(oldDuration), snapshot=\(snapshotDuration)")
        await model.disconnect()
    }

    func testDiscoveryPagesBeyondFiveHundred() async throws {
        let (model, _, directory, endpoint, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        XCTAssertEqual(model.channelGroups.first?.sessions.count, 100)
        assertChannelSnapshot(model)
        XCTAssertEqual(model.channelGroups.first?.hasMore, true)
        for _ in 0..<6 { await model.loadMoreChannels(source: "telegram") }
        XCTAssertEqual(model.channelGroups.first?.sessions.count, 601)
        assertChannelSnapshot(model)
        XCTAssertEqual(model.channelGroups.first?.hasMore, false)
        await model.disconnect()
    }

    func testPassiveBrowsingHomeWorkspaceUpdatesAndExplicitContinuation() async throws {
        let (model, reader, directory, endpoint, sockets) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        let id = StoredSessionID(rawValue: "default-0")
        await model.openSession(id)
        XCTAssertTrue(model.isPassiveChannel)
        let originalIDs = model.conversation?.messages.map(\.id) ?? []
        XCTAssertEqual(originalIDs.count, 2)
        model.draft = "Do not send while passive"
        await model.send()
        await model.chooseHome(id)
        let other = StoredSessionID(rawValue: "default-1")
        let workspace = try XCTUnwrap(model.createWorkspace(name: "Channel", sessionID: other))
        await model.navigate(to: .workspace(workspace))
        XCTAssertTrue(model.isPassiveChannel)
        await model.openSession(id)
        await reader.setCount(3)
        await model.refreshChannelHistory()
        XCTAssertEqual(Array((model.conversation?.messages.map(\.id) ?? []).prefix(2)), originalIDs)
        XCTAssertEqual(model.conversation?.messages.count, 3)
        let socket = try XCTUnwrap(sockets().last)
        let passiveMethods = await socket.methods
        XCTAssertFalse(passiveMethods.contains("session.resume"))
        XCTAssertFalse(passiveMethods.contains("prompt.submit"))
        await model.continueChannelInTalaria()
        assertChannelSnapshot(model)
        XCTAssertFalse(model.isPassiveChannel)
        let continuedMethods = await socket.methods
        XCTAssertEqual(continuedMethods.filter { $0 == "session.resume" }.count, 1)
        model.draft = "Continue here"
        XCTAssertTrue(model.canSend)
        await model.send()
        let sentMethods = await socket.methods
        XCTAssertEqual(sentMethods.filter { $0 == "prompt.submit" }.count, 1)
        await model.disconnect()
    }

    func testErrorsRetainHistoryAndProfileSwitchDropsLateResponsesAndPreferences() async throws {
        let (model, reader, directory, endpoint, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        let id = StoredSessionID(rawValue: "default-0")
        await model.openSession(id)
        let messages = model.conversation?.messages.map(\.id)
        model.toggleChannelPin(id); model.toggleChannelCollapsed("telegram")
        await reader.fail(.authenticationRejected)
        await model.refreshChannelHistory()
        await model.refreshChannels()
        XCTAssertEqual(model.conversation?.messages.map(\.id), messages)
        XCTAssertNotNil(model.channelHistoryError); XCTAssertNotNil(model.channelError)
        await reader.fail(nil)
        await reader.holdNext()
        let oldRefresh = Task { await model.refreshChannelHistory() }
        for _ in 0..<100 { if await reader.isHolding() { break }; try await Task.sleep(for: .milliseconds(2)) }
        let holding = await reader.isHolding()
        XCTAssertTrue(holding)
        var research = endpoint; research.profile = "research"
        await model.connect(to: research, token: "fixture")
        XCTAssertEqual(model.endpoint?.profile, "research")
        assertChannelSnapshot(model)
        XCTAssertFalse(model.channelSessionIDs.contains(id))
        await reader.release(); await oldRefresh.value
        XCTAssertFalse(model.isChannelPinned(id)); XCTAssertFalse(model.isChannelCollapsed("telegram"))
        XCTAssertFalse(model.sessions.contains { $0.id == id })
        await model.connect(to: endpoint, token: "fixture")
        XCTAssertEqual(model.endpoint?.profile, "default")
        XCTAssertTrue(model.isChannelPinned(id)); XCTAssertTrue(model.isChannelCollapsed("telegram"))
        await model.disconnect()
    }

    func testSavedAssignmentsBeyondFirstPageOpenPassivelyOnFreshModel() async throws {
        let home = StoredSessionID(rawValue: "default-500")
        let workspaceThread = StoredSessionID(rawValue: "default-501")
        let workspace = TalariaWorkspace(name: "Saved workspace", sessionIDs: [workspaceThread])
        let (model, reader, directory, endpoint, sockets) = try fixture(saved: {
            $0.homeSessionID = home; $0.workspaces = [workspace]
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        await model.navigate(to: .home)
        XCTAssertEqual(model.selectedID, home)
        XCTAssertTrue(model.isPassiveChannel)
        XCTAssertEqual(model.conversation?.messages.count, 2)
        await model.navigate(to: .workspace(workspace.id))
        XCTAssertEqual(model.selectedID, workspaceThread)
        XCTAssertTrue(model.isPassiveChannel)
        XCTAssertEqual(model.conversation?.messages.count, 2)
        let details = await reader.detailIDs
        XCTAssertTrue(details.contains(home.rawValue))
        XCTAssertTrue(details.contains(workspaceThread.rawValue))
        let methods = await sockets().last?.methods ?? []
        XCTAssertFalse(methods.contains("session.resume"))
        await model.disconnect()
    }

    func testContinuedChannelKeepsLiveOutputAndDraftAcrossStoredIDRotation() async throws {
        let (model, reader, directory, endpoint, sockets) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        await model.openSession(StoredSessionID(rawValue: "default-0"))
        await model.continueChannelInTalaria()
        assertChannelSnapshot(model)
        model.draft = "Keep this draft after compression"
        let socket = try XCTUnwrap(sockets().last)
        let original = StoredSessionID(rawValue: "default-0")
        let owner = try XCTUnwrap(model.currentHierarchyOwner)
        model.classificationStore.rememberPlace("latest-row", for: original, owner: owner)
        let rotated = StoredSessionID(rawValue: "default-1")
        try await socket.event("session.info", sessionID: "runtime-default", payload: .object(["stored_session_id": .string(rotated.rawValue)]))
        for _ in 0..<100 {
            if model.selectedID == rotated { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.selectedID, rotated)
        XCTAssertEqual(model.classificationStore.place(for: rotated, owner: owner).visibleMessageID, "latest-row")
        XCTAssertFalse(model.isPassiveChannel)
        XCTAssertEqual(model.draft, "Keep this draft after compression")
        try await socket.event("message.start", sessionID: "runtime-default", payload: .object([:]))
        try await socket.event("message.delta", sessionID: "runtime-default", payload: .object(["text": .string("Live answer after compression")]))
        try await socket.event("message.complete", sessionID: "runtime-default", payload: .object(["text": .string("Live answer after compression")]))
        for _ in 0..<100 {
            if model.conversation?.messages.contains(where: { $0.text == "Live answer after compression" }) == true { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        // Let the completion-triggered list/history refresh run too.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(model.isPassiveChannel)
        XCTAssertEqual(model.draft, "Keep this draft after compression")
        XCTAssertTrue(model.conversation?.messages.contains(where: { $0.text == "Live answer after compression" }) == true)
        let persisted = [("assistant", "Reply 0"), ("assistant", "Reply 1"),
                         ("assistant", "Live answer after compression"),
                         ("user", "Later Telegram question"), ("assistant", "Later Telegram answer")]
        await reader.persist(persisted)
        await model.refreshChannelHistory()
        XCTAssertEqual(model.conversation?.messages.filter { $0.text == "Live answer after compression" }.count, 1)
        XCTAssertEqual(model.conversation?.messages.map(\.text), persisted.map { $0.1 })
        XCTAssertEqual(model.conversation?.messages.suffix(2).map(\.role), [.user, .assistant])
        XCTAssertEqual(model.draft, "Keep this draft after compression")
        let later = persisted + [("user", "Another external question"), ("assistant", "Another external answer")]
        await reader.persist(later)
        await model.refreshChannelHistory()
        XCTAssertEqual(model.conversation?.messages.filter { $0.text == "Live answer after compression" }.count, 1)
        XCTAssertEqual(model.conversation?.messages.map(\.text), later.map { $0.1 })
        XCTAssertEqual(model.draft, "Keep this draft after compression")
        model.classificationStore.rememberPlace(nil, for: rotated, owner: owner)
        let finalID = StoredSessionID(rawValue: "default-2")
        model.classificationStore.rememberPlace("stale-row", for: finalID, owner: owner)
        try await socket.event("session.info", sessionID: "runtime-default", payload: .object(["stored_session_id": .string(finalID.rawValue)]))
        for _ in 0..<100 {
            if model.selectedID == finalID { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.selectedID, finalID)
        XCTAssertNil(model.classificationStore.place(for: finalID, owner: owner).visibleMessageID)
        assertChannelSnapshot(model)
        await model.disconnect()
    }

    func testPagingProgressSurvivesInterleavedRefreshAndStaysComplete() async throws {
        let (model, _, directory, endpoint, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        for page in 1...6 {
            await model.loadMoreChannels(source: "telegram")
            await model.refreshChannels()
            XCTAssertEqual(model.channelGroups.first?.sessions.count, min(601, (page + 1) * 100))
        }
        XCTAssertEqual(model.channelGroups.first?.hasMore, false)
        await model.refreshChannels()
        XCTAssertEqual(model.channelGroups.first?.sessions.count, 601)
        assertChannelSnapshot(model)
        XCTAssertEqual(model.channelGroups.first?.hasMore, false)
        await model.disconnect()
    }

    func testEmptyAuthoritativeListRemovesRowsWithoutDiscardingCachedHistory() async throws {
        let (model, reader, directory, endpoint, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.connect(to: endpoint, token: "fixture")
        let id = StoredSessionID(rawValue: "default-0")
        await model.openSession(id)
        let cached = model.conversations[id]?.messages
        await model.openSession(StoredSessionID(rawValue: "default-1"))
        await reader.setSessions(0)
        await model.refreshChannels()
        XCTAssertFalse(model.channelGroups.flatMap(\.sessions).contains { $0.id == id })
        assertChannelSnapshot(model)
        XCTAssertTrue(model.channelSessionIDs.contains(id)) // Cached history remains a channel.
        XCTAssertEqual(model.conversations[id]?.messages, cached)
        await model.disconnect()
    }

    func testMissingSavedPinDoesNotBlockOtherPinsAndCanBeUnpinned() async throws {
        let missing = StoredSessionID(rawValue: "deleted-pin")
        let existing = StoredSessionID(rawValue: "default-500")
        let (model, reader, directory, endpoint, _) = try fixture(saved: {
            $0.pinnedChannelIDs = [missing, existing]
        })
        defer { try? FileManager.default.removeItem(at: directory) }
        await reader.delete(missing.rawValue)
        await model.connect(to: endpoint, token: "fixture")
        XCTAssertNil(model.channelError)
        XCTAssertTrue(model.pinnedChannelSessions.contains { $0.id == existing })
        let placeholder = try XCTUnwrap(model.pinnedChannelSessions.first { $0.id == missing })
        XCTAssertTrue(placeholder.displayTitle.localizedCaseInsensitiveContains("unavailable"))
        XCTAssertEqual(model.channelGroups.first?.sessions.count, 100)
        assertChannelSnapshot(model)
        model.toggleChannelPin(missing)
        XCTAssertFalse(model.isChannelPinned(missing))
        XCTAssertFalse(model.pinnedChannelSessions.contains { $0.id == missing })
        assertChannelSnapshot(model)
        await model.disconnect()
    }

}
