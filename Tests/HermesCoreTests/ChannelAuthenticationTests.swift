import Foundation
import XCTest
@testable import HermesCore
import HermesProtocol
@testable import HermesTransport

private actor ChannelAuthenticationSocket: GatewaySocket {
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


private actor ChannelAuthenticationHTTP: GatewayHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var expired = false
    func expire() { expired = true }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        func response(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> GatewayHTTPResponse {
            GatewayHTTPResponse(data: Data(body.utf8), status: status, headers: headers)
        }
        if path.hasSuffix("/api/status") { return response(#"{"auth_required":true,"auth_providers":["basic"]}"#) }
        if path.hasSuffix("/auth/password-login") {
            return response(#"{"ok":true}"#, headers: ["Set-Cookie": "hermes_session_at=channel-cookie; Path=/; HttpOnly"])
        }
        guard request.value(forHTTPHeaderField: "Cookie")?.contains("channel-cookie") == true, !expired else {
            return response("private error", status: 401)
        }
        if path.hasSuffix("/api/auth/me") { return response(#"{"provider":"basic","expires_at":4102444800}"#) }
        if path.hasSuffix("/api/auth/ws-ticket") { return response(#"{"ticket":"channel-ticket","ttl_seconds":30}"#) }
        if path.hasSuffix("/sessions/search") {
            return response(#"{"results":[{"session_id":"channel","id":"channel","profile":"work","source":"telegram","title":"Needle"}]}"#)
        }
        if path.hasSuffix("/sessions") {
            let source = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source" }?.value
            return response(source == nil || source == "telegram"
                ? #"{"sessions":[{"id":"channel","profile":"work","source":"telegram","title":"Channel"}],"total":1}"#
                : #"{"sessions":[],"total":0}"#)
        }
        if path.hasSuffix("/messages") {
            return response(#"{"session_id":"channel","profile":"work","messages":[{"id":1,"role":"assistant","content":"Mirrored reply"}],"pagination":{"limit":100,"offset":0,"returned":1,"order":"latest"}}"#)
        }
        if path.hasSuffix("/sessions/channel") || path.hasSuffix("/sessions/probe") {
            return request.httpMethod == "PATCH" ? response(#"{"ok":true,"title":"Renamed"}"#)
                : response(#"{"id":"probe","profile":"work","source":"telegram","title":"Probe"}"#)
        }
        return response("{}", status: 404)
    }
}

@MainActor
final class ChannelAuthenticationTests: XCTestCase {
    func testBasicChannelsReuseSessionWithoutTokenAndRecoverExpiry() async throws {
        let http = ChannelAuthenticationHTTP()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = HermesAppModel(defaults: defaults, draftStore: DraftStore(directory: directory),
            clientFactory: { GatewayClient(http: http, socketFactory: { _ in ChannelAuthenticationSocket() }) })
        let configured = GatewayEndpoint(name: "SSH Basic", baseURL: URL(string: "http://127.0.0.1:9119")!, profile: "work",
            authentication: .basic)
        var active = configured; active.baseURL = URL(string: "http://127.0.0.1:24567")!
        await model.connect(to: active, username: "fixture", password: "password", remember: false)
        XCTAssertTrue(model.isConnected, model.banner ?? "")
        XCTAssertNil(model.channelError)
        XCTAssertEqual(model.channelGroups.first?.sessions.first?.id.rawValue, "channel")
        await model.openSession(StoredSessionID(rawValue: "channel"))
        XCTAssertTrue(model.isPassiveChannel)
        XCTAssertEqual(model.conversation?.messages.count, 1)
        model.searchText = "needle"
        await model.searchChannelHistory()
        XCTAssertEqual(model.channelSearchResults.first?.id.rawValue, "channel")
        await model.renameChannel(id: StoredSessionID(rawValue: "channel"), title: "Renamed")
        XCTAssertNil(model.channelError)
        XCTAssertEqual(model.sessions.first { $0.id.rawValue == "channel" }?.title, "Renamed")
        await model.openSession(StoredSessionID(rawValue: "probe"))
        XCTAssertTrue(model.isPassiveChannel)
        let requests = await http.requests
        let channelReads = requests.filter { $0.url!.path.contains("/sessions") }
        XCTAssertTrue(channelReads.contains { $0.httpMethod == "PATCH" })
        XCTAssertTrue(channelReads.contains { $0.url!.path.hasSuffix("/sessions/probe") })
        XCTAssertTrue(channelReads.contains { $0.url!.path.hasSuffix("/sessions/search") })
        XCTAssertTrue(channelReads.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("channel-cookie") == true })
        XCTAssertTrue(requests.allSatisfy { $0.url?.port == 24567 })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil })
        XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/auth/password-login") }.count, 1)
        let retainedMessages = model.conversation?.messages.map(\.id)
        model.draft = "Keep this draft"
        await http.expire()
        await model.refreshChannelHistory()
        XCTAssertNotNil(model.channelHistoryError)
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.showConnection)
        XCTAssertEqual(model.conversation?.messages.map(\.id), retainedMessages)
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertFalse(model.canSend)
        await model.disconnect()
    }
}
