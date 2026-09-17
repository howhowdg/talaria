import Foundation
import XCTest
@testable import HermesProtocol

final class ProtocolTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testJSONStructurePreservesNullBooleanAndUnknownFields() throws {
        let input = #"{"null":null,"boolean":true,"count":42,"fraction":1.5,"nested":{"future":["a",false,null]}}"#
        let value = try decode(JSONValue.self, input)
        XCTAssertEqual(value["null"], .null)
        XCTAssertEqual(value["boolean"], .bool(true))
        XCTAssertNil(value["boolean"]?.intValue)
        XCTAssertEqual(value["count"]?.intValue, 42)
        XCTAssertNil(value["fraction"]?.intValue)
        XCTAssertEqual(value["nested"]?["future"]?.arrayValue, [.string("a"), .bool(false), .null])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(Double(Int.max)).intValue)
    }

    func testRPCIDsKeepStringAndIntegerIdentity() throws {
        XCTAssertEqual(try decode(RPCID.self, #""request-7""#), .string("request-7"))
        XCTAssertEqual(try decode(RPCID.self, "7"), .number(7))
        XCTAssertNotEqual(try decode(RPCID.self, #""7""#), .number(7))
        XCTAssertEqual(try decode(RPCID.self, "9007199254740993"), .number(9_007_199_254_740_993))
        XCTAssertThrowsError(try decode(RPCID.self, "null"))
        XCTAssertThrowsError(try decode(RPCID.self, "true"))
        XCTAssertThrowsError(try decode(RPCID.self, "1.5"))
        for id in [RPCID.number(-4), .string("approval:session:3")] {
            XCTAssertEqual(try JSONDecoder().decode(RPCID.self, from: JSONEncoder().encode(id)), id)
        }
    }

    func testEventEnvelopeKeepsPayloadNested() throws {
        let frame = try decode(JSONValue.self, #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"live-1","seq":12,"payload":{"text":"Hello","future":{"count":1}},"text":"wrong"}}"#)
        let event = try GatewayEvent(params: XCTUnwrap(frame["params"]))
        XCTAssertEqual(event.type, "message.delta")
        XCTAssertEqual(event.sessionID, "live-1")
        XCTAssertEqual(event.sequence, 12)
        XCTAssertEqual(event.payload["text"], .string("Hello"))
        XCTAssertEqual(event.payload["future"]?["count"], .number(1))
        let roundTrip = try JSONValue.from(event)
        XCTAssertEqual(roundTrip["session_id"], .string("live-1"))
        XCTAssertEqual(roundTrip["seq"], .number(12))
        XCTAssertNil(roundTrip["text"])
        XCTAssertEqual(try roundTrip.decode(GatewayEvent.self), event)
    }

    func testUnknownAndPayloadlessEventsRemainUsable() throws {
        let started = try decode(GatewayEvent.self, #"{"type":"message.start","session_id":"s"}"#)
        XCTAssertEqual(started.payload, .object([:]))
        XCTAssertNil(started.sequence)
        let future = try decode(GatewayEvent.self, #"{"type":"future.new_feature","payload":null}"#)
        XCTAssertEqual(future.type, "future.new_feature")
        XCTAssertEqual(future.payload, .null)
        XCTAssertNil(future.sessionID)
        for malformed in [#"{"type":""}"#, #"{"payload":{}}"#, #"{"type":"message.delta","seq":1.5}"#,
                          #"{"type":"message.delta","session_id":false}"#, "[]"] {
            XCTAssertThrowsError(try decode(GatewayEvent.self, malformed))
        }
    }

    func testReadyAndReplayFixturesExposeRecoveryMetadata() throws {
        let ready = try decode(GatewayEvent.self, #"{"type":"gateway.ready","payload":{"skin":{},"change_events":true,"heartbeat":true,"replay_epoch":"epoch-b"}}"#)
        let payload = try ready.payload.decode(GatewayReadyPayload.self)
        XCTAssertEqual(payload.replayEpoch, "epoch-b")
        XCTAssertEqual(payload.heartbeat, .value(true))

        let replay = try decode(SessionEventsSinceResult.self, #"{"events":[{"type":"message.delta","session_id":"s","seq":3,"payload":{"text":"replayed"}}],"latest_seq":3,"truncated":true,"count":1,"epoch":"epoch-b","open_requests":[{"id":"server-8","method":"approval","params":{"session_id":"s","command":"example"}}]}"#)
        XCTAssertTrue(replay.truncated)
        XCTAssertEqual(replay.latestSeq, 3)
        XCTAssertEqual(try GatewayEvent(params: replay.events[0]).payload["text"], .string("replayed"))
        let request = try replay.openRequests[0].decode(GatewayServerRequest.self)
        XCTAssertEqual(request.id, .string("server-8"))
        XCTAssertEqual(request.method, "approval")
        XCTAssertEqual(request.params["session_id"], .string("s"))
    }

    func testOptionalRequestFieldsPreserveOmittedNullAndValue() throws {
        let omitted = try decode(SessionCreateParams.self, #"{"source":"desktop"}"#)
        XCTAssertEqual(omitted.profile, .absent)
        XCTAssertEqual(omitted.source, .value("desktop"))
        XCTAssertEqual(try JSONValue.from(omitted), .object(["source": .string("desktop")]))
        var explicitNull = omitted
        explicitNull.profile = .null
        explicitNull.closeOnDisconnect = false
        let encoded = try JSONValue.from(explicitNull)
        XCTAssertEqual(encoded["profile"], .null)
        XCTAssertEqual(encoded["close_on_disconnect"], .bool(false))
        XCTAssertNil(encoded["cwd"])
        XCTAssertEqual(try encoded.decode(SessionCreateParams.self), explicitNull)
        XCTAssertThrowsError(try decode(SessionCreateParams.self, #"{"close_on_disconnect":null}"#))
    }

    func testPromptSubmitDoesNotInventDefaultsOrRejectNewStatus() throws {
        let request = PromptSubmitParams(sessionID: "runtime", text: .array([.object(["text": .string("Hello")])]))
        let encoded = try JSONValue.from(request)
        XCTAssertEqual(encoded["session_id"], .string("runtime"))
        XCTAssertEqual(encoded.objectValue?.count, 2)
        XCTAssertNil(encoded["profile"])
        XCTAssertNil(encoded["queued"])
        let result = try decode(PromptSubmitResult.self, #"{"status":"new_future_status","survivor_user_row_ids":[7,null,9],"survivor_row_id_map":{"old":null}}"#)
        XCTAssertEqual(result.status, .value("new_future_status"))
        XCTAssertEqual(result.survivorUserRowIDs, .value([7, nil, 9]))
        XCTAssertEqual(try JSONValue.from(result)["survivor_row_id_map"]?["old"], .null)
        XCTAssertThrowsError(try decode(PromptSubmitParams.self, #"{"text":"no session"}"#))
    }

    func testErrorDataPreservesNullAndDetails() throws {
        let absent = try decode(JSONRPCError.self, #"{"code":4000,"message":"Invalid parameters"}"#)
        XCTAssertNil(absent.data)
        XCTAssertNil(try JSONValue.from(absent)["data"])
        let explicitNull = try decode(JSONRPCError.self, #"{"code":4000,"message":"Invalid parameters","data":null}"#)
        XCTAssertEqual(explicitNull.data, .null)
        XCTAssertEqual(try JSONValue.from(explicitNull)["data"], .null)
        XCTAssertEqual(explicitNull.localizedDescription, "Invalid parameters")
    }

    func testGeneratedCatalogMatchesPinnedSurface() {
        XCTAssertEqual(GatewayContract.upstreamCommit, "a566d20d226a8e2ef0747639dc8a3fc1c43f9dba")
        XCTAssertEqual(GatewayMethod.allCases.count, 218)
        XCTAssertEqual(GatewayServerRequestMethod.allCases.count, 12)
        XCTAssertEqual(GatewayEventType.allCases.count, 69)
        XCTAssertEqual(GatewayMethod.sessionEventsSince.payloadSchema, "SessionEventsSinceParams")
        XCTAssertEqual(GatewayMethod.promptSubmit.resultSchema, "PromptSubmitResult")
        XCTAssertEqual(GatewayServerRequestMethod.approval.resultSchema, "ApprovalResult")
        XCTAssertEqual(GatewayEventType.messageDelta.payloadSchema, "StreamDeltaPayload")
    }
}
