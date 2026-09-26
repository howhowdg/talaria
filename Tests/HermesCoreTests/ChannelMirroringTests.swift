import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore

final class ChannelMirroringTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testSourcesAndSessionPagingKeepRawOffsetCount() throws {
        XCTAssertEqual(ChannelSource.known.count, 20)
        for source in [nil, "", "native", "cron", "tool", "bot_room"] as [String?] { XCTAssertFalse(ChannelSource.isChannel(source)) }
        XCTAssertTrue(ChannelSource.isChannel("future_adapter"))
        XCTAssertEqual(ChannelSource.label("api_server"), "API")
        let response = try json(#"{"sessions":[{"id":"a","profile":"default","source":"telegram"},{"id":"a","source":"telegram"},{"id":"b","source":"native"}],"total":8}"#)
        let page = try ChannelSessionPage(response: response, profile: "default", source: "telegram")
        XCTAssertEqual(page.sessions.map(\.id.rawValue), ["a"])
        XCTAssertEqual(page.rawCount, 3)
        XCTAssertTrue(page.hasMore(offset: 0, limit: 3))
        XCTAssertFalse(page.hasMore(offset: 6, limit: 3))
        XCTAssertFalse(page.hasMore(offset: 0, limit: 4))
        let pins = try ChannelSessionPage(response: json(#"{"sessions":[{"id":"a","source":"telegram"},{"id":"pin","source":"telegram"}],"total":2}"#), profile: "default", source: "telegram")
        XCTAssertTrue(pins.hasMore(offset: 0, limit: 1))
    }

    func testRejectsWrongOwnerCorruptionAndMalformedSessionPages() throws {
        for value in [#"{"sessions":[{"id":"a","profile":"work"}]}"#, #"{"sessions":[],"storage":{"default":"corrupt"}}"#, #"{"sessions":[],"errors":[{"profile":"default","error":"unavailable"}]}"#, #"{"sessions":[{"id":""}]}"#, #"{"sessions":[],"total":-1}"#, #"{}"#] {
            XCTAssertThrowsError(try ChannelSessionPage(response: json(value), profile: "default", source: nil))
        }
    }

    func testHistoryUsesStableIDsAcrossPagesAndHonorsDisplayProjection() throws {
        let response = try json(#"{"session_id":"new","profile":"default","pagination":{"offset":0,"limit":4,"returned":4},"messages":[{"id":1,"session_id":"old","role":"user","content":[{"type":"text","text":"Hello"}]},{"id":2,"session_id":"old","role":"assistant","content":"secret","display_content":"","reasoning_content":"Thinking","tool_calls":[{"function":{"name":"lookup","arguments":"{}"}}]},{"id":3,"session_id":"new","role":"tool","tool_name":"lookup","content":"Found"},{"id":4,"role":"assistant","display_kind":"hidden","content":"hidden"}]}"#)
        let page = try ChannelMessagePage(response: response, profile: "default", requestedID: .init(rawValue: "old"))
        XCTAssertEqual(page.resolvedID.rawValue, "new")
        XCTAssertEqual(page.returned, 4)
        XCTAssertEqual(page.messages.count, 4)
        XCTAssertEqual(page.messages[0].text, "Hello")
        XCTAssertEqual(page.messages[1].text, "")
        XCTAssertEqual(page.messages[1].reasoning, "Thinking")
        XCTAssertEqual(page.messages[2].toolName, "lookup")
        XCTAssertEqual(page.messages[3].toolSummary, "Found")
        let older = try json(#"{"session_id":"new","pagination":{"offset":20,"limit":20,"returned":1},"messages":[{"id":1,"session_id":"old","role":"user","content":"Hello"}]}"#)
        let olderPage = try ChannelMessagePage(response: older, profile: "default", requestedID: .init(rawValue: "new"))
        XCTAssertEqual(page.messages[0].id, olderPage.messages[0].id)
    }

    func testHistoryRejectsMissingIdentityAndInvalidPagination() throws {
        for value in [
            #"{"session_id":"a","pagination":{"offset":0,"limit":1,"returned":1},"messages":[{"role":"user","content":"x"}]}"#,
            #"{"session_id":"a","pagination":{"offset":-1,"limit":1,"returned":0},"messages":[]}"#,
            #"{"session_id":"a","profile":"work","pagination":{"offset":0,"limit":1,"returned":0},"messages":[]}"#,
            #"{"session_id":"a","pagination":{"offset":0,"limit":1,"returned":1},"messages":[]}"#,
            #"{"session_id":"a","pagination":{"offset":0,"limit":2,"returned":2},"messages":[{"id":1},{"id":1}]}"#
        ] { XCTAssertThrowsError(try ChannelMessagePage(response: json(value), profile: "default", requestedID: .init(rawValue: "a"))) }
    }
}
