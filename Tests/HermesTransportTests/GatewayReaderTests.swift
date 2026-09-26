import Foundation
import XCTest
import HermesProtocol
@testable import HermesTransport

private actor ReaderHTTP: GatewayHTTPTransport {
    let response: GatewayHTTPResponse
    private(set) var requests: [URLRequest] = []
    init(_ text: String, status: Int = 200) {
        response = GatewayHTTPResponse(data: Data(text.utf8), status: status)
    }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request); return response
    }
}

final class GatewayReaderTests: XCTestCase, @unchecked Sendable {
    private let endpoint = GatewayEndpoint(name: "Fixture", baseURL: URL(string: "https://example.test/hermes")!, profile: "work / private")

    func testReadRouteEncodesIdentifiersAndKeepsCredentialsInHeader() throws {
        let request = try GatewayRoutes(endpoint: endpoint).readRequest(.scheduleRuns(id: "job/a?other=1#x", limit: 900), token: "fixture-secret")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "example.test")
        XCTAssertEqual(components.percentEncodedPath, "/hermes/api/cron/jobs/job%2Fa%3Fother%3D1%23x/runs")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "profile" })?.value, "work / private")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "20")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "fixture-secret")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

    func testReadRouteRejectsTraversalAndRemoteCleartext() throws {
        let routes = try GatewayRoutes(endpoint: endpoint)
        for id in ["", ".", "..", "bad\nname", String(repeating: "a", count: 513)] {
            XCTAssertThrowsError(try routes.readRequest(.sessionMessages(id: id, limit: 20), token: "fixture"))
        }
        XCTAssertThrowsError(try routes.readRequest(.schedules, token: ""))
        XCTAssertThrowsError(try GatewayRoutes(endpoint: GatewayEndpoint(name: "Bad", baseURL: URL(string: "http://remote.test")!)))
    }

    func testReadHandlesAuthenticationAndMalformedPayloadWithoutLeakingBody() async throws {
        let rejected = GatewayReader(endpoint: endpoint, token: "fixture", http: ReaderHTTP("secret server detail", status: 401))
        do { _ = try await rejected.read(.schedules); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .authenticationRejected) }
        let invalid = GatewayReader(endpoint: endpoint, token: "fixture", http: ReaderHTTP("not JSON"))
        do { _ = try await invalid.read(.schedules); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? GatewayTransportError, .invalidResponse) }
        let valid = GatewayReader(endpoint: endpoint, token: "fixture", http: ReaderHTTP("[]"))
        let result = try await valid.read(.schedules)
        XCTAssertEqual(result, .array([]))
    }
}

extension GatewayReaderTests {
    func testChannelRoutesKeepProfileFiltersAndPaging() throws {
        let routes = try GatewayRoutes(endpoint: endpoint)
        let cases: [(GatewayReadEndpoint, String, [String: String])] = [
            (.messagingPlatforms, "/hermes/api/messaging/platforms", [:]),
            (.channelSession(id: "thread/a?x=1"), "/hermes/api/sessions/thread%2Fa%3Fx%3D1", [:]),
            (.channelSessions(source: nil, limit: 900, offset: -1), "/hermes/api/sessions",
             ["limit": "100", "offset": "0", "order": "recent", "archived": "exclude",
              "exclude_sources": "cli,codex,desktop,gateway,kanban,local,native,oneshot,tui,cron,subagent,tool,unknown,bot_room"]),
            (.channelSessions(source: "telegram&profile=other", limit: 20, offset: 40), "/hermes/api/sessions",
             ["source": "telegram&profile=other", "limit": "20", "offset": "40", "order": "recent", "archived": "exclude"]),
            (.channelMessages(id: "thread/a?x=1", limit: 900, offset: 500), "/hermes/api/sessions/thread%2Fa%3Fx%3D1/messages",
             ["limit": "500", "offset": "500", "order": "latest", "include_compacted": "true"]),
            (.channelSearch(query: "hello & profile=other"), "/hermes/api/sessions/search",
             ["q": "hello & profile=other", "limit": "100",
              "exclude_sources": "cli,codex,desktop,gateway,kanban,local,native,oneshot,tui,cron,subagent,tool,unknown,bot_room"])
        ]
        for (resource, path, expected) in cases {
            let request = try routes.readRequest(resource, token: "secret")
            let route = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(route.host, "example.test")
            XCTAssertEqual(route.percentEncodedPath, path)
            var query = expected
            query["profile"] = endpoint.profile
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: (route.queryItems ?? []).map { ($0.name, $0.value ?? "") }), query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret")
            XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        }
    }

    func testRenameCarriesProfileInBodyAndDoesNotRetry() async throws {
        let http = ReaderHTTP("{\"ok\":true,\"title\":\"New title\"}")
        let reader = GatewayReader(endpoint: endpoint, token: "secret", http: http)
        _ = try await reader.renameSession(id: "thread/a?x=1", title: "New title")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/hermes/api/sessions/thread%2Fa%3Fx%3D1")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody)),
                       ["title": "New title", "profile": endpoint.profile])
        let rejected = ReaderHTTP("private detail", status: 403)
        do {
            _ = try await GatewayReader(endpoint: endpoint, token: "secret", http: rejected).renameSession(id: "id", title: "Title")
            XCTFail("Expected authentication failure")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .authenticationRejected) }
        let attempts = await rejected.requests
        XCTAssertEqual(attempts.count, 1)
    }

    func testAutomationMutationsPreserveOriginProfileAndDoNotRetry() async throws {
        let http = ReaderHTTP("{}")
        let reader = GatewayReader(endpoint: endpoint, token: "secret", http: http)
        _ = try await reader.setAutomationEnabled(id: "id/with?special", enabled: false)
        _ = try await reader.setAutomationEnabled(id: "id/with?special", enabled: true)
        _ = try await reader.triggerAutomation(id: "id/with?special")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3)
        for (index, action) in ["pause", "resume", "trigger"].enumerated() {
            let request = requests[index]
            let route = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(route.host, "example.test")
            XCTAssertEqual(route.percentEncodedPath, "/hermes/api/cron/jobs/id%2Fwith%3Fspecial/\(action)")
            XCTAssertEqual(route.queryItems, [URLQueryItem(name: "profile", value: "work / private")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "secret")
        }
        let ambiguous = ReaderHTTP("host detail", status: 503)
        do {
            _ = try await GatewayReader(endpoint: endpoint, token: "secret", http: ambiguous).triggerAutomation(id: "id")
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .httpStatus(503)) }
        let attempts = await ambiguous.requests
        XCTAssertEqual(attempts.count, 1)
    }
}
