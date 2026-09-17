import Foundation
import XCTest
import HermesProtocol
@testable import HermesTransport

private actor UploadHTTPStub: GatewayHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let response: GatewayHTTPResponse
    let failure: Error?
    init(payload: String, status: Int = 200, failure: Error? = nil) {
        response = GatewayHTTPResponse(data: Data(payload.utf8), status: status)
        self.failure = failure
    }
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        if let failure { throw failure }
        return response
    }
}

private actor HeldUploadHTTP: GatewayHTTPTransport {
    private var continuation: CheckedContinuation<GatewayHTTPResponse, Never>?
    private(set) var started = false
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: GatewayHTTPResponse(data: Data(#"{"ok":true,"path":"/host/a.txt"}"#.utf8), status: 200))
        continuation = nil
    }
}

@MainActor
final class UploadTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
    private func endpoint() -> GatewayEndpoint {
        GatewayEndpoint(name: "Fixture", baseURL: URL(string: "https://host.example/hermes")!, profile: "research profile")
    }

    func testImageUploadUsesScopedSecretHeaderAndNoSessionMutation() async throws {
        let http = UploadHTTPStub(payload: #"{"ok":true,"path":"/host/profile/images/a.png","bytes":8}"#)
        let result = try await GatewayUploadClient(http: http).uploadImage(data: png, filename: "a.png", endpoint: endpoint(), token: "private-token")
        XCTAssertEqual(result.hostPath, "/host/profile/images/a.png")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/hermes/api/chat/image-upload")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "profile", value: "research profile")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "private-token")
        XCTAssertFalse(request.url!.absoluteString.contains("private-token"))
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["data_url"], .string("data:image/png;base64,\(png.base64EncodedString())"))
        XCTAssertNil(body["session_id"])
        XCTAssertNil(body["method"])
    }

    func testMultipartUsesExactBytesAndRefusesOverwrite() async throws {
        let http = UploadHTTPStub(payload: #"{"ok":true,"path":"/work/.hermes/native-attachments/id/a.pdf"}"#)
        let data = Data([0, 1, 2, 255, 13, 10])
        _ = try await GatewayUploadClient(http: http).uploadFile(data: data, filename: "a.pdf", mimeType: "application/pdf",
            hostPath: "/work/.hermes/native-attachments/id/a.pdf", endpoint: endpoint(), token: "token")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/hermes/api/files/upload-stream")
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: data))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"overwrite\"\r\n\r\nfalse\r\n"))
        XCTAssertTrue(text.contains("name=\"path\"\r\n\r\n/work/.hermes/native-attachments/id/a.pdf"))
        XCTAssertFalse(text.contains(data.base64EncodedString()))
    }

    func testUnsafeAndOversizedInputsNeverTouchNetwork() async throws {
        let http = UploadHTTPStub(payload: "{}")
        let client = GatewayUploadClient(http: http)
        for data in [Data(), Data(repeating: 0, count: GatewayUploadClient.maximumBytes + 1)] {
            do { _ = try await client.uploadImage(data: data, filename: "a.png", endpoint: endpoint(), token: "token"); XCTFail("Accepted invalid data") }
            catch { XCTAssertTrue(error is GatewayUploadError) }
        }
        do { _ = try await client.uploadImage(data: png, filename: "a\r\n.png", endpoint: endpoint(), token: "token"); XCTFail("Accepted filename") } catch {}
        do { _ = try await client.uploadImage(data: png, filename: "a.png", endpoint: endpoint(), token: "token\r\nInjected: yes"); XCTFail("Accepted header") } catch {}
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailureNeverLeaksServerBodyTokenOrSourceURL() async throws {
        let secret = "must-not-appear"
        for status in [302, 401, 413, 500] {
            let http = UploadHTTPStub(payload: "token=\(secret)", status: status)
            do { _ = try await GatewayUploadClient(http: http).uploadImage(data: png, filename: "a.png", endpoint: endpoint(), token: secret); XCTFail("Accepted failed upload") }
            catch { XCTAssertFalse(error.localizedDescription.contains(secret)) }
        }
        let http = UploadHTTPStub(payload: "", failure: NSError(domain: "https://host/?token=\(secret)", code: 1))
        do { _ = try await GatewayUploadClient(http: http).uploadImage(data: png, filename: "a.png", endpoint: endpoint(), token: secret); XCTFail("Accepted failed network") }
        catch { XCTAssertEqual(error as? GatewayUploadError, .transferFailed); XCTAssertFalse(error.localizedDescription.contains(secret)) }
    }

    func testCanceledTransferRejectsLateSuccessfulResponse() async throws {
        let http = HeldUploadHTTP()
        let task = Task {
            try await GatewayUploadClient(http: http).uploadFile(data: Data("x".utf8), filename: "a.txt", mimeType: "text/plain",
                hostPath: "/host/a.txt", endpoint: endpoint(), token: "token")
        }
        for _ in 0..<100 {
            if await http.started { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await http.started
        XCTAssertTrue(started)
        task.cancel()
        await http.finish()
        do { _ = try await task.value; XCTFail("Canceled upload became ready") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidResponseAndRemotePathAreRejected() async throws {
        for payload in [#"{"ok":true,"path":"relative.png","bytes":8}"#, #"{"ok":true,"path":"/host/a.png","bytes":9}"#, "null"] {
            let http = UploadHTTPStub(payload: payload)
            do { _ = try await GatewayUploadClient(http: http).uploadImage(data: png, filename: "a.png", endpoint: endpoint(), token: "token"); XCTFail("Accepted malformed response") }
            catch { XCTAssertEqual(error as? GatewayUploadError, .invalidResponse) }
        }
    }
}
