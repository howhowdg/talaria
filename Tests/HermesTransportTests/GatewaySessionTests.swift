import Foundation
import XCTest
@testable import HermesTransport

private actor AuthHTTP: GatewayHTTPTransport {
    var replies: [GatewayHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [GatewayHTTPResponse]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}

final class GatewaySessionTests: XCTestCase, @unchecked Sendable {
    let endpoint = GatewayEndpoint(name: "Fixture", baseURL: URL(string: "https://example.test/hermes")!, authentication: .basic)
    func response(_ body: String, _ status: Int = 200, cookie: String? = nil) -> GatewayHTTPResponse {
        GatewayHTTPResponse(data: Data(body.utf8), status: status, headers: cookie.map { ["Set-Cookie": $0] } ?? [:])
    }
    var status: GatewayHTTPResponse { response(#"{"auth_required":true,"auth_providers":[{"name":"basic"}]}"#) }
    var identity: GatewayHTTPResponse { response(#"{"provider":"basic","expires_at":4102444800}"#) }
    var login: GatewayHTTPResponse {
        response(#"{"ok":true,"next":"https://untrusted.test"}"#, cookie: "__Secure-hermes_session_at=access-sentinel; Path=/hermes; Secure; Max-Age=3600, __Secure-hermes_session_rt=refresh-sentinel; Path=/hermes; Secure; Max-Age=3600")
    }
    func testBasicSignInOverTailscaleHTTP() async throws {
        let endpoint = GatewayEndpoint(name: "Tailscale", baseURL: URL(string: "http://100.64.1.2:8642")!, authentication: .basic)
        let http = AuthHTTP([status, response(#"{"ok":true}"#, cookie: "hermes_session_at=access-sentinel; Path=/; Max-Age=3600"), identity,
                             identity, response(#"{"ticket":"ticket-one"}"#)])
        let session = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        try await session.login(username: "user", password: "password")
        let socket = try await session.socketRequest()
        XCTAssertEqual(socket.url?.scheme, "ws")
        XCTAssertEqual(socket.url?.host, "100.64.1.2")
        let requests = await http.requests
        XCTAssertTrue(requests.dropFirst(2).allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("access-sentinel") == true })
    }
    func testSSHCookieSnapshotRebindsOnlyToConfiguredDestination() async throws {
        var configured = GatewayEndpoint(name: "SSH", baseURL: URL(string: "http://127.0.0.1:9119")!,
            authentication: .basic, ssh: GatewaySSHDestination(host: "mini.example", gatewayPort: 9119))
        var active = configured; active.baseURL = URL(string: "http://127.0.0.1:23456")!
        let http = AuthHTTP([status, response(#"{"ok":true}"#, cookie: "hermes_session_at=access-sentinel; Path=/; Max-Age=3600"), identity])
        let original = try GatewaySession(endpoint: active, credentialEndpoint: configured, token: nil, http: http)
        try await original.login(username: "user", password: "password")
        let saved = await original.snapshot()
        let snapshot = try XCTUnwrap(saved)
        XCTAssertEqual(snapshot.baseURL, configured.baseURL)
        await original.suspend()
        let retained = await original.snapshot()
        XCTAssertNotNil(retained)
        do { try await original.validate(); XCTFail("Dead tunnel must reject requests") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
        active.baseURL = URL(string: "http://127.0.0.1:34567")!
        let restored = try GatewaySession(endpoint: active, credentialEndpoint: configured, token: nil,
            restored: snapshot, http: AuthHTTP([identity]))
        try await restored.validate()
        configured.baseURL = URL(string: "http://127.0.0.1:9120")!
        XCTAssertThrowsError(try GatewaySession(endpoint: active, credentialEndpoint: configured, token: nil,
            restored: snapshot, http: AuthHTTP([])))
    }
    func testLoginSnapshotReaderUploadAndFreshTicketsShareCookies() async throws {
        let http = AuthHTTP([status, login, identity, response("{}"), response(#"{"ok":true,"path":"/tmp/image","bytes":8}"#), identity,
                             response(#"{"ticket":"ticket-one","ttl_seconds":30}"#), identity, response(#"{"ticket":"ticket-two","ttl_seconds":30}"#)])
        let session = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        try await session.login(username: "user", password: "password-sentinel")
        let snapshot = await session.snapshot()
        let encoded = try JSONEncoder().encode(XCTUnwrap(snapshot))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password-sentinel"))
        _ = try await GatewayReader(session: session).read(.schedules)
        _ = try await GatewayUploadClient(session: session).uploadImage(data: Data([0x89,0x50,0x4e,0x47,13,10,26,10]), filename: "test.png")
        let first = try await session.socketRequest()
        let second = try await session.socketRequest()
        XCTAssertTrue(first.url!.absoluteString.contains("ticket=ticket-one"))
        XCTAssertTrue(second.url!.absoluteString.contains("ticket=ticket-two"))
        let requests = await http.requests
        XCTAssertEqual(requests[1].url?.path, "/hermes/auth/password-login")
        for request in requests.dropFirst(2) {
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("access-sentinel") == true)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("refresh-sentinel") == true)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        var other = endpoint; other.baseURL = URL(string: "https://example.test:9443/hermes")!
        XCTAssertThrowsError(try GatewaySession(endpoint: other, restored: snapshot))
        other = endpoint; other.baseURL = URL(string: "https://example.test/sibling")!
        XCTAssertThrowsError(try GatewaySession(endpoint: other, restored: snapshot))
    }

    func testWrongPasswordUnsupportedRateLimitAndOutageAreSafe() async throws {
        for (code, error) in [(401, GatewayTransportError.invalidCredentials), (404, .unsupportedAuthentication), (429, .rateLimited), (503, .authenticationUnavailable)] {
            let session = try GatewaySession(endpoint: endpoint, token: nil, http: AuthHTTP([status, response("secret diagnostic", code)]))
            do { try await session.login(username: "u", password: "p"); XCTFail() }
            catch let actual { XCTAssertEqual(actual as? GatewayTransportError, error) }
        }
        let http = AuthHTTP([response(#"{"auth_providers":["oauth"]}"#)])
        let session = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        do { try await session.login(username: "u", password: "p"); XCTFail() }
        catch { XCTAssertEqual(error as? GatewayTransportError, .unsupportedAuthentication) }
        let requests = await http.requests; XCTAssertEqual(requests.count, 1)
    }

    func testRestoreRefreshRotationAndTerminalExpiry() async throws {
        let http = AuthHTTP([status, login, identity])
        let first = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        try await first.login(username: "u", password: "p")
        let snapshot = await first.snapshot()
        let restoredHTTP = AuthHTTP([response(#"{"provider":"basic","expires_at":4102444800}"#, cookie: "__Secure-hermes_session_at=rotated; Path=/hermes; Secure; Max-Age=3600"), response("{}", 503), response("{}", 401)])
        let restored = try GatewaySession(endpoint: endpoint, token: nil, restored: snapshot, http: restoredHTTP)
        try await restored.validate()
        let reader = GatewayReader(session: restored)
        do { _ = try await reader.triggerAutomation(id: "job"); XCTFail() }
        catch { XCTAssertEqual(error as? GatewayTransportError, .authenticationUnavailable) }
        let stillSaved = await restored.snapshot(); XCTAssertNotNil(stillSaved)
        do { _ = try await reader.triggerAutomation(id: "job"); XCTFail() }
        catch { XCTAssertEqual(error as? GatewayTransportError, .sessionExpired) }
        let cleared = await restored.snapshot(); XCTAssertNil(cleared)
        let requests = await restoredHTTP.requests
        XCTAssertEqual(requests.count, 3, "Mutations must not replay")
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Cookie")!.contains("rotated"))
    }

    func testOriginAndCookieAllowlistAndLogout() async throws {
        let badCookies = "attacker=bad; Path=/hermes; Secure, __Secure-hermes_session_at=wide; Domain=.example.test; Path=/hermes; Secure, __Secure-hermes_session_rt=good; Path=/hermes; Secure"
        let http = AuthHTTP([status, response(#"{"ok":true}"#, cookie: badCookies), identity, response("", 302)])
        let session = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        try await session.login(username: "u", password: "p")
        for url in ["https://example.test:444/hermes/api/status", "https://example.test/sibling/api/status", "https://other.test/hermes/api/status"] {
            do { _ = try await session.data(for: URLRequest(url: URL(string: url)!)); XCTFail() }
            catch { XCTAssertEqual(error as? GatewayTransportError, .invalidEndpoint) }
        }
        await session.logout()
        let snapshot = await session.snapshot(); XCTAssertNil(snapshot)
        do { try await session.validate(); XCTFail("A signed-out session must stay invalidated") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.last?.httpMethod, "POST")
        XCTAssertEqual(requests.last?.url?.path, "/hermes/auth/logout")
        let header = requests[2].value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertFalse(header.contains("bad")); XCTAssertFalse(header.contains("wide")); XCTAssertTrue(header.contains("good"))
    }
}

private actor HeldAuthHTTP: GatewayHTTPTransport {
    var waiter: CheckedContinuation<GatewayHTTPResponse, Never>?
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        await withCheckedContinuation { waiter = $0 }
    }
    func isWaiting() -> Bool { waiter != nil }
    func finish(_ response: GatewayHTTPResponse) { waiter?.resume(returning: response); waiter = nil }
}

extension GatewaySessionTests {
    func testExpiredAccessRefreshCoalescesAndDeletionIsApplied() async throws {
        let http = AuthHTTP([status, login, identity])
        let original = try GatewaySession(endpoint: endpoint, token: nil, http: http)
        try await original.login(username: "u", password: "p")
        let savedValue = await original.snapshot()
        let saved = try XCTUnwrap(savedValue)
        let expired = HTTPCookie(properties: [.name: "__Secure-hermes_session_at", .value: "expired", .domain: "example.test", .path: "/hermes", .secure: "TRUE", .expires: Date(timeIntervalSince1970: 1)])!
        let snapshot = GatewaySessionSnapshot(connectionID: endpoint.id, baseURL: endpoint.baseURL,
            cookies: saved.cookies.filter { !$0.name.hasSuffix("_at") } + [GatewaySessionSnapshot.Cookie(expired)], expiresAt: Date(timeIntervalSince1970: 1))
        let refreshedHTTP = AuthHTTP([response(#"{"provider":"basic","expires_at":4102444800}"#, cookie: "__Secure-hermes_session_at=new; Path=/hermes; Secure; Max-Age=3600"),
                                      response("{}", cookie: "__Secure-hermes_session_rt=; Path=/hermes; Secure; Max-Age=0"), response("{}")])
        let restored = try GatewaySession(endpoint: endpoint, token: nil, restored: snapshot, http: refreshedHTTP)
        let reader = GatewayReader(session: restored)
        async let first = reader.read(.schedules)
        async let second = reader.read(.schedules)
        _ = try await (first, second)
        let requests = await refreshedHTTP.requests
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/auth/me") == true }.count, 1)
        XCTAssertFalse(requests[0].value(forHTTPHeaderField: "Cookie")!.contains("expired"))
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Cookie")!.contains("refresh-sentinel"))
        XCTAssertFalse(requests[2].value(forHTTPHeaderField: "Cookie")!.contains("refresh-sentinel"))
    }

    func testClearRejectsLateResponseAndCannotRestoreCookies() async throws {
        let held = HeldAuthHTTP()
        let session = try GatewaySession(endpoint: endpoint, token: nil, http: held)
        let pending = Task { try await session.validate() }
        for _ in 0..<1000 {
            if await held.isWaiting() { break }
            await Task.yield()
        }
        let waiting = await held.isWaiting(); XCTAssertTrue(waiting)
        await session.clear()
        await held.finish(response(#"{"provider":"basic","expires_at":4102444800}"#, cookie: "__Secure-hermes_session_at=late; Path=/hermes; Secure; Max-Age=3600"))
        do { try await pending.value; XCTFail("Late response must fail") } catch { }
        let snapshot = await session.snapshot(); XCTAssertNil(snapshot)
    }
}
