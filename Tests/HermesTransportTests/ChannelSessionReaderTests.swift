import Foundation
import XCTest
@testable import HermesTransport

private actor ChannelSessionHTTP: GatewayHTTPTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        let body: String
        var headers: [String: String] = [:]
        if path.hasSuffix("/api/status") { body = #"{"auth_required":true,"auth_providers":["basic"]}"# }
        else if path.hasSuffix("/auth/password-login") {
            body = #"{"ok":true}"#
            headers["Set-Cookie"] = "hermes_session_at=ssh-cookie; Path=/; HttpOnly"
        } else if path.hasSuffix("/api/auth/me") { body = #"{"provider":"basic","expires_at":4102444800}"# }
        else { body = "{}" }
        return GatewayHTTPResponse(data: Data(body.utf8), status: 200, headers: headers)
    }
}

final class ChannelSessionReaderTests: XCTestCase, @unchecked Sendable {
    func testBasicChannelRequestsReuseCookiesAndActiveTunnelOrigin() async throws {
        let http = ChannelSessionHTTP()
        let configured = GatewayEndpoint(name: "SSH", baseURL: URL(string: "http://127.0.0.1:9119/hermes")!, profile: "work",
            authentication: .basic, ssh: GatewaySSHDestination(host: "fixture.invalid", gatewayPort: 9119))
        var active = configured; active.baseURL = URL(string: "http://127.0.0.1:24567/hermes")!
        let session = try GatewaySession(endpoint: active, credentialEndpoint: configured, token: nil, http: http)
        try await session.login(username: "fixture", password: "unused-password")
        let reader = GatewayReader(session: session)
        for route: GatewayReadEndpoint in [.channelSessions(source: nil, limit: 100, offset: 0),
            .channelSession(id: "probe"), .channelMessages(id: "probe", limit: 100, offset: 0),
            .channelSearch(query: "needle"), .messagingPlatforms] {
            _ = try await reader.read(route)
        }
        _ = try await reader.renameSession(id: "probe", title: "Renamed")
        let requests = await http.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.port == 24567 && $0.url?.host == "127.0.0.1" })
        let reads = Array(requests.dropFirst(3))
        XCTAssertEqual(reads.count, 6)
        XCTAssertTrue(reads.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("ssh-cookie") == true })
        XCTAssertTrue(reads.allSatisfy { $0.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil })
        let rename = try XCTUnwrap(reads.last)
        XCTAssertEqual(rename.httpMethod, "PATCH")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(rename.httpBody)), ["title": "Renamed", "profile": "work"])
        await session.suspend()
        do { _ = try await reader.read(.channelSession(id: "probe")); XCTFail("Closed tunnel must not send") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .notConnected) }
        let afterSuspend = await http.requests
        XCTAssertEqual(afterSuspend.count, requests.count)
    }
}
