import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore

final class SessionSummaryTests: XCTestCase {
    func testReadsFractionalUnixSecondsFromTheSessionListRow() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"stored","title":"Project","preview":"First question","message_count":4,"started_at":1767225600.25}"#.utf8))
        let summary = SessionSummary(json: json)

        XCTAssertEqual(summary.id.rawValue, "stored")
        XCTAssertEqual(summary.title, "Project")
        XCTAssertEqual(summary.preview, "First question")
        XCTAssertEqual(summary.messageCount, 4)
        XCTAssertEqual(try XCTUnwrap(summary.startedAt).timeIntervalSince1970, 1_767_225_600.25, accuracy: 0.000_001)
    }

    func testAbsentUnknownAndMalformedStartDatesRemainUnknown() {
        XCTAssertNil(SessionSummary(json: .object([:])).startedAt)
        let invalid: [JSONValue] = [
            .null, .bool(true), .string("1767225600"), .string("2026-01-01T00:00:00Z"),
            .array([]), .object([:]), .number(0), .number(-1),
            .number(.nan), .number(.infinity), .number(-.infinity)
        ]
        for value in invalid {
            XCTAssertNil(SessionSummary(json: .object(["started_at": value])).startedAt)
        }
    }

    func testDoesNotGuessMillisecondsOrUseUnspecifiedTimestampFields() {
        let milliseconds = JSONValue.number(1_767_225_600_000)
        XCTAssertNil(SessionSummary(json: .object(["started_at": milliseconds])).startedAt)
        XCTAssertNil(SessionSummary(json: .object([
            "created_at": .number(1_767_225_600),
            "updated_at": .number(1_767_312_000),
            "last_active": .number(1_767_312_000)
        ])).startedAt)
    }

    func testStartDateRemainsAnAbsoluteInstantForLocalCalendarGrouping() throws {
        let summary = SessionSummary(json: .object(["started_at": .number(1_767_225_600)]))
        let date = try XCTUnwrap(summary.startedAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let utcDay = utc.dateComponents([.year, .month, .day], from: date)
        let localDay = losAngeles.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(utcDay, DateComponents(year: 2026, month: 1, day: 1))
        XCTAssertEqual(localDay, DateComponents(year: 2025, month: 12, day: 31))
    }
}
