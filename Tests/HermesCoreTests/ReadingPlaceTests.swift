import Foundation
import XCTest
@testable import HermesCore

@MainActor
final class ReadingPlaceTests: XCTestCase {
    func testPlacesRemainIsolatedByConnectionProfileAndSession() throws {
        let suite = "reading-place-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = SessionOwner(connectionID: UUID(), profile: "work")
        let otherProfile = SessionOwner(connectionID: owner.connectionID, profile: "personal")
        let otherConnection = SessionOwner(connectionID: UUID(), profile: owner.profile)
        let session = StoredSessionID(rawValue: "one")
        let otherSession = StoredSessionID(rawValue: "two")
        let store = HierarchyClassificationStore(defaults: defaults)
        store.rememberPlace("row-1", for: session, owner: owner)
        store.rememberPlace("row-2", for: otherSession, owner: owner)
        store.rememberPlace("row-3", for: session, owner: otherProfile)
        store.rememberPlace("row-4", for: session, owner: otherConnection)

        let reopened = HierarchyClassificationStore(defaults: defaults)
        XCTAssertEqual(reopened.place(for: session, owner: owner).visibleMessageID, "row-1")
        XCTAssertEqual(reopened.place(for: otherSession, owner: owner).visibleMessageID, "row-2")
        XCTAssertEqual(reopened.place(for: session, owner: otherProfile).visibleMessageID, "row-3")
        XCTAssertEqual(reopened.place(for: session, owner: otherConnection).visibleMessageID, "row-4")
        XCTAssertNil(reopened.place(for: otherSession, owner: otherConnection).visibleMessageID)
    }

    func testLegacyFallbackAndExplicitBottomSurviveOrdinaryUpdatesAndReopen() throws {
        let suite = "reading-place-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = SessionOwner(connectionID: UUID(), profile: "work")
        let session = StoredSessionID(rawValue: "one")
        let store = HierarchyClassificationStore(defaults: defaults)
        store.update(for: owner) { $0.places[session.rawValue] = SessionPlace(visibleMessageID: "legacy") }
        XCTAssertEqual(store.place(for: session, owner: owner).visibleMessageID, "legacy")
        store.rememberPlace("new", for: session, owner: owner)
        store.update(for: owner) { $0.readRunIDs.insert("run-1") }
        XCTAssertEqual(HierarchyClassificationStore(defaults: defaults).place(for: session, owner: owner).visibleMessageID, "new")

        store.rememberPlace(nil, for: session, owner: owner)
        store.update(for: owner) { $0.readRunIDs.insert("run-2") }
        let reopened = HierarchyClassificationStore(defaults: defaults)
        XCTAssertNil(reopened.place(for: session, owner: owner).visibleMessageID)
        XCTAssertEqual(reopened.classification(for: owner).places[session.rawValue]?.visibleMessageID, "legacy")
        XCTAssertEqual(reopened.classification(for: owner).readRunIDs, ["run-1", "run-2"])
    }

    func testScrollingDoesNotRewriteClassificationOrInvalidateItsRevision() throws {
        let suite = "reading-place-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = SessionOwner(connectionID: UUID(), profile: "work")
        let session = StoredSessionID(rawValue: "one")
        let store = HierarchyClassificationStore(defaults: defaults)
        store.update(for: owner) {
            $0.cachedHomeMessages = [ChatMessage(role: .assistant, text: String(repeating: "a", count: 500_000))]
            $0.workspaces = [TalariaWorkspace(name: "Research", sessionIDs: [session])]
        }
        let classification = store.classification(for: owner)
        let revision = store.revision
        let payloads = defaults.dictionaryRepresentation().compactMapValues { $0 as? Data }
        XCTAssertFalse(payloads.isEmpty)
        for index in 0..<100 { store.rememberPlace("row-\(index)", for: session, owner: owner) }
        store.rememberPlace(nil, for: session, owner: owner)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.classification(for: owner), classification)
        XCTAssertEqual(defaults.dictionaryRepresentation().compactMapValues { $0 as? Data }, payloads)
        XCTAssertEqual(HierarchyClassificationStore(defaults: defaults).classification(for: owner), classification)
    }

    func testSyntheticReadingPlaceBenchmark() throws {
        let suite = "reading-place-benchmark-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = SessionOwner(connectionID: UUID(), profile: "work")
        let session = StoredSessionID(rawValue: "one")
        let store = HierarchyClassificationStore(defaults: defaults)
        store.update(for: owner) {
            $0.cachedHomeMessages = [ChatMessage(role: .assistant, text: String(repeating: "a", count: 500_000))]
        }
        let clock = ContinuousClock()
        let legacy = clock.measure {
            for index in 0..<100 {
                store.update(for: owner) { $0.places[session.rawValue] = SessionPlace(visibleMessageID: "row-\(index)") }
            }
        }
        let revision = store.revision
        let separate = clock.measure {
            for index in 0..<100 { store.rememberPlace("new-row-\(index)", for: session, owner: owner) }
        }
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.place(for: session, owner: owner).visibleMessageID, "new-row-99")
        print("Reading-place benchmark: 100 crossings, 500 KB cached transcript; legacy=\(legacy), separate=\(separate)")
    }
}
