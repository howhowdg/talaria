import Foundation
import XCTest
import HermesProtocol
@testable import HermesTransport

private actor StubHTTP: GatewayHTTPTransport {
    var requests: [URLRequest] = []
    let payload: String
    let status: Int

    init(payload: String = #"{"auth_required":false,"auth_providers":[],"auth_flows":[],"version":"fixture"}"#, status: Int = 200) {
        self.payload = payload
        self.status = status
    }

    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        return GatewayHTTPResponse(data: Data(payload.utf8), status: status)
    }
}

private actor ScriptedSocket: GatewaySocket {
    var sent: [JSONValue] = []
    var rawSent: [String] = []
    private var queued: [String] = []
    private var reader: CheckedContinuation<String, Error>?
    private var closed = false
    let acknowledgeHeartbeat: Bool
    let capabilityError: Int?
    let results: [String: JSONValue]
    let eventsBeforeCapabilities: [String]

    init(ready: Bool = true, heartbeat: Bool = false, acknowledgeHeartbeat: Bool = true,
         capabilityError: Int? = nil, results: [String: JSONValue] = [:], eventsBeforeCapabilities: [String] = []) {
        self.acknowledgeHeartbeat = acknowledgeHeartbeat
        self.capabilityError = capabilityError
        self.results = results
        self.eventsBeforeCapabilities = eventsBeforeCapabilities
        if ready {
            queued = ["{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"type\":\"gateway.ready\",\"payload\":{\"heartbeat\":\(heartbeat)}}}"]
        }
    }

    func send(_ text: String) async throws {
        guard !closed else { throw URLError(.networkConnectionLost) }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        sent.append(frame)
        rawSent.append(text)
        guard let id = frame["id"], let method = frame["method"]?.stringValue else { return }
        if method == "hold" || (method == "gateway.ping" && !acknowledgeHeartbeat) { return }
        if method == "client.capabilities" {
            for event in eventsBeforeCapabilities { push(event) }
            if let capabilityError {
                push(String(decoding: try JSONEncoder().encode(JSONValue.object([
                    "jsonrpc": .string("2.0"), "id": id,
                    "error": .object(["code": .number(Double(capabilityError)), "message": .string("Unsupported capability")])
                ])), as: UTF8.self))
                return
            }
        }
        let result: JSONValue
        if let fixture = results[method] { result = fixture }
        else if method == "client.capabilities" { result = .object(["server_requests": .array([.string("approval")])]) }
        else if method == "gateway.ping" { result = .object(["ok": .bool(true)]) }
        else if method == "session.resume" {
            result = .object([
                "session_id": .string("live-1"), "messages": .array([]),
                "open_requests": .array([.object([
                    "id": .string("srq-replayed"), "method": .string("clarify"),
                    "params": .object(["session_id": .string("live-1"), "question": .string("Continue?")])
                ])])
            ])
        } else { result = frame["params"] ?? .null }
        push(try String(decoding: JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])), as: UTF8.self))
    }

    func receive() async throws -> String {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { throw URLError(.networkConnectionLost) }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func push(_ text: String) {
        if let reader {
            self.reader = nil
            reader.resume(returning: text)
        } else { queued.append(text) }
    }

    func close() async {
        closed = true
        let previous = reader
        reader = nil
        previous?.resume(throwing: URLError(.cancelled))
    }

    func frames() -> [JSONValue] { sent }
}

private actor DelayedStatusHTTP: GatewayHTTPTransport {
    private var waiter: CheckedContinuation<GatewayHTTPResponse, Error>?
    private(set) var oldRequestStarted = false

    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        if request.url?.path == "/old/api/status" {
            oldRequestStarted = true
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        return GatewayHTTPResponse(data: Data(#"{"auth_required":false}"#.utf8), status: 200)
    }

    func releaseOldRequest() {
        waiter?.resume(returning: GatewayHTTPResponse(data: Data(#"{"auth_required":false}"#.utf8), status: 200))
        waiter = nil
    }
}

@MainActor
final class TransportTests: XCTestCase {
    func testSSHAddressAcceptsPastedTargetAndRejectsMalformedInput() {
        XCTAssertEqual(GatewaySSHDestination.parse("user@mini.tailnet:2222"),
                       GatewaySSHDestination(host: "mini.tailnet", user: "user", sshPort: 2222))
        XCTAssertEqual(GatewaySSHDestination.parse("ssh user@mini"),
                       GatewaySSHDestination(host: "mini", user: "user"))
        XCTAssertNil(GatewaySSHDestination.parse("user@@mini"))
        XCTAssertNil(GatewaySSHDestination.parse("user@mini:0"))
        XCTAssertNil(GatewaySSHDestination.parse("-oProxyCommand=evil"))
        let legacy = GatewaySSHDestination(host: "mini", gatewayPort: 9443, gatewayPath: "/hermes")
        XCTAssertTrue(legacy.attachesExistingGateway)
        XCTAssertFalse(GatewaySSHDestination(host: "mini").attachesExistingGateway)
        var managed = legacy
        managed.useExistingGateway = false
        XCTAssertFalse(managed.attachesExistingGateway)
    }

    private func endpoint(_ url: String = "http://127.0.0.1:8642", profile: String = "default") -> GatewayEndpoint {
        GatewayEndpoint(name: "Fixture", baseURL: URL(string: url)!, profile: profile)
    }

    private func client(socket: ScriptedSocket, http: StubHTTP = StubHTTP(), timing: GatewayTiming = GatewayTiming()) -> GatewayClient {
        GatewayClient(http: http, socketFactory: { _ in socket }, timing: timing)
    }

    func testRoutesPreservePrefixEncodeScopeAndKeepTokenOutOfPersistedEndpoint() throws {
        let endpoint = endpoint("https://host.example/hermes/", profile: "research & code")
        let routes = try GatewayRoutes(endpoint: endpoint)
        let status = try routes.statusRequest(token: "secret & ?")
        XCTAssertEqual(status.url?.path, "/hermes/api/status")
        let statusItems = URLComponents(url: status.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(statusItems, [URLQueryItem(name: "profile", value: "research & code")])
        XCTAssertEqual(status.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret & ?")
        let socket = try routes.socketRequest(token: "secret & ?")
        XCTAssertEqual(socket.url?.scheme, "wss")
        XCTAssertEqual(socket.url?.path, "/hermes/api/ws")
        XCTAssertEqual(URLComponents(url: socket.url!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "secret & ?")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self).contains("secret"))
    }

    func testUnsafeEndpointURLsAreRejected() throws {
        for url in ["http://host.example", "http://100.63.255.255", "http://100.128.0.1", "http://100.bad.64.1.2", "http://0100.64.0.1", "https://user:password@host.example", "https://host.example?token=secret", "https://host.example/#fragment", "file:///tmp/hermes", "http://127.0.0.1.evil.example"] {
            XCTAssertThrowsError(try GatewayRoutes(endpoint: endpoint(url)), url)
        }
        for url in ["http://127.0.0.1:9000", "http://localhost:9000", "http://[::1]:9000", "http://100.64.0.1:8642", "http://100.127.255.254:8642", "https://host.example"] {
            XCTAssertNoThrow(try GatewayRoutes(endpoint: endpoint(url)), url)
        }
        XCTAssertEqual(try GatewayRoutes(endpoint: endpoint("http://100.64.1.2:8642")).socketRequest(token: "test").url?.scheme, "ws")
    }

    func testConnectDeclaresCapabilitiesAndRoundTripsRawJSONValues() async throws {
        let socket = ScriptedSocket()
        let http = StubHTTP()
        let client = client(socket: socket, http: http)
        try await client.connect(to: endpoint(profile: "research"), token: "fixture-secret")
        let raw = #"{"text":"quotes \" backslash \\ newline\n雪","null":null,"nested":[true,42,{"future":false}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        let result = try await client.request("fixture.echo", params: value)
        XCTAssertEqual(result, value)
        let sent = await socket.frames()
        XCTAssertEqual(sent.first?["method"]?.stringValue, "client.capabilities")
        XCTAssertEqual(sent.first?["params"]?["server_requests"], .bool(true))
        XCTAssertNil(sent.first?["params"]?["profile"], "Do not add profile to strict unscoped contracts")
        let httpRequests = await http.requests
        XCTAssertEqual(URLComponents(url: httpRequests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "research")
        await client.disconnect()
    }

    func testInteractiveAuthAndHTTPRejectionAreActionable() async throws {
        for (http, expected) in [(StubHTTP(payload: #"{"auth_required":true,"auth_providers":["oidc"],"auth_flows":["cookie","native_pkce"]}"#), GatewayTransportError.interactiveAuthenticationRequired),
                                 (StubHTTP(payload: #"{"auth_required":true,"auth_providers":["token"],"auth_flows":["cookie"]}"#), .interactiveAuthenticationRequired),
                                 (StubHTTP(status: 401), .authenticationRejected)] {
            let socket = ScriptedSocket()
            let client = client(socket: socket, http: http)
            do {
                try await client.connect(to: endpoint(), token: "do-not-expose")
                XCTFail("Expected authentication failure")
            } catch {
                XCTAssertEqual(error as? GatewayTransportError, expected)
                XCTAssertFalse(error.localizedDescription.contains("do-not-expose"))
            }
            let sent = await socket.frames()
            XCTAssertTrue(sent.isEmpty)
        }
    }

    func testOnlyMethodNotFoundAllowsLegacyCapabilityFallback() async throws {
        for code in [-32600, -32602, -32603, -32000] {
            let socket = ScriptedSocket(capabilityError: code)
            let client = client(socket: socket)
            do {
                try await client.connect(to: endpoint(), token: "fixture")
                XCTFail("Capability errors other than method-not-found must fail")
            } catch { XCTAssertEqual((error as? JSONRPCError)?.code, code) }
            let frames = await socket.frames()
            XCTAssertEqual(frames.count, 1, "Do not retry negotiation")
        }
        let socket = ScriptedSocket(capabilityError: -32601)
        let client = client(socket: socket)
        try await client.connect(to: endpoint(), token: "fixture")
        let result = try await client.request("fixture.echo", params: .string("legacy connected"))
        XCTAssertEqual(result, .string("legacy connected"))
        await client.disconnect()
    }

    func testLegacyApprovalDuringNegotiationRequiresExplicitScopedAnswer() async throws {
        let event = #"{"jsonrpc":"2.0","method":"event","params":{"type":"approval.request","session_id":"live-legacy","payload":{"request_id":"approval-1","command":"fixture command","description":"Permission required"}}}"#
        let socket = ScriptedSocket(capabilityError: -32601, results: [
            "approval.respond": .object(["resolved": .number(1)]),
            "approval.pending": .object(["approvals": .array([])])
        ], eventsBeforeCapabilities: [event])
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        var approval: GatewayServerRequest?
        for _ in 0..<4 {
            switch await updates.next() {
            case .request(let request): approval = request
            case .connected: break
            default: break
            }
        }
        let request = try XCTUnwrap(approval)
        XCTAssertEqual(request.method, "approval")
        XCTAssertEqual(request.params["session_id"], .string("live-legacy"))
        let before = await socket.frames()
        XCTAssertFalse(before.contains { $0["method"]?.stringValue == "approval.respond" },
                       "Receiving an approval must never answer it automatically")
        try await client.respond(to: request.id, result: .object(["choice": .string("once")]))
        let frames = await socket.frames()
        let response = try XCTUnwrap(frames.first { $0["method"]?.stringValue == "approval.respond" })
        XCTAssertEqual(response["params"]?["request_id"], .string("approval-1"))
        XCTAssertEqual(response["params"]?["session_id"], .string("live-legacy"))
        XCTAssertEqual(response["params"]?["choice"], .string("once"))
        XCTAssertEqual(response["params"]?["all"], .bool(false))
        XCTAssertNil(response["result"], "Legacy replies are RPC calls, not modern server-request replies")
        do {
            try await client.respond(to: request.id, result: .object(["choice": .string("always")]))
            XCTFail("A second answer must not be sent")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .unknownServerRequest) }
        await client.disconnect()
    }

    func testLegacyResumeReplaysClarificationAfterSnapshotAndExpiresIt() async throws {
        let snapshot: JSONValue = .object([
            "session_id": .string("legacy-session"), "stored_session_id": .string("stored-legacy"),
            "messages": .array([]), "status": .string("waiting"),
            "pending_clarify": .object(["request_id": .string("clarify-1"), "question": .string("Which file?")])
        ])
        let socket = ScriptedSocket(capabilityError: -32601, results: [
            "session.resume": snapshot, "approval.pending": .object(["approvals": .array([])])
        ])
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        _ = try await client.request("session.resume")
        guard case .snapshot(_, let published) = await updates.next() else { return XCTFail("Snapshot must precede its question") }
        XCTAssertEqual(published, snapshot)
        guard case .request(let question) = await updates.next() else { return XCTFail("Legacy clarification must be restored") }
        XCTAssertEqual(question.method, "clarify")
        await socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"clarify.expire","session_id":"legacy-session","payload":{"request_id":"clarify-1"}}}"#)
        _ = await updates.next() // Original expiration notification.
        guard case .event(let cancellation) = await updates.next() else { return XCTFail("Expected normalized cancellation") }
        XCTAssertEqual(cancellation.type, "request.cancel")
        do {
            try await client.respond(to: question.id, result: .object(["answer": .string("too late")]))
            XCTFail("Expired questions must not be answered")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .unknownServerRequest) }
        let frames = await socket.frames()
        XCTAssertFalse(frames.contains { $0["method"]?.stringValue == "clarify.respond" })
        await client.disconnect()
    }

    func testLegacyUnrestorableInputFailsWithActionableDiagnostic() async throws {
        let socket = ScriptedSocket(capabilityError: -32601, results: [
            "session.resume": .object(["session_id": .string("legacy-session"), "status": .string("waiting")])
        ])
        let client = client(socket: socket)
        try await client.connect(to: endpoint(), token: "fixture")
        do {
            _ = try await client.request("session.resume")
            XCTFail("Do not hide a waiting password or secret prompt")
        } catch {
            XCTAssertEqual(error as? LegacyGatewayRequestError, .pendingPromptCannotBeRestored)
            XCTAssertTrue(error.localizedDescription.contains("original client"))
        }
    }

    func testLegacyAmbiguousSecretReplyDisconnectsWithoutRetry() async throws {
        let socket = ScriptedSocket(capabilityError: -32601, results: ["secret.respond": .object([:])])
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        await socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"secret.request","session_id":"legacy-session","payload":{"request_id":"secret-1","name":"FIXTURE_KEY","prompt":"Enter key"}}}"#)
        _ = await updates.next()
        guard case .request(let secret) = await updates.next() else { return XCTFail("Expected secure input request") }
        do {
            try await client.respond(to: secret.id, result: .object(["value": .string("fixture-secret-value")]))
            XCTFail("An unrecognized acknowledgement must not be treated as success")
        } catch { XCTAssertEqual(error as? LegacyGatewayRequestError, .invalidReply) }
        guard case .disconnected(let message) = await updates.next() else { return XCTFail("Expected disconnect") }
        XCTAssertFalse(message?.contains("fixture-secret-value") == true)
        let frames = await socket.frames()
        XCTAssertEqual(frames.filter { $0["method"]?.stringValue == "secret.respond" }.count, 1)
        do {
            try await client.respond(to: secret.id, result: .object(["value": .string("retry")]))
            XCTFail("The uncertain response must not be replayed")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
    }

    func testReadyTimeoutIsBounded() async throws {
        let socket = ScriptedSocket(ready: false)
        let client = client(socket: socket, timing: GatewayTiming(readyTimeout: 0.02))
        do {
            try await client.connect(to: endpoint(), token: "fixture")
            XCTFail("Expected ready timeout")
        } catch {
            XCTAssertEqual(error as? GatewayTransportError, .readyTimedOut)
        }
    }

    func testKnownHostRejectionProvidesSafeTunnelGuidanceWithoutOpeningSocket() async throws {
        let token = "do-not-expose-host-test-token"
        let http = StubHTTP(payload: #"{"detail":"Invalid Host header. Dashboard requests must use the hostname the server was bound to.","debug":"server-private-details do-not-expose-host-test-token"}"#, status: 400)
        let socket = ScriptedSocket()
        let client = GatewayClient(http: http, socketFactory: { _ in
            XCTFail("A rejected status request must not open a WebSocket")
            return socket
        })
        var updates = await client.updates().makeAsyncIterator()
        do {
            try await client.connect(to: endpoint(), token: token)
            XCTFail("Expected hostname rejection")
        } catch {
            XCTAssertEqual(error as? GatewayTransportError, .hostRejected)
            XCTAssertTrue(error.localizedDescription.contains("SSH tunnel"))
            XCTAssertTrue(error.localizedDescription.contains("127.0.0.1"))
            XCTAssertFalse(error.localizedDescription.contains(token))
            XCTAssertFalse(error.localizedDescription.contains("server-private-details"))
        }
        guard case .disconnected(let diagnostic) = await updates.next() else {
            return XCTFail("Expected the safe disconnect diagnostic")
        }
        XCTAssertEqual(diagnostic, GatewayTransportError.hostRejected.localizedDescription)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1, "Do not retry with an altered Host header")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Host"))
        let frames = await socket.frames()
        XCTAssertTrue(frames.isEmpty, "Do not send capabilities after a failed HTTP handshake")
    }

    func testUnrecognizedOrUnboundedHTTPFailureKeepsGenericDiagnostic() async throws {
        let knownDetail = "Invalid Host header. Dashboard requests must use the hostname the server was bound to."
        let cases: [(payload: String, status: Int)] = [
            (#"{"detail":"server-private-details do-not-expose"}"#, 400),
            (#"{"detail":"\#(knownDetail) do-not-expose"}"#, 400),
            (#"{"detail":["\#(knownDetail)"]}"#, 400),
            (#""\#(knownDetail)""#, 400),
            ("<html>\(knownDetail) server-private-details do-not-expose</html>", 400),
            (#"{"detail":"\#(knownDetail)""#, 400),
            (#"{"detail":"\#(knownDetail)","padding":"\#(String(repeating: "x", count: 4_096))"}"#, 400),
            (#"{"detail":"\#(knownDetail)"}"#, 500)
        ]
        for (payload, status) in cases {
            let socket = ScriptedSocket()
            let http = StubHTTP(payload: payload, status: status)
            let client = GatewayClient(http: http, socketFactory: { _ in
                XCTFail("A failed status request must not open a WebSocket")
                return socket
            })
            do {
                try await client.connect(to: endpoint(), token: "do-not-expose")
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertEqual(error as? GatewayTransportError, .httpStatus(status))
                XCTAssertEqual(error.localizedDescription, GatewayTransportError.httpStatus(status).localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("do-not-expose"))
                XCTAssertFalse(error.localizedDescription.contains("server-private-details"))
            }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Host"))
            let frames = await socket.frames()
            XCTAssertTrue(frames.isEmpty)
        }
    }

    func testPendingRequestTimeoutCancellationAndDisconnectDoNotRetry() async throws {
        let socket = ScriptedSocket()
        let client = client(socket: socket)
        try await client.connect(to: endpoint(), token: "fixture")
        do {
            _ = try await client.request("hold", timeout: 0.02)
            XCTFail("Expected request timeout")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .requestTimedOut) }
        let cancelled = Task { try await client.request("hold", timeout: 10) }
        await waitForFrames(socket, count: 3)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let disconnected = Task { try await client.request("hold", timeout: 10) }
        await waitForFrames(socket, count: 4)
        await client.disconnect()
        do { _ = try await disconnected.value; XCTFail("Expected disconnect") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
        let frames = await socket.frames()
        XCTAssertEqual(frames.filter { $0["method"]?.stringValue == "hold" }.count, 3)
    }

    func testResumePublishesSnapshotThenReplayedQuestionInOrder() async throws {
        let socket = ScriptedSocket()
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        guard case .event(let ready) = await updates.next() else { return XCTFail("Expected ready event") }
        XCTAssertEqual(ready.type, "gateway.ready")
        guard case .connected = await updates.next() else { return XCTFail("Expected connected") }
        let result = try await client.request("session.resume", params: .object(["session_id": .string("stored-1"), "profile": .string("default")]))
        guard case .snapshot(let method, let snapshot) = await updates.next() else { return XCTFail("Expected ordered snapshot") }
        XCTAssertEqual(method, "session.resume")
        XCTAssertEqual(snapshot, result)
        guard case .request(let request) = await updates.next() else { return XCTFail("Expected replayed question") }
        XCTAssertEqual(request.id, .string("srq-replayed"))
        XCTAssertEqual(request.method, "clarify")
        try await client.respond(to: request.id, result: .object(["answer": .string("Yes")]))
        do {
            try await client.respond(to: request.id, result: .object(["answer": .string("Again")]))
            XCTFail("Duplicate answer must be rejected")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .unknownServerRequest) }
        let frames = await socket.frames()
        XCTAssertEqual(frames.last?["id"], .string("srq-replayed"))
        XCTAssertEqual(frames.last?["result"]?["answer"], .string("Yes"))
        await client.disconnect()
    }

    func testHeartbeatFailureInvalidatesTheConnection() async throws {
        let socket = ScriptedSocket(heartbeat: true, acknowledgeHeartbeat: false)
        let client = client(socket: socket, timing: GatewayTiming(readyTimeout: 1, heartbeatInterval: 0.01, heartbeatTimeout: 0.02))
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        guard case .disconnected(let message) = await updates.next() else { return XCTFail("Expected heartbeat disconnect") }
        XCTAssertNotNil(message)
        do { _ = try await client.request("fixture.echo"); XCTFail("Connection should be closed") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
        let frames = await socket.frames()
        XCTAssertEqual(frames.filter { $0["method"]?.stringValue == "gateway.ping" }.count, 1)
    }

    func testResumeRefreshesAnAlreadyDeliveredOpenQuestion() async throws {
        let socket = ScriptedSocket()
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        await socket.push(#"{"jsonrpc":"2.0","id":"srq-replayed","method":"clarify","params":{"session_id":"live-1","question":"Old question"}}"#)
        guard case .request(let initial) = await updates.next() else { return XCTFail("Expected initial question") }
        XCTAssertEqual(initial.params["question"], .string("Old question"))
        _ = try await client.request("session.resume")
        guard case .snapshot = await updates.next() else { return XCTFail("Expected snapshot before refreshed request") }
        guard case .request(let refreshed) = await updates.next() else { return XCTFail("Expected refreshed question") }
        XCTAssertEqual(refreshed.id, initial.id)
        XCTAssertEqual(refreshed.params["question"], .string("Continue?"))
        await client.disconnect()
    }

    func testNumericServerRequestIDIsNotRoundedAndRejectionAnswersSameID() async throws {
        let socket = ScriptedSocket()
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        await socket.push(#"{"jsonrpc":"2.0","id":9007199254740993,"method":"preview.act","params":{"session_id":"live-1"}}"#)
        guard case .request(let request) = await updates.next() else { return XCTFail("Expected server request") }
        XCTAssertEqual(request.id, .number(9_007_199_254_740_993))
        try await client.reject(request.id, code: -32601, message: "This client does not provide a preview surface")
        struct Identity: Decodable { let id: RPCID }
        let frames = await socket.rawSent
        let response = try JSONDecoder().decode(Identity.self, from: Data(try XCTUnwrap(frames.last).utf8))
        XCTAssertEqual(response.id, request.id)
        await client.disconnect()
    }

    func testCancelledServerQuestionCannotBeAnswered() async throws {
        let socket = ScriptedSocket()
        let client = client(socket: socket)
        var updates = await client.updates().makeAsyncIterator()
        try await client.connect(to: endpoint(), token: "fixture")
        _ = await updates.next()
        _ = await updates.next()
        await socket.push(#"{"jsonrpc":"2.0","id":"srq-old","method":"approval","params":{"session_id":"live-1"}}"#)
        _ = await updates.next()
        await socket.push(#"{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","session_id":"live-1","seq":1,"payload":{"id":"srq-old","reason":"timeout"}}}"#)
        guard case .event(let event) = await updates.next() else { return XCTFail("Expected cancellation event") }
        XCTAssertEqual(event.type, "request.cancel")
        do {
            try await client.respond(to: .string("srq-old"), result: .object(["choice": .string("allow")]))
            XCTFail("Expired approval must not be sent")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .unknownServerRequest) }
        await client.disconnect()
    }

    func testLateStatusFromRetiredGenerationCannotReplaceTheNewConnection() async throws {
        let http = DelayedStatusHTTP()
        let socket = ScriptedSocket()
        let client = GatewayClient(http: http, socketFactory: { _ in socket })
        let old = Task { try await client.connect(to: endpoint("http://127.0.0.1:8642/old"), token: "old") }
        for _ in 0..<100 {
            if await http.oldRequestStarted { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        try await client.connect(to: endpoint("http://127.0.0.1:8642/new"), token: "new")
        await http.releaseOldRequest()
        do { try await old.value; XCTFail("Retired handshake must not succeed") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .connectionChanged) }
        let result = try await client.request("fixture.echo", params: .string("new connection survives"))
        XCTAssertEqual(result, .string("new connection survives"))
        await client.disconnect()
    }

    private func waitForFrames(_ socket: ScriptedSocket, count: Int) async {
        for _ in 0..<100 {
            if await socket.frames().count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Fixture did not receive expected request")
    }
}
