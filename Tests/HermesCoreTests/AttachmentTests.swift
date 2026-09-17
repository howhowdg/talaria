import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore
@testable import HermesTransport

private actor AttachmentHTTPStub: GatewayHTTPTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let marker = "name=\"path\"\r\n\r\n"
        let path: String
        if let start = body.range(of: marker)?.upperBound {
            let remainder = body[start...]
            path = String(remainder[..<(remainder.range(of: "\r\n")?.lowerBound ?? remainder.endIndex)])
        } else { path = "/remote/profile/images/upload.png" }
        let value = JSONValue.object(["ok": .bool(true), "path": .string(path), "bytes": .number(8)])
        return GatewayHTTPResponse(data: try JSONEncoder().encode(value), status: 200)
    }
}

@MainActor
final class AttachmentTests: XCTestCase {
    private func scope(_ id: UUID = UUID(), profile: String = "work", session: String = "stored-1") -> AttachmentScope {
        AttachmentScope(connectionID: id, profile: profile, storedSessionID: StoredSessionID(rawValue: session))
    }
    private func endpoint(_ scope: AttachmentScope) -> GatewayEndpoint {
        GatewayEndpoint(id: scope.connectionID, name: "Fixture", baseURL: URL(string: "https://remote.example")!, profile: scope.profile)
    }

    func testTypeSniffingPreservesImagesAndRejectsUnsupportedOrInvalidFiles() throws {
        let scope = scope()
        let png = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
        let image = try AttachmentLoader.stage(data: png, filename: "wrong-name.txt", scope: scope)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.scope, scope)
        let pdf = try AttachmentLoader.stage(data: Data("%PDF-1.4\n".utf8), filename: "report.pdf", scope: scope)
        XCTAssertEqual(pdf.kind, .file)
        XCTAssertEqual(pdf.mimeType, "application/pdf")
        for (data, name, expected) in [(Data("text".utf8), "a.png", AttachmentError.unsupportedImage),
                                      (Data("text".utf8), "a.pdf", .invalidPDF),
                                      (Data(), "a.txt", .empty),
                                      (Data("x".utf8), "../secret", .invalidName)] {
            XCTAssertThrowsError(try AttachmentLoader.stage(data: data, filename: name, scope: scope)) { XCTAssertEqual($0 as? AttachmentError, expected) }
        }
    }

    func testScopedReadAcceptsRegularFileAndRejectsDirectorySymlinkAndURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("read marker".utf8).write(to: file)
        let staged = try await AttachmentLoader.read(url: file, scope: scope())
        XCTAssertEqual(staged.byteCount, 11)
        XCTAssertEqual(staged.filename, "notes.txt")
        let symlink = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        for url in [directory, symlink, URL(string: "https://example.com/a.txt")!] {
            do { _ = try await AttachmentLoader.read(url: url, scope: scope()); XCTFail("Accepted invalid file") }
            catch { XCTAssertEqual(error as? AttachmentError, .regularFileRequired) }
        }
    }

    func testDocumentsUploadInsideCapturedWorkspaceAndPromptUsesRelativeReference() async throws {
        let owner = scope()
        let staged = try AttachmentLoader.stage(data: Data("document marker".utf8), filename: "Report (draft).txt", scope: owner)
        let http = AttachmentHTTPStub()
        let uploaded = try await AttachmentTransferService(upload: GatewayUploadClient(http: http)).upload(
            staged, workspace: "/remote/project", endpoint: endpoint(owner), token: "token")
        let expectedRelative = ".hermes/native-attachments/\(staged.id.uuidString.lowercased())/Report__draft_.txt"
        XCTAssertEqual(uploaded.hostPath, "/remote/project/" + expectedRelative)
        XCTAssertEqual(uploaded.relativePath, expectedRelative)
        XCTAssertEqual(uploaded.scope, owner)
        let prompt = try AttachmentPrompt.compose(text: "Read this", attachments: [uploaded], scope: owner)
        XCTAssertEqual(prompt, "Read this\n\n@file:" + expectedRelative)
        XCTAssertFalse(prompt.contains("/remote/project"))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/files/upload-stream")
    }

    func testImageTransferDoesNotQueueImageOrInjectFakeImageDirective() async throws {
        let owner = scope()
        let staged = try AttachmentLoader.stage(data: Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]), filename: "photo.png", scope: owner)
        let http = AttachmentHTTPStub()
        let uploaded = try await AttachmentTransferService(upload: GatewayUploadClient(http: http)).upload(
            staged, workspace: "", endpoint: endpoint(owner), token: "token")
        XCTAssertEqual(uploaded.kind, .image)
        XCTAssertNil(uploaded.promptReference)
        XCTAssertNil(uploaded.relativePath)
        XCTAssertEqual(try AttachmentPrompt.compose(text: "", attachments: [uploaded], scope: owner), "Please review the attached files.")
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/chat/image-upload"])
    }

    func testWrongOwnerAndInvalidWorkspaceAreRejectedBeforeNetwork() async throws {
        let owner = scope()
        let staged = try AttachmentLoader.stage(data: Data("x".utf8), filename: "a.txt", scope: owner)
        let http = AttachmentHTTPStub()
        let transfer = AttachmentTransferService(upload: GatewayUploadClient(http: http))
        var wrongProfile = endpoint(owner)
        wrongProfile.profile = "different"
        do { _ = try await transfer.upload(staged, workspace: "/project", endpoint: wrongProfile, token: "token"); XCTFail("Crossed profile") }
        catch { XCTAssertEqual(error as? AttachmentError, .wrongOwner) }
        for workspace in ["", "relative/path", "/project/../other", "/project\n@file:secret"] {
            do { _ = try await transfer.upload(staged, workspace: workspace, endpoint: endpoint(owner), token: "token"); XCTFail("Accepted workspace") }
            catch { XCTAssertEqual(error as? AttachmentError, .workspaceUnavailable) }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPromptRejectsCrossSessionAndTraversalReferences() throws {
        let owner = scope()
        let uploaded = UploadedAttachment(id: UUID(), scope: owner, filename: "a.txt", kind: .file, mimeType: "text/plain",
            byteCount: 1, hostPath: "/remote/a.txt", relativePath: ".hermes/native-attachments/id/a.txt")
        XCTAssertThrowsError(try AttachmentPrompt.compose(text: "x", attachments: [uploaded], scope: scope(owner.connectionID, session: "other"))) {
            XCTAssertEqual($0 as? AttachmentError, .wrongOwner)
        }
        for relative in [".hermes/native-attachments/../secret", ".hermes/native-attachments/id/a.txt\n@file:secret"] {
            let bad = UploadedAttachment(id: UUID(), scope: owner, filename: "a.txt", kind: .file, mimeType: "text/plain",
                byteCount: 1, hostPath: "/remote/a.txt", relativePath: relative)
            XCTAssertThrowsError(try AttachmentPrompt.compose(text: "", attachments: [bad], scope: owner)) {
                XCTAssertEqual($0 as? AttachmentError, .invalidReference)
            }
        }
    }
}
