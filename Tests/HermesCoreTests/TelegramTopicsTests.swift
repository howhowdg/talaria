import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore

final class TelegramTopicsTests: XCTestCase {
    private func row(chat: String = "-100123", thread: String = "7", key: String = "agent:telegram:group:-100123:7",
                     session: String = "session-7", name: JSONValue = .string("Trip")) -> JSONValue {
        .object(["chat_id": .string(chat), "thread_id": .string(thread), "session_key": .string(key),
                 "current_session_id": .string(session), "chat_type": .string("group"),
                 "chat_name": .string("Hermes"), "topic_name": name, "binding_source": .string("gateway_routing")])
    }
    private func snapshot(_ rows: [JSONValue], profile: String = "default", schema: Int = 1) -> JSONValue {
        .object(["schema_version": .number(Double(schema)), "profile": .string(profile), "topics": .array(rows)])
    }
    private func topic(thread: String = "7", session: String = "session-7", name: String = "Trip") -> TelegramTopic {
        TelegramTopic(id: .init(chatID: "-100123", threadID: thread, sessionKey: "agent:telegram:group:-100123:\(thread)"),
                      currentSessionID: .init(rawValue: session), chatType: "group", chatName: "Hermes", topicName: name)
    }

    func testExplicitIdentitySurvivesLabelAndSessionChanges() throws {
        let before = try TelegramTopicsSnapshot(json: snapshot([row()]), expectedProfile: "default")
        let after = try TelegramTopicsSnapshot(json: snapshot([row(session: "session-after-reset", name: .string("New name"))]), expectedProfile: "default")
        XCTAssertEqual(before.topics.first?.id, after.topics.first?.id)
        XCTAssertNotEqual(before.topics.first?.currentSessionID, after.topics.first?.currentSessionID)
        XCTAssertEqual(after.topics.first?.displayLabel, "New name")
    }

    func testAbsentLabelDoesNotInferGeneralFromThreadID() throws {
        let result = try TelegramTopicsSnapshot(json: snapshot([row(thread: "1", name: .null)]), expectedProfile: "default")
        XCTAssertNil(result.topics.first?.topicName)
        XCTAssertEqual(result.topics.first?.displayLabel, "Topic 1")
    }

    func testEmojiJoinersInRealTopicNamesArePreserved() throws {
        let name = "Family 👨‍👩‍👧‍👦"
        let result = try TelegramTopicsSnapshot(json: snapshot([row(name: .string(name))]), expectedProfile: "default")
        XCTAssertEqual(result.topics.first?.displayLabel, name)
    }

    func testSchemaAndProfileMustMatch() {
        XCTAssertThrowsError(try TelegramTopicsSnapshot(json: snapshot([], schema: 2), expectedProfile: "default")) {
            XCTAssertEqual($0 as? TelegramTopicsError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try TelegramTopicsSnapshot(json: snapshot([], profile: "other"), expectedProfile: "default")) {
            XCTAssertEqual($0 as? TelegramTopicsError, .profileMismatch)
        }
        XCTAssertNoThrow(try TelegramTopicsSnapshot(json: snapshot([]), expectedProfile: "default"))
    }

    func testMalformedIdentityOrLabelsRejectEntireSnapshot() {
        let badRows = [row(chat: ""), row(thread: "bad"), row(key: ""), row(session: "\nwrong"), row(name: .number(8))]
        for bad in badRows {
            XCTAssertThrowsError(try TelegramTopicsSnapshot(json: snapshot([row(), bad]), expectedProfile: "default"))
        }
        var unverified = row().objectValue!
        unverified["binding_source"] = .string("most_recent")
        XCTAssertThrowsError(try TelegramTopicsSnapshot(json: snapshot([.object(unverified)]), expectedProfile: "default"))
    }

    func testDuplicateRoutesAndSessionsAreAmbiguousButSameNamedTopicsAreDistinct() throws {
        for duplicate in [row(), row(thread: "8", session: "other"), row(thread: "8", key: "other-route")] {
            XCTAssertThrowsError(try TelegramTopicsSnapshot(json: snapshot([row(), duplicate]), expectedProfile: "default")) {
                XCTAssertEqual($0 as? TelegramTopicsError, .duplicateBinding)
            }
        }
        let secondChat = row(chat: "-100456", key: "agent:telegram:group:-100456:7", session: "other-chat")
        let result = try TelegramTopicsSnapshot(json: snapshot([row(), secondChat]), expectedProfile: "default")
        XCTAssertEqual(result.topics.count, 2)
        XCTAssertNotEqual(result.topics[0].id, result.topics[1].id)
        XCTAssertEqual(result.topics[0].displayLabel, result.topics[1].displayLabel)
    }

    func testPerUserRoutesInSameGroupTopicRemainDistinct() throws {
        let result = try TelegramTopicsSnapshot(json: snapshot([
            row(key: "agent:telegram:group:-100123:7:user1", session: "user1-session"),
            row(key: "agent:telegram:group:-100123:7:user2", session: "user2-session")
        ]), expectedProfile: "default")
        XCTAssertNotEqual(result.topics[0].id, result.topics[1].id)
    }

    func testExplicitImportIsIdempotentAndPreservesCustomWorkspaceNameAndArchive() throws {
        let general = topic(thread: "1", session: "home", name: "General")
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([general, trip], home: general.id, asWorkspaces: [trip.id])
        let workspaceID = try XCTUnwrap(value.workspaces.first?.id)
        value.workspaces[0].name = "My trip"; value.workspaces[0].purpose = "Keep this purpose"
        value.workspaces[0].isArchived = true
        value.importTelegramTopics([general, trip], home: general.id, asWorkspaces: [trip.id])
        XCTAssertEqual(value.homeSessionID, general.currentSessionID)
        XCTAssertEqual(value.workspaces.count, 1)
        XCTAssertEqual(value.workspaces[0].id, workspaceID)
        XCTAssertEqual(value.workspaces[0].name, "My trip")
        XCTAssertEqual(value.workspaces[0].purpose, "Keep this purpose")
        XCTAssertTrue(value.workspaces[0].isArchived)
        XCTAssertEqual(value.telegramTopicAssignments.count, 2)
    }

    func testOnlyUserSelectedTopicsAreImportedAndGeneralDoesNotChooseItself() {
        let general = topic(thread: "1", session: "general", name: "General")
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([general, trip], home: nil, asWorkspaces: [trip.id])
        XCTAssertNil(value.homeSessionID)
        XCTAssertEqual(value.workspaces.flatMap(\.sessionIDs), [trip.currentSessionID])
        XCTAssertEqual(value.telegramTopicAssignments.map(\.identity), [trip.id])
    }

    func testReconciliationFollowsAuthoritativeResetForHomeAndWorkspace() {
        let general = topic(thread: "1", session: "home", name: "General")
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([general, trip], home: general.id, asWorkspaces: [trip.id])
        value.cachedHomeMessages = [.init(role: .assistant, text: "Old history")]
        value.reconcileTelegramTopics([topic(thread: "1", session: "new-home", name: "Renamed General"),
                                       topic(session: "new-trip", name: "Renamed Trip")])
        XCTAssertEqual(value.homeSessionID?.rawValue, "new-home")
        XCTAssertTrue(value.cachedHomeMessages.isEmpty)
        XCTAssertEqual(value.workspaces[0].sessionIDs.map(\.rawValue), ["new-trip"])
        XCTAssertEqual(value.workspaces[0].name, "Renamed Trip")
    }

    func testMissingOrDifferentRouteNeverRedirectsAssignment() {
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([trip], home: trip.id, asWorkspaces: [])
        let before = value
        value.reconcileTelegramTopics([])
        XCTAssertEqual(value, before)
        value.reconcileTelegramTopics([topic(thread: "999", session: "newer", name: "Trip")])
        XCTAssertEqual(value, before)
    }

    func testManualHomeChoiceRevokesImportedAuthority() {
        let general = topic(thread: "1", session: "home", name: "General")
        var value = HierarchyClassification()
        value.importTelegramTopics([general], home: general.id, asWorkspaces: [])
        value.homeSessionID = .init(rawValue: "manually-chosen")
        value.reconcileTelegramTopics([topic(thread: "1", session: "reset-home", name: "General")])
        XCTAssertEqual(value.homeSessionID?.rawValue, "manually-chosen")
        XCTAssertTrue(value.telegramTopicAssignments.isEmpty)
        value.homeSessionID = general.currentSessionID
        value.reconcileTelegramTopics([topic(thread: "1", session: "reset-home", name: "General")])
        XCTAssertEqual(value.homeSessionID, general.currentSessionID)
    }

    func testManualWorkspaceReassignmentRevokesImportedAuthority() {
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([trip], home: nil, asWorkspaces: [trip.id])
        value.workspaces[0].sessionIDs = []
        value.workspaces.append(.init(name: "Manual", sessionIDs: [trip.currentSessionID]))
        value.reconcileTelegramTopics([topic(session: "reset-trip")])
        XCTAssertTrue(value.telegramTopicAssignments.isEmpty)
        XCTAssertEqual(value.workspaces.flatMap(\.sessionIDs), [trip.currentSessionID])
    }

    func testImportReusesExplicitExistingWorkspaceAndNeverStealsHome() {
        let trip = topic()
        var value = HierarchyClassification()
        value.workspaces = [.init(name: "Already organised", sessionIDs: [trip.currentSessionID])]
        let existingID = value.workspaces[0].id
        value.importTelegramTopics([trip], home: nil, asWorkspaces: [trip.id])
        XCTAssertEqual(value.workspaces.count, 1)
        XCTAssertEqual(value.telegramTopicAssignments[0].destination, .workspace(existingID))
        var homeOnly = HierarchyClassification()
        homeOnly.homeSessionID = trip.currentSessionID
        homeOnly.importTelegramTopics([trip], home: nil, asWorkspaces: [trip.id])
        XCTAssertTrue(homeOnly.workspaces.isEmpty)
        XCTAssertEqual(homeOnly.homeSessionID, trip.currentSessionID)
    }

    func testAssignmentsRoundTripAndOldStoresDecodeEmpty() throws {
        let trip = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([trip], home: trip.id, asWorkspaces: [])
        XCTAssertEqual(try JSONDecoder().decode(HierarchyClassification.self, from: JSONEncoder().encode(value)), value)
        let legacy = try JSONDecoder().decode(HierarchyClassification.self, from: Data(#"{"homeSessionID":"chosen"}"#.utf8))
        XCTAssertTrue(legacy.telegramTopicAssignments.isEmpty)
        XCTAssertEqual(legacy.homeSessionID?.rawValue, "chosen")
    }

    func testNumberedImportBackfillsRealNameAndTracksRenameWithoutLosingIdentity() throws {
        let unnamed = try TelegramTopicsSnapshot(json: snapshot([row(name: .null)]), expectedProfile: "default").topics[0]
        var value = HierarchyClassification()
        value.importTelegramTopics([unnamed], home: nil, asWorkspaces: [unnamed.id])
        let id = value.workspaces[0].id
        value.workspaces[0].isArchived = true
        value.reconcileTelegramTopics([topic(name: "Travel ✈️")])
        XCTAssertEqual(value.workspaces[0].name, "Travel ✈️")
        value.reconcileTelegramTopics([topic(name: "Summer travel")])
        XCTAssertEqual(value.workspaces[0].name, "Summer travel")
        value.reconcileTelegramTopics([unnamed])
        XCTAssertEqual(value.workspaces[0].name, "Summer travel")
        XCTAssertEqual(value.workspaces[0].id, id)
        XCTAssertTrue(value.workspaces[0].isArchived)
        XCTAssertEqual(value.workspaces[0].sessionIDs, [unnamed.currentSessionID])
    }

    func testCustomWorkspaceNameDoesNotFollowSubsequentTelegramRenames() {
        let original = topic()
        var value = HierarchyClassification()
        value.importTelegramTopics([original], home: nil, asWorkspaces: [original.id])
        value.workspaces[0].name = "My private planning"
        value.reconcileTelegramTopics([topic(name: "New Telegram title")])
        XCTAssertEqual(value.workspaces[0].name, "My private planning")
        XCTAssertEqual(value.telegramTopicAssignments[0].followsTopicName, false)
    }

    func testAdoptedManualWorkspaceDoesNotBecomeNameManaged() {
        let original = topic()
        var value = HierarchyClassification()
        value.workspaces = [.init(name: "Trip", sessionIDs: [original.currentSessionID])]
        value.importTelegramTopics([original], home: nil, asWorkspaces: [original.id])
        value.reconcileTelegramTopics([topic(name: "Renamed")])
        XCTAssertEqual(value.workspaces[0].name, "Trip")
    }

    func testLegacyAssignmentDecodesAndOnlyNumberedDefaultMigrates() throws {
        let original = topic()
        for name in ["Topic 7", "User's name"] {
            var value = HierarchyClassification()
            value.workspaces = [.init(name: name, sessionIDs: [original.currentSessionID])]
            value.telegramTopicAssignments = [.init(identity: original.id, destination: .workspace(value.workspaces[0].id),
                                                    lastKnownSessionID: original.currentSessionID)]
            let data = try JSONEncoder().encode(value)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("followsTopicName"))
            var restored = try JSONDecoder().decode(HierarchyClassification.self, from: data)
            restored.reconcileTelegramTopics([original])
            XCTAssertEqual(restored.workspaces[0].name, name == "Topic 7" ? "Trip" : name)
        }
    }

    func testNameUpdateIsScopedToTheFullTopicIdentity() throws {
        let first = topic(name: "Shared name")
        let other = try TelegramTopicsSnapshot(json: snapshot([row(chat: "-100456", key: "other", session: "other", name: .string("Shared name"))]), expectedProfile: "default").topics[0]
        var value = HierarchyClassification()
        value.importTelegramTopics([first, other], home: nil, asWorkspaces: [first.id, other.id])
        value.reconcileTelegramTopics([topic(name: "New first name"), other])
        XCTAssertEqual(value.workspaces.map(\.name), ["New first name", "Shared name"])
    }
}
