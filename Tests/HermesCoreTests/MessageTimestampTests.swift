import Foundation
import XCTest
import HermesProtocol
@testable import HermesCore

final class MessageTimestampTests: XCTestCase {
    private let owner = SessionOwner(connectionID: UUID(), profile: "test")

    private func snapshot(timestamp: JSONValue? = nil) throws -> ConversationState {
        var message: [String: JSONValue] = ["role": .string("user"), "text": .string("Hello")]
        if let timestamp { message["timestamp"] = timestamp }
        return try ConversationState(snapshot: .object([
            "session_id": .string("runtime"), "stored_session_id": .string("stored"),
            "messages": .array([.object(message)])
        ]), owner: owner)
    }

    func testHydrationPreservesAuthoritativeUnixSeconds() throws {
        let seconds = 1_789_747_320.25
        let message = try XCTUnwrap(snapshot(timestamp: .number(seconds)).messages.first)
        XCTAssertEqual(message.timestamp, Date(timeIntervalSince1970: seconds))
    }

    func testMissingNullAndMalformedTimestampsRemainUnknown() throws {
        let invalid: [JSONValue?] = [
            nil, .null, .string("1789747320"), .bool(true), .array([]), .object([:]),
            .number(0), .number(-1), .number(.infinity), .number(-.infinity), .number(.nan),
            .number(253_402_300_800), .number(1_789_747_320_000)
        ]
        for value in invalid {
            XCTAssertNil(try snapshot(timestamp: value).messages.first?.timestamp)
        }
    }

    func testOldCachedMessageDecodesWithoutTimestamp() throws {
        let oldCache = Data("""
        {"id":"cached-user","role":"user","text":"Saved message","reasoning":"","isStreaming":false,"isError":false}
        """.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: oldCache)
        XCTAssertEqual(message.id, "cached-user")
        XCTAssertEqual(message.text, "Saved message")
        XCTAssertNil(message.timestamp)
    }

    func testTimestampSurvivesCachedMessageRoundTrip() throws {
        let original = try XCTUnwrap(snapshot(timestamp: .number(1_789_747_320.25)).messages.first)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }

    func testLiveMessagesDoNotInventTimestamps() throws {
        var state = try snapshot()
        state.beginSubmission(text: "A new question")
        state.apply(.init(type: "message.delta", sessionID: "runtime", payload: .object(["text": .string("Reply")])))
        XCTAssertEqual(state.messages.map(\.text), ["Hello", "A new question", "Reply"])
        XCTAssertTrue(state.messages.allSatisfy { $0.timestamp == nil })
    }
}
