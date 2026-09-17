import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore

private enum SenderFixtureError: Error { case lostAcknowledgement, unexpectedMethod }
private actor SenderFixture {
    enum AttachMode: Sendable, Equatable { case accepted, rejected, lostAcknowledgement, malformed }
    struct Call: Sendable { let method: String; let params: JSONValue; let journal: JSONValue? }
    var calls: [Call] = []
    var queue: [String]
    let modes: [AttachMode]
    let result: JSONValue
    let canonicalize: Bool
    let journalURL: URL?
    var detachMalformed = false
    var runtimeMissing = false
    private var attachIndex = 0

    init(queue: [String] = [], modes: [AttachMode] = [], canonicalize: Bool = false,
         result: JSONValue = .object(["status": .string("streaming")]), journalURL: URL? = nil) {
        self.queue = queue; self.modes = modes; self.canonicalize = canonicalize
        self.result = result; self.journalURL = journalURL
    }
    func setDetachMalformed(_ value: Bool) { detachMalformed = value }
    func removeRuntime() { runtimeMissing = true; queue = [] }
    func request(_ method: String, _ params: JSONValue, _: TimeInterval) async throws -> JSONValue {
        let journal = journalURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        calls.append(Call(method: method, params: params, journal: journal))
        switch method {
        case "image.attach":
            let mode = modes.indices.contains(attachIndex) ? modes[attachIndex] : .accepted
            attachIndex += 1
            if mode == .rejected { return .object(["attached": .bool(false), "count": .number(Double(queue.count))]) }
            let raw = params["path"]!.stringValue!
            let path = canonicalize ? raw.replacingOccurrences(of: "/link/", with: "/canonical/") : raw
            queue.append(path)
            if mode == .lostAcknowledgement { throw SenderFixtureError.lostAcknowledgement }
            if mode == .malformed { return .null }
            return .object(["attached": .bool(true), "path": .string(path), "count": .number(Double(queue.count))])
        case "prompt.submit":
            if result == .string("lost") { throw SenderFixtureError.lostAcknowledgement }
            if result["status"]?.stringValue == "queued" { queue = [] }
            // Streaming acknowledges before admission; deliberately leave the
            // queue untouched to simulate failed/canceled agent initialization.
            return result
        case "image.detach":
            if runtimeMissing { throw JSONRPCError(code: 4001, message: "session not found") }
            if detachMalformed { return .object(["detached": .bool(false)]) }
            let before = queue.count
            queue.removeAll { $0 == params["path"]?.stringValue }
            return .object(["detached": .bool(before != queue.count), "count": .number(Double(queue.count))])
        default: throw SenderFixtureError.unexpectedMethod
        }
    }
    nonisolated var operation: AttachmentSender.Request { { method, params, timeout in try await self.request(method, params, timeout) } }
}

private actor SenderGate {
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func block() async {
        blocked = true
        for observer in observers { observer.resume() }
        observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class AttachmentSenderTests: XCTestCase {
    private let runtime = RuntimeSessionID(rawValue: "live-1")
    private func scope(connection: UUID = UUID(), profile: String = "work", stored: String = "stored-1") -> ComposerScope {
        ComposerScope(connectionID: connection, profile: profile, storedSessionID: StoredSessionID(rawValue: stored))
    }
    private func image(_ scope: ComposerScope, path: String = "/link/photo.png") -> UploadedAttachment {
        UploadedAttachment(id: UUID(), scope: scope, filename: "photo.png", kind: .image,
            mimeType: "image/png", byteCount: 8, hostPath: path)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-sender-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func expectError(_ expected: AttachmentSendError?, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Operation unexpectedly succeeded") }
        catch {
            guard let actual = error as? AttachmentSendError else { XCTFail("Unexpected error: \(error)"); return }
            if let expected { XCTAssertEqual(actual, expected) }
            else if case .preparationFailed = actual {} else { XCTFail("Expected definitely unsent preparation failure, got \(actual)") }
        }
    }

    func testJournalPrecedesAttachAndStoresCanonicalPathBeforeSubmit() async throws {
        let directory = try directory(), owner = scope()
        let sender = AttachmentSender(directory: directory)
        let fixture = SenderFixture(canonicalize: true, journalURL: directory.appendingPathComponent("pending-sends-v1.json"))
        _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.method), ["image.attach", "prompt.submit"])
        XCTAssertEqual(calls[0].journal?.arrayValue?.first?["attempts"]?.arrayValue?.first?["requestedPath"], .string("/link/photo.png"))
        XCTAssertEqual(calls[1].journal?.arrayValue?.first?["attempts"]?.arrayValue?.first?["canonicalPath"], .string("/canonical/photo.png"))
        XCTAssertEqual(calls[1].journal?.arrayValue?.first?["submitted"], .bool(true))
        XCTAssertEqual(calls[1].params["queued"], .bool(true))
        XCTAssertEqual(calls[0].params["profile"], .string("work"))
        let pending = await sender.hasPending(owner, runtimeID: runtime)
        XCTAssertTrue(pending)
    }

    func testStreamingInitFailureRetainsJournalAndBlocksReplayUntilIdleCleanup() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture(canonicalize: true)
        _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        await expectError(.reconciliationRequired) {
            _ = try await sender.submit(text: "Another turn", attachments: [], scope: owner, runtimeID: runtime, request: fixture.operation)
        }
        await expectError(.reconciliationRequired) {
            try await sender.reconcile(owner, runtimeID: runtime, isIdle: false, request: fixture.operation)
        }
        try await sender.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        let calls = await fixture.calls, queue = await fixture.queue, pending = await sender.hasPending(owner)
        XCTAssertEqual(calls.map(\.method), ["image.attach", "prompt.submit", "image.detach"])
        XCTAssertEqual(calls.last?.params["path"], .string("/canonical/photo.png"))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(pending)
    }

    func testQueuedAcknowledgementTransfersOwnershipWithoutDetach() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory())
        let fixture = SenderFixture(result: .object(["status": .string("queued")]))
        _ = try await sender.submit(text: "", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        try await sender.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        let methods = await fixture.calls.map(\.method), pending = await sender.hasPending(owner)
        XCTAssertEqual(methods, ["image.attach", "prompt.submit"])
        XCTAssertFalse(pending)
    }

    func testFalseAndMalformedAttachAcknowledgementsNeverSubmitPrompt() async throws {
        for mode in [SenderFixture.AttachMode.rejected, .malformed] {
            let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture(modes: [mode])
            await expectError(nil) {
                _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
            }
            let calls = await fixture.calls, queue = await fixture.queue, pending = await sender.hasPending(owner)
            XCTAssertFalse(calls.contains { $0.method == "prompt.submit" })
            XCTAssertTrue(queue.isEmpty)
            XCTAssertFalse(pending)
        }
    }

    func testExistingForeignQueueIsPreservedAndPreventsPromptSubmission() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory())
        let fixture = SenderFixture(queue: ["/other/client.png"], canonicalize: true)
        await expectError(nil) {
            _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        }
        let queue = await fixture.queue, calls = await fixture.calls
        XCTAssertEqual(queue, ["/other/client.png"])
        XCTAssertEqual(calls.map(\.method), ["image.attach", "image.detach"])
        XCTAssertEqual(calls.last?.params["path"], .string("/canonical/photo.png"))
    }

    func testLostAttachAcknowledgementCleansExactPathBeforeAllowingRetry() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory())
        let fixture = SenderFixture(modes: [.lostAcknowledgement])
        await expectError(nil) {
            _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        }
        let queue = await fixture.queue, calls = await fixture.calls, pending = await sender.hasPending(owner)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(calls.map(\.method), ["image.attach", "image.detach"])
        XCTAssertFalse(pending)
    }

    func testLostCanonicalAttachAcknowledgementDoesNotGuessOrDiscardJournal() async throws {
        let directory = try directory(), owner = scope()
        let sender = AttachmentSender(directory: directory)
        let fixture = SenderFixture(modes: [.lostAcknowledgement], canonicalize: true)
        await expectError(.reconciliationRequired) {
            _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        }
        let restored = AttachmentSender(directory: directory)
        let pending = await restored.hasPending(owner, runtimeID: runtime), queue = await fixture.queue
        XCTAssertTrue(pending)
        XCTAssertEqual(queue, ["/canonical/photo.png"])
        await expectError(.reconciliationRequired) {
            try await restored.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        }
        await fixture.removeRuntime()
        try await restored.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        let remaining = await restored.hasPending(owner)
        XCTAssertFalse(remaining)
    }

    func testVoiceStoppedCleansImagesAndReturnsDefiniteNonSubmission() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory())
        let fixture = SenderFixture(canonicalize: true, result: .object(["voice_stopped": .bool(true)]))
        let result = try await sender.submit(text: "Stop", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        let calls = await fixture.calls, queue = await fixture.queue, pending = await sender.hasPending(owner)
        XCTAssertEqual(result["voice_stopped"], .bool(true))
        XCTAssertEqual(calls.map(\.method), ["image.attach", "prompt.submit", "image.detach"])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertFalse(pending)
    }

    func testUnknownMalformedAndLostSubmitAcknowledgementsStayLockedWithoutReplay() async throws {
        for result in [JSONValue.null, .object(["status": .string("future")]), .string("lost"), .object(["status": .string("steered")])] {
            let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture(result: result)
            await expectError(.uncertain) {
                _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
            }
            let pending = await sender.hasPending(owner), calls = await fixture.calls
            XCTAssertTrue(pending)
            XCTAssertEqual(calls.map(\.method), ["image.attach", "prompt.submit"])
        }
    }

    func testMalformedDetachCannotUnlockJournal() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture()
        _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        await fixture.setDetachMalformed(true)
        await expectError(.reconciliationRequired) {
            try await sender.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        }
        let pending = await sender.hasPending(owner)
        XCTAssertTrue(pending)
    }

    func testRotatedStoredIDMatchesRuntimeAndCannotReconcileDuringInFlightAttach() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture(), gate = SenderGate()
        let rotated = scope(connection: owner.connectionID, stored: "rotated")
        let operation: AttachmentSender.Request = { method, params, timeout in
            if method == "image.attach" { await gate.block() }
            return try await fixture.request(method, params, timeout)
        }
        let task = Task { try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: operation) }
        await gate.waitUntilBlocked()
        let pending = await sender.hasPending(rotated, runtimeID: runtime)
        XCTAssertTrue(pending)
        await expectError(.reconciliationRequired) {
            try await sender.reconcile(rotated, runtimeID: runtime, isIdle: true, request: fixture.operation)
        }
        await expectError(.reconciliationRequired) {
            _ = try await sender.submit(text: "Duplicate", attachments: [], scope: rotated, runtimeID: runtime, request: fixture.operation)
        }
        await gate.release()
        _ = try await task.value
        try await sender.reconcile(rotated, runtimeID: runtime, isIdle: true, request: fixture.operation)
        let remaining = await sender.hasPending(rotated, runtimeID: runtime)
        XCTAssertFalse(remaining)
    }

    func testStoredIDAliasSurvivesRestartAndNewRuntimeWhileCleanupTargetsOriginalRuntime() async throws {
        let directory = try directory(), owner = scope(), fixture = SenderFixture()
        let sender = AttachmentSender(directory: directory)
        let rotated = scope(connection: owner.connectionID, stored: "rotated")
        _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        let observed = await sender.hasPending(rotated, runtimeID: runtime)
        XCTAssertTrue(observed)
        let restored = AttachmentSender(directory: directory)
        let newRuntime = RuntimeSessionID(rawValue: "live-after-restart")
        let pending = await restored.hasPending(rotated, runtimeID: newRuntime)
        XCTAssertTrue(pending)
        try await restored.reconcile(rotated, runtimeID: newRuntime, isIdle: true, request: fixture.operation)
        let calls = await fixture.calls, remaining = await restored.hasPending(rotated)
        XCTAssertEqual(calls.last?.params["session_id"], .string(runtime.rawValue))
        XCTAssertFalse(remaining)
    }

    func testLegacyJournalDoesNotAssumeOldPathsWereCanonical() async throws {
        let directory = try directory(), owner = scope()
        let legacy = JSONValue.array([.object([
            "scope": try JSONValue.from(owner), "runtimeID": .string(runtime.rawValue),
            "imagePaths": .array([.string("/link/photo.png")]), "submitted": .bool(false)
        ])])
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("pending-sends-v1.json"))
        let sender = AttachmentSender(directory: directory)
        let fixture = SenderFixture(queue: ["/canonical/photo.png"])
        await expectError(.reconciliationRequired) {
            try await sender.reconcile(owner, runtimeID: runtime, isIdle: true, request: fixture.operation)
        }
        let pending = await sender.hasPending(owner), queue = await fixture.queue
        XCTAssertTrue(pending)
        XCTAssertEqual(queue, ["/canonical/photo.png"])
    }

    func testRuntimeMatchingNeverCrossesConnectionOrProfile() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture()
        _ = try await sender.submit(text: "Inspect", attachments: [image(owner)], scope: owner, runtimeID: runtime, request: fixture.operation)
        let otherConnection = scope(), otherProfile = scope(connection: owner.connectionID, profile: "personal")
        for unrelated in [otherConnection, otherProfile] {
            let pending = await sender.hasPending(unrelated, runtimeID: runtime)
            XCTAssertFalse(pending)
            try await sender.reconcile(unrelated, runtimeID: runtime, isIdle: true, request: fixture.operation)
        }
        let calls = await fixture.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testDocumentAttachmentsForceQueueWhileTextOnlySteeringRemainsValid() async throws {
        let owner = scope(), sender = AttachmentSender(directory: try directory()), fixture = SenderFixture()
        let file = UploadedAttachment(id: UUID(), scope: owner, filename: "notes.txt", kind: .file, mimeType: "text/plain", byteCount: 1,
            hostPath: "/work/.hermes/native-attachments/id/notes.txt", relativePath: ".hermes/native-attachments/id/notes.txt")
        _ = try await sender.submit(text: "Read", attachments: [file], scope: owner, runtimeID: runtime, request: fixture.operation)
        let calls = await fixture.calls, pending = await sender.hasPending(owner)
        XCTAssertEqual(calls.map(\.method), ["prompt.submit"])
        XCTAssertEqual(calls[0].params["queued"], .bool(true))
        XCTAssertFalse(pending)
        let steer = SenderFixture(result: .object(["status": .string("steered")]))
        _ = try await sender.submit(text: "A correction", attachments: [], scope: owner, runtimeID: runtime, request: steer.operation)
        let textCalls = await steer.calls
        XCTAssertNil(textCalls[0].params["queued"])
    }
}
