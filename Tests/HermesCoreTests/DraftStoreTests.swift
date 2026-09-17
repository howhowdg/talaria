import XCTest
@testable import HermesCore

@MainActor
final class DraftStoreTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talaria-drafts-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testDraftsSurviveRelaunchAndRemainScopedToConnectionProfileAndSession() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = UUID()
        let a = ComposerScope(connectionID: connection, profile: "default", storedSessionID: .init(rawValue: "same-id"))
        let b = ComposerScope(connectionID: connection, profile: "work", storedSessionID: a.storedSessionID)
        let c = ComposerScope(connectionID: UUID(), profile: "default", storedSessionID: a.storedSessionID)
        let store = DraftStore(directory: directory)
        store.setText("Personal draft", for: a); store.setText("Work draft", for: b)
        store.setText("Different host", for: c)
        store.select(a.storedSessionID, owner: .init(connectionID: connection, profile: "default"))
        try store.flush()
        let restored = DraftStore(directory: directory)
        XCTAssertEqual(restored.text(for: a), "Personal draft")
        XCTAssertEqual(restored.text(for: b), "Work draft")
        XCTAssertEqual(restored.text(for: c), "Different host")
        XCTAssertEqual(restored.selectedSession(for: .init(connectionID: connection, profile: "default")), a.storedSessionID)
        XCTAssertNil(restored.selectedSession(for: .init(connectionID: connection, profile: "work")))
    }
    func testCompressionIdentityMovePreservesDraftAndSelectedSession() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = SessionOwner(connectionID: UUID(), profile: "default")
        let old = ComposerScope(owner: owner, sessionID: .init(rawValue: "before"))
        let new = ComposerScope(owner: owner, sessionID: .init(rawValue: "after"))
        let store = DraftStore(directory: directory)
        store.setText("Unsent text", for: old); store.select(old.storedSessionID, owner: owner)
        store.move(from: old, to: new)
        try store.flush()
        XCTAssertEqual(store.text(for: old), "")
        XCTAssertEqual(store.text(for: new), "Unsent text")
        XCTAssertEqual(store.selectedSession(for: owner), new.storedSessionID)
    }
    func testCorruptStoreIsPreservedBeforeWritingNewDrafts() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("drafts-v1.json")
        try Data("broken draft data".utf8).write(to: file)
        let store = DraftStore(directory: directory)
        XCTAssertNotNil(store.lastError)
        store.setText("New draft", for: .init(connectionID: UUID(), profile: "default", storedSessionID: .init(rawValue: "s")))
        try store.flush()
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("drafts-unreadable-") })
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "broken draft data")
        XCTAssertNil(store.lastError)
    }
    func testClearingDraftPersistsRemoval() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = ComposerScope(connectionID: UUID(), profile: "default", storedSessionID: .init(rawValue: "s"))
        let store = DraftStore(directory: directory)
        store.setText("Sent", for: scope); try store.flush()
        store.setText("", for: scope); try store.flush()
        XCTAssertEqual(DraftStore(directory: directory).text(for: scope), "")
    }
}
