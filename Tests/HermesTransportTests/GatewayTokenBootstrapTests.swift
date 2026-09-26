import Foundation
import XCTest
@testable import HermesTransport

private actor BootstrapHTTP: GatewayHTTPTransport {
    var replies: [GatewayHTTPResponse]
    init(_ status: String, _ body: String) {
        replies = [GatewayHTTPResponse(data: Data(status.utf8), status: 200),
                   GatewayHTTPResponse(data: Data(body.utf8), status: 200)]
    }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse { replies.removeFirst() }
}

final class GatewayTokenBootstrapTests: XCTestCase {
    let endpoint = GatewayEndpoint(name: "Tunnel", baseURL: URL(string: "http://127.0.0.1:23456/hermes")!)

    func testParsesOnlyUngatedHeadlessToken() async throws {
        let token = try await GatewayTokenBootstrap.token(through: endpoint,
            http: BootstrapHTTP(#"{"auth_required":false}"#, #"<script>window.__HERMES_SESSION_TOKEN__ = "abc123";</script>"#))
        XCTAssertEqual(token, "abc123")
        do {
            _ = try await GatewayTokenBootstrap.token(through: endpoint,
                http: BootstrapHTTP(#"{"auth_required":true}"#, #"window.__HERMES_SESSION_TOKEN__ = "secret";"#))
            XCTFail("Gated service must never bootstrap")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .interactiveAuthenticationRequired) }
        do {
            _ = try await GatewayTokenBootstrap.token(through: endpoint,
                http: BootstrapHTTP(#"{"auth_required":false}"#, #"window.__HERMES_SESSION_TOKEN__ = JSON.parse("evil");"#))
            XCTFail("Only a JSON string assignment is supported")
        } catch { XCTAssertEqual(error as? GatewayTransportError, .missingToken) }
    }
}
