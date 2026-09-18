import Foundation
import XCTest
import HermesProtocol
import HermesTransport
@testable import HermesCore

private actor ActivityFixture {
    private(set) var reads: [GatewayReadEndpoint] = []
    private(set) var calls: [(String, JSONValue)] = []
    let scheduleCount: Int
    let failSchedules: Bool
    init(scheduleCount: Int = 1, failSchedules: Bool = false) {
        self.scheduleCount = scheduleCount; self.failSchedules = failSchedules
    }
    func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        calls.append((method, params))
        switch method {
        case "skills.manage": return .object(["skills": .object(["Writing": .array([.string("notes"), .string("notes")])])])
        case "projects.list": return .object(["projects": .array([
            .object(["id": .string("p1"), "name": .string("Work"), "folders": .array([.object(["path": .string("/host/Work")])])]),
            .object(["id": .string("archived"), "archived": .bool(true)])])])
        default: throw MobileActivityError.invalidResponse
        }
    }
    func read(_ endpoint: GatewayReadEndpoint) throws -> JSONValue {
        reads.append(endpoint)
        switch endpoint {
        case .schedules:
            if failSchedules { throw MobileActivityError.unavailable }
            return .array((0..<scheduleCount).map { .object([
                "id": .string("job-\($0)"), "name": .string("Job \($0)"), "schedule_display": .string("Every morning"),
                "last_run_at": .string("2026-09-17T09:00:00Z")]) })
        case .scheduleRuns(let id, _):
            return .object(["runs": .array((0..<20).map { .object([
                "id": .string("\(id)-run-\($0)"), "profile": .string($0 == 0 ? "other-profile" : "work"),
                "title": .string("Run \($0)"), "started_at": .number(1_800_000_000 + Double($0)),
                "preview": .string("This is a first user prompt, not a result")]) })])
        case .sessionMessages(_, _):
            return .object(["profile": .string("work"), "messages": .array([
                .object(["role": .string("user"), "content": .string("Do the task")]),
                .object(["role": .string("assistant"), "content": .string("Finished the actual task")]),
                .object(["role": .string("assistant"), "display_kind": .string("hidden"), "content": .string("Do not show hidden scaffold")])])])
        }
    }
}

final class MobileActivityTests: XCTestCase, @unchecked Sendable {
    private func service(_ fixture: ActivityFixture) -> MobileActivityService {
        MobileActivityService(request: { try await fixture.request($0, $1) }, read: { try await fixture.read($0) })
    }

    func testUsesActualAssistantOutputAndExplicitProfile() async throws {
        let fixture = ActivityFixture()
        let snapshot = try await service(fixture).load(profile: "work")
        XCTAssertEqual(snapshot.schedules.first?.schedule, "Every morning")
        XCTAssertNotNil(snapshot.schedules.first?.lastRunAt)
        XCTAssertEqual(snapshot.skills.map(\.name), ["notes"])
        XCTAssertEqual(snapshot.projects.map(\.id), ["p1"])
        XCTAssertEqual(snapshot.projects.first?.folders, ["/host/Work"])
        XCTAssertEqual(snapshot.runs.count, 4, "The wrong-profile row must not be displayed")
        XCTAssertTrue(snapshot.runs.allSatisfy { $0.summary == "Finished the actual task" })
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.0), ["skills.manage", "projects.list"])
        XCTAssertTrue(calls.allSatisfy { $0.1["profile"] == .string("work") })
        XCTAssertTrue(snapshot.notices.isEmpty)
    }

    func testBoundsRequestsAndRetentionWhenHostIgnoresPageLimit() async throws {
        let fixture = ActivityFixture(scheduleCount: 300)
        let snapshot = try await service(fixture).load(profile: "work")
        let reads = await fixture.reads
        XCTAssertEqual(snapshot.schedules.count, 200)
        XCTAssertEqual(snapshot.runs.count, MobileActivityService.maximumRuns)
        XCTAssertEqual(reads.count, 1 + MobileActivityService.maximumSchedules + MobileActivityService.maximumSummaries)
        XCTAssertEqual(snapshot.runs.filter { !$0.summary.isEmpty }.count, MobileActivityService.maximumSummaries)
        XCTAssertFalse(snapshot.notices.isEmpty)
    }

    func testPartialFailureKeepsWorkingDomainsAndReportsFailure() async throws {
        let fixture = ActivityFixture(failSchedules: true)
        let snapshot = try await service(fixture).load(profile: "work")
        XCTAssertTrue(snapshot.runs.isEmpty)
        XCTAssertEqual(snapshot.skills.map(\.name), ["notes"])
        XCTAssertEqual(snapshot.notices, ["Schedules could not be loaded. Pull to refresh."])
    }

    func testMalformedDatesStayUnknown() throws {
        let schedule = try XCTUnwrap(MobileSchedule(json: .object(["id": .string("job"), "last_run_at": .number(-1),
            "next_run_at": .string("not a date") ])))
        XCTAssertNil(schedule.lastRunAt); XCTAssertNil(schedule.nextRunAt)
    }

    func testForeignProfileSchedulesAndMismatchedTranscriptAreNotShown() async throws {
        let service = MobileActivityService(request: { method, _ in
            method == "skills.manage" ? .object(["skills": .object([:])]) : .object(["projects": .array([])])
        }, read: { resource in
            switch resource {
            case .schedules: return .array([
                .object(["id": .string("foreign"), "profile": .string("personal")]),
                .object(["id": .string("work-job"), "profile": .string("work")])])
            case .scheduleRuns(let id, _):
                XCTAssertEqual(id, "work-job")
                return .object(["runs": .array([.object(["id": .string("work-run")])])])
            case .sessionMessages:
                return .object(["profile": .string("work"), "session_id": .string("another-session"),
                    "messages": .array([.object(["role": .string("assistant"), "content": .string("Other conversation")])])])
            }
        })
        let snapshot = try await service.load(profile: "work")
        XCTAssertEqual(snapshot.schedules.map(\.id), ["work-job"])
        XCTAssertEqual(snapshot.runs.map(\.summary), [""])
        XCTAssertEqual(snapshot.notices, ["Some run summaries are unavailable; open the conversation to read its history."])
    }

    func testSummaryUsesDisplayProjectionAndNeverRawCompactionCarrier() async throws {
        let service = MobileActivityService(request: { method, _ in
            method == "skills.manage" ? .object(["skills": .object([:])]) : .object(["projects": .array([])])
        }, read: { resource in
            switch resource {
            case .schedules: return .array([.object(["id": .string("job")])])
            case .scheduleRuns: return .object(["runs": .array([.object(["id": .string("run")])])])
            case .sessionMessages:
                return .object(["profile": .string("work"), "session_id": .string("run"), "messages": .array([
                    .object(["role": .string("assistant"), "content": .string("Earlier actual output")]),
                    .object(["role": .string("assistant"), "content": .string("Raw model-facing compaction carrier"),
                             "display_content": .string("User-visible recovered result")]),
                    .object(["role": .string("assistant"), "content": .string("Must remain hidden"), "display_content": .string("")]),
                    .object(["role": .string("assistant"), "content": .string("Must also remain hidden"), "display_content": .null])])])
            }
        })
        let snapshot = try await service.load(profile: "work")
        XCTAssertEqual(snapshot.runs.first?.summary, "User-visible recovered result")
    }
}
