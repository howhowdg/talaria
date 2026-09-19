import Foundation
import XCTest
@testable import HermesTransport

final class TelegramTopicsReaderTests: XCTestCase {
    func testOptionalExtensionUsesAuthenticatedProfileScopedReadUnderProxyPrefix() throws {
        let endpoint = GatewayEndpoint(name: "Fixture", baseURL: URL(string: "https://example.test/hermes")!, profile: "work / private")
        let request = try GatewayRoutes(endpoint: endpoint).readRequest(.telegramTopics, token: "fixture-secret")
        let route = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(route.percentEncodedPath, "/hermes/api/talaria/telegram/topics")
        XCTAssertEqual(route.queryItems, [URLQueryItem(name: "profile", value: "work / private")])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "fixture-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret"))
    }
}
