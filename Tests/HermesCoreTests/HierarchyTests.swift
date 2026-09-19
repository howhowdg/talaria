import Foundation
import XCTest
import HermesProtocol
import HermesTransport
@testable import HermesCore

@MainActor
final class HierarchyClassificationTests: XCTestCase {
    func testHomeAndWorkspaceAssignmentsPersistAndNeverLeakAcrossOwners() throws {
        let suite = "hierarchy-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = SessionOwner(connectionID: UUID(), profile: "work")
        let sameProfileOtherConnection = SessionOwner(connectionID: UUID(), profile: "work")
        let sameConnectionOtherProfile = SessionOwner(connectionID: owner.connectionID, profile: "other")
        let session = StoredSessionID(rawValue: "home")
        let store = HierarchyClassificationStore(defaults: defaults)
        store.update(for: owner) { value in
            value.homeSessionID = session
            value.workspaces = [TalariaWorkspace(name: "Planning", purpose: "Explicit purpose", sessionIDs: [.init(rawValue: "assigned")])]
            value.archivedSessionIDs.insert(.init(rawValue: "archived"))
            value.readRunIDs.insert("run")
            value.places["home"] = SessionPlace(visibleMessageID: "row-8")
        }
        let reopened = HierarchyClassificationStore(defaults: defaults)
        XCTAssertEqual(reopened.classification(for: owner).homeSessionID, session)
        XCTAssertEqual(reopened.classification(for: owner).workspaces.first?.purpose, "Explicit purpose")
        XCTAssertTrue(reopened.classification(for: owner).readRunIDs.contains("run"))
        XCTAssertEqual(reopened.classification(for: owner).places["home"]?.visibleMessageID, "row-8")
        XCTAssertEqual(reopened.classification(for: sameProfileOtherConnection), HierarchyClassification())
        XCTAssertEqual(reopened.classification(for: sameConnectionOtherProfile), HierarchyClassification())
    }

    func testSourceRetainedWithoutInferringHomeOrWorkspace() throws {
        let summary = SessionSummary(json: .object(["id": .string("one"), "title": .string("Home"), "source": .string("telegram")]))
        XCTAssertEqual(summary.source, "telegram")
        let store = HierarchyClassificationStore(defaults: UserDefaults(suiteName: "empty-hierarchy-\(UUID())")!)
        let value = store.classification(for: SessionOwner(connectionID: UUID(), profile: "default"))
        XCTAssertNil(value.homeSessionID); XCTAssertTrue(value.workspaces.isEmpty)
    }

    func testOnlyTypedNotFoundMeansHomeUnavailable() {
        XCTAssertTrue(HomeResolution.isConfirmedMissing(JSONRPCError(code: 4007, message: "session not found")))
        XCTAssertTrue(HomeResolution.isConfirmedMissing(GatewayTransportError.httpStatus(404)))
        XCTAssertFalse(HomeResolution.isConfirmedMissing(JSONRPCError(code: -32603, message: "session not found")))
        XCTAssertFalse(HomeResolution.isConfirmedMissing(GatewayTransportError.httpStatus(500)))
        XCTAssertFalse(HomeResolution.isConfirmedMissing(GatewayTransportError.authenticationRejected))
        XCTAssertFalse(HomeResolution.isConfirmedMissing(URLError(.timedOut)))
    }
}

final class AutomationRunResultTests: XCTestCase {
    private func run(_ extra: [String: JSONValue] = [:]) -> MobileRun {
        let automation = MobileSchedule(json: .object(["id": .string("automation")]))!
        return MobileRun(json: .object(["id": .string("run"), "ended_at": .number(1_800_000_001), "end_reason": .string("cron_complete")].merging(extra, uniquingKeysWith: { _, value in value })), schedule: automation, profile: "default")!
    }
    private func response(_ rows: [(String, String)]) -> JSONValue {
        .object(["messages": .array(rows.map { .object(["role": .string($0.0), "content": .string($0.1)]) })])
    }
    func testFinalAssistantResultDoesNotReuseEarlierTurnOrInterimText() {
        let completed = AutomationRunResult.parse(run(), response: response([("user", "Do work"), ("assistant", "Looking"), ("tool", "Data"), ("assistant", "Final answer")]))
        XCTAssertEqual(completed.result, "Final answer"); XCTAssertEqual(completed.status, .completed)
        for ending in ["user", "tool"] {
            let incomplete = AutomationRunResult.parse(run(), response: response([("assistant", "An earlier answer"), (ending, "Still waiting")]))
            XCTAssertEqual(incomplete.result, ""); XCTAssertEqual(incomplete.status, .noOutput)
        }
    }
    func testFailedAndWorkingRunsDoNotBecomeCompletedBecauseOutputExists() {
        XCTAssertEqual(AutomationRunResult.parse(run(["end_reason": .string("error")]), response: response([("assistant", "Partial")])).status, .failed)
        XCTAssertEqual(AutomationRunResult.parse(run(["is_active": .bool(true)]), response: response([("assistant", "Partial")])).status, .working)
        let unknown = run(["ended_at": .null, "end_reason": .null])
        XCTAssertEqual(AutomationRunResult.parse(unknown, response: response([("assistant", "Some text")])).status, .unavailable)
    }
    func testSilentAndCompactionProjectionAreNotExposedAsResults() {
        XCTAssertEqual(AutomationRunResult.parse(run(), response: response([("assistant", "[SILENT]")])).status, .noOutput)
        let projected: JSONValue = .object(["messages": .array([
            .object(["role": .string("assistant"), "content": .string("internal compaction"), "display_content": .string("Public result")]),
            .object(["role": .string("assistant"), "content": .string("secret carrier"), "display_kind": .string("hidden")])])])
        let result = AutomationRunResult.parse(run(), response: projected)
        XCTAssertEqual(result.result, "Public result"); XCTAssertFalse(result.messages.contains { $0.text.contains("carrier") })
    }
}

final class WorkspaceFileReferencesTests: XCTestCase {
    func testOnlyRecordedFileOperationsWithinSessionDirectoryAreIncluded() {
        let session = StoredSessionID(rawValue: "session")
        let messages = [
            ChatMessage(role: .tool, text: "{}", toolName: "write_file", toolInput: #"{"path":"notes/result.md","content":"Text"}"#),
            ChatMessage(role: .tool, text: "{}", toolName: "read_file", toolInput: #"{"path":"../private.txt"}"#),
            ChatMessage(role: .tool, text: "/work/shell-guess.txt", toolName: "terminal"),
            ChatMessage(role: .tool, text: #"{"success":false}"#, toolName: "write_file", toolInput: #"{"path":"failed.txt"}"#),
            ChatMessage(role: .tool, text: "", toolName: "write_file", toolInput: #"{"path":"pending.txt"}"#, isStreaming: true)
        ]
        let files = WorkspaceFileReferences.collect(sessionID: session, cwd: "/work", messages: messages)
        XCTAssertEqual(files.map(\.path), ["/work/notes/result.md"])
        XCTAssertEqual(files.first?.sessionID, session)
        XCTAssertTrue(WorkspaceFileReferences.collect(sessionID: session, cwd: "", messages: messages).isEmpty)
    }
}

extension HierarchyClassificationTests {
    func testOlderClassificationFieldsDecodeWithoutErasingExplicitHome() throws {
        let value = try JSONDecoder().decode(HierarchyClassification.self, from: Data(#"{"homeSessionID":"chosen","workspaces":[]}"#.utf8))
        XCTAssertEqual(value.homeSessionID?.rawValue, "chosen")
        XCTAssertTrue(value.archivedSessionIDs.isEmpty)
        XCTAssertTrue(value.lineage.isEmpty)
    }

    func testUnreadableOrganisationDoesNotPreventSavingAnotherOwner() throws {
        let suite = "hierarchy-corruption-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corruptOwner = SessionOwner(connectionID: UUID(), profile: "old")
        let validOwner = SessionOwner(connectionID: UUID(), profile: "new")
        let encoded = try JSONEncoder().encode([corruptOwner.connectionID.uuidString, corruptOwner.profile])
        let key = "talaria.hierarchy.v1." + encoded.base64EncodedString()
        defaults.set(Data("not valid JSON".utf8), forKey: key)
        let store = HierarchyClassificationStore(defaults: defaults)
        _ = store.classification(for: corruptOwner)
        XCTAssertNotNil(store.error)
        store.update(for: validOwner) { $0.homeSessionID = .init(rawValue: "safe-home") }
        XCTAssertEqual(store.classification(for: validOwner).homeSessionID?.rawValue, "safe-home")
        store.update(for: corruptOwner) { $0.homeSessionID = .init(rawValue: "replacement") }
        XCTAssertEqual(defaults.data(forKey: key), Data("not valid JSON".utf8), "Unreadable data must not be overwritten")
    }
}
