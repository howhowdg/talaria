import XCTest
@testable import HermesTransport
import HermesProtocol

final class LegacyGatewayRequestsTests: XCTestCase {
    private func event(_ kind: String, session: String = "session-a", id: String = "question-a",
                       fields: [String: JSONValue] = [:]) -> GatewayEvent {
        var payload = fields
        payload["request_id"] = .string(id)
        return GatewayEvent(type: kind + ".request", sessionID: session, payload: .object(payload))
    }

    private func request(_ updates: [GatewayUpdate], file: StaticString = #filePath, line: UInt = #line) throws -> GatewayServerRequest {
        guard case .request(let value) = try XCTUnwrap(updates.first, file: file, line: line) else {
            XCTFail("Expected a request", file: file, line: line)
            throw LegacyGatewayRequestError.malformedPrompt
        }
        return value
    }

    func testApprovalMapsExactSessionAndRequestWithoutGrantingOtherQueuedWork() throws {
        var adapter = LegacyGatewayRequests()
        let input = try request(adapter.receive(event: event("approval", fields: [
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")]),
            "command": .string("remove synthetic fixture")
        ])))
        XCTAssertEqual(input.method, "approval")
        let reply = try XCTUnwrap(adapter.response(to: input.id, result: .object(["choice": .string("once")])))
        XCTAssertEqual(reply.method, "approval.respond")
        XCTAssertEqual(reply.params, .object(["session_id": .string("session-a"),
                                             "request_id": .string("question-a"),
                                             "choice": .string("once"), "all": .bool(false)]))
        XCTAssertEqual(adapter.acknowledgement(for: input.id)?.method, "approval.received")
        let other = try request(adapter.receive(event: event("approval", session: "session-b")))
        XCTAssertNotEqual(input.id, other.id)
        XCTAssertEqual(try request(adapter.receive(event: event("approval"))).id, input.id)
    }

    func testApprovalScopeFlagsAndInvalidAnswersFailClosed() throws {
        var adapter = LegacyGatewayRequests()
        let restricted = try request(adapter.receive(event: event("approval", fields: [
            "allow_permanent": .bool(false)
        ])))
        XCTAssertEqual(restricted.params["choices"], .array([.string("once"), .string("session"), .string("deny")]))
        XCTAssertThrowsError(try adapter.response(to: restricted.id, result: .object(["choice": .string("always")])))
        let smart = try request(adapter.receive(event: event("approval", id: "smart", fields: [
            "smart_denied": .bool(true), "allow_permanent": .bool(true),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")])
        ])))
        XCTAssertEqual(smart.params["choices"], .array([.string("once"), .string("deny")]))
        XCTAssertThrowsError(try adapter.response(to: smart.id, result: .object(["choice": .string("session")])))
        XCTAssertEqual(adapter.rejection(to: smart.id)?.params["choice"], .string("deny"))
    }

    func testCredentialRepliesUseLegacyFieldsWithoutAddingValuesToPromptState() throws {
        var adapter = LegacyGatewayRequests()
        let sudo = try request(adapter.receive(event: event("sudo")))
        let secret = try request(adapter.receive(event: event("secret", fields: ["env_var": .string("FIXTURE_KEY")])))
        XCTAssertNotEqual(sudo.id, secret.id)
        let sudoReply = try XCTUnwrap(adapter.response(to: sudo.id, result: .object(["value": .string("synthetic-value")])))
        XCTAssertEqual(sudoReply.method, "sudo.respond")
        XCTAssertEqual(sudoReply.params["password"], .string("synthetic-value"))
        XCTAssertNil(sudoReply.params["value"])
        XCTAssertNil(sudo.params["password"])
        let secretReply = try XCTUnwrap(adapter.response(to: secret.id, result: .object(["value": .string("synthetic-value")])))
        XCTAssertEqual(secretReply.method, "secret.respond")
        XCTAssertEqual(secretReply.params["value"], .string("synthetic-value"))
        XCTAssertNil(secret.params["value"])
        XCTAssertEqual(adapter.rejection(to: sudo.id)?.params["password"], .string(""))
        XCTAssertNil(adapter.acknowledgement(for: secret.id))
    }

    func testClarificationBatchUsesLegacyJSONAnswerAndEmptyCancellation() throws {
        var adapter = LegacyGatewayRequests()
        let input = try request(adapter.receive(event: event("clarify", fields: [
            "questions": .array([.object(["qid": .string("first"), "question": .string("First?")]),
                                 .object(["qid": .string("second"), "question": .string("Second?")])])
        ])))
        let answer: JSONValue = .object(["answers": .object(["first": .string("A"), "second": .string("B")])])
        let reply = try XCTUnwrap(adapter.response(to: input.id, result: answer))
        let encoded = try XCTUnwrap(reply.params["answer"]?.stringValue)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)), answer)
        XCTAssertEqual(adapter.rejection(to: input.id)?.params["answer"], .string(""))
        XCTAssertThrowsError(try adapter.response(to: input.id, result: .object(["answers": .object(["unknown": .string("A")])])))
    }

    func testSnapshotReplaysKnownQuestionsAndExplicitlyRejectsUnrestorableWaitingInput() throws {
        var adapter = LegacyGatewayRequests()
        let snapshot: JSONValue = .object(["session_id": .string("session-a"), "status": .string("waiting"),
                                          "pending_clarify": .object(["request_id": .string("question-a"), "question": .string("Choose?")])])
        let input = try request(adapter.replay(snapshot: snapshot))
        XCTAssertEqual(input.method, "clarify")
        XCTAssertEqual(try adapter.response(to: input.id, result: .object(["answer": .string("fixture")]))?.params["answer"], .string("fixture"))
        var fresh = LegacyGatewayRequests()
        XCTAssertThrowsError(try fresh.replay(snapshot: .object(["session_id": .string("session-a"), "status": .string("waiting")]))) { error in
            XCTAssertEqual(error as? LegacyGatewayRequestError, .pendingPromptCannotBeRestored)
        }
        _ = try fresh.receive(event: event("sudo"))
        XCTAssertTrue(try fresh.replay(snapshot: .object(["session_id": .string("session-a"), "status": .string("waiting")])).isEmpty)
    }

    func testSettledAndExpiredRequestsCannotBeResurrectedByStaleEventsOrReads() throws {
        var adapter = LegacyGatewayRequests()
        let input = try request(adapter.receive(event: event("approval")))
        adapter.settle(input.id)
        XCTAssertNil(try adapter.response(to: input.id, result: .object(["choice": .string("once")])))
        XCTAssertTrue(try adapter.receive(event: event("approval")).isEmpty)
        let stale: JSONValue = .object(["approvals": .array([.object(["request_id": .string("question-a")])])])
        XCTAssertTrue(try adapter.replayApprovals(sessionID: "session-a", result: stale).isEmpty)
        _ = try adapter.receive(event: GatewayEvent(type: "secret.expire", sessionID: "session-a", payload: .object(["request_id": .string("unseen")])))
        XCTAssertTrue(try adapter.receive(event: event("secret", id: "unseen")).isEmpty)
        let active = try request(adapter.receive(event: event("sudo", id: "active")))
        let cancelled = try adapter.receive(event: GatewayEvent(type: "sudo.expire", sessionID: "session-a", payload: .object(["request_id": .string("active")])))
        guard case .event(let cancellation) = try XCTUnwrap(cancelled.first) else { return XCTFail("Expected cancellation") }
        XCTAssertEqual(cancellation.type, "request.cancel")
        XCTAssertNil(try adapter.response(to: active.id, result: .object(["value": .string("")])))
    }

    func testApprovalQueueReplayPreservesDistinctRequestsAndCompletionClearsOnlyItsSession() throws {
        var adapter = LegacyGatewayRequests()
        let result: JSONValue = .object(["approvals": .array([
            .object(["request_id": .string("first"), "allow_permanent": .bool(true)]),
            .object(["request_id": .string("second"), "allow_permanent": .bool(false)])
        ])])
        let updates = try adapter.replayApprovals(sessionID: "session-a", result: result)
        XCTAssertEqual(updates.count, 2)
        let other = try request(adapter.receive(event: event("sudo", session: "session-b")))
        XCTAssertEqual(try adapter.receive(event: GatewayEvent(type: "message.complete", sessionID: "session-a")).count, 2)
        XCTAssertNotNil(try adapter.response(to: other.id, result: .object(["value": .string("")])))
        XCTAssertTrue(try adapter.replayApprovals(sessionID: "session-a", result: result).isEmpty)
        XCTAssertEqual(LegacyGatewayRequests.approvalsQuery(sessionID: "session-a").params, .object(["session_id": .string("session-a")]))
    }

    func testReplyAcknowledgementsDistinguishSettlementFromAmbiguity() throws {
        var adapter = LegacyGatewayRequests()
        let approval = try request(adapter.receive(event: event("approval")))
        let reply = try XCTUnwrap(adapter.response(to: approval.id, result: .object(["choice": .string("once")])))
        XCTAssertNoThrow(try adapter.validateReply(result: .object(["resolved": .number(0)]), for: reply))
        XCTAssertNoThrow(try adapter.validateReply(result: .object(["resolved": .number(1)]), for: reply))
        XCTAssertThrowsError(try adapter.validateReply(result: .object(["resolved": .bool(true)]), for: reply))
        let sudo = try request(adapter.receive(event: event("sudo")))
        let sudoReply = try XCTUnwrap(adapter.response(to: sudo.id, result: .object(["value": .string("")])))
        for status in ["ok", "expired"] {
            XCTAssertNoThrow(try adapter.validateReply(result: .object(["status": .string(status)]), for: sudoReply))
        }
        XCTAssertThrowsError(try adapter.validateReply(result: .object([:]), for: sudoReply))
    }

    func testMalformedPromptAndUnboundedQueuesAreRejected() throws {
        var adapter = LegacyGatewayRequests()
        XCTAssertThrowsError(try adapter.receive(event: GatewayEvent(type: "approval.request", sessionID: "session-a")))
        XCTAssertThrowsError(try adapter.receive(event: GatewayEvent(type: "secret.request", payload: .object(["request_id": .string("id")]))))
        let oversized: JSONValue = .object(["approvals": .array((0..<257).map { .object(["request_id": .string("fixture-\($0)")]) })])
        XCTAssertThrowsError(try adapter.replayApprovals(sessionID: "session-a", result: oversized))
        XCTAssertTrue(try adapter.receive(event: GatewayEvent(type: "some.unsupported.event")).isEmpty)
    }
}
