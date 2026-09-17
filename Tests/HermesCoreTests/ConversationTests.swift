import XCTest
import HermesProtocol
@testable import HermesCore

final class ConversationTests: XCTestCase {
    let owner = SessionOwner(connectionID: UUID(), profile: "work")
    func state() throws -> ConversationState {
        try ConversationState(snapshot: .object([
            "session_id": .string("runtime"), "stored_session_id": .string("stored"),
            "messages": .array([]), "info": .object(["title": .string("Test")])
        ]), owner: owner)
    }
    func testRuntimeAndStoredIdentityRemainDistinct() throws {
        let state = try state()
        XCTAssertEqual(state.runtimeID.rawValue, "runtime")
        XCTAssertEqual(state.storedID.rawValue, "stored")
        XCTAssertEqual(state.owner.profile, "work")
    }
    func testUnsentSubmissionRemovesOnlyItsOptimisticRow() throws {
        var state = try state()
        state.messages = [ChatMessage(role: .user, text: "Previously sent")]
        let pendingID = state.beginSubmission(text: "Image could not attach")
        state.cancelUnsentSubmission(pendingID)
        XCTAssertEqual(state.messages.map(\.text), ["Previously sent"])
        XCTAssertFalse(state.isRunning)
    }
    func testForeignSessionAndDuplicateSequenceCannotPolluteTranscript() throws {
        var state = try state()
        state.apply(.init(type: "message.delta", sessionID: "foreign", sequence: 1, payload: .object(["text": .string("wrong")])))
        let event = GatewayEvent(type: "message.delta", sessionID: "runtime", sequence: 2, payload: .object(["text": .string("hello")]))
        state.apply(event); state.apply(event)
        XCTAssertEqual(state.messages.map(\.text), ["hello"])
    }
    func testCompletionReplacesStreamingTextWithoutDuplication() throws {
        var state = try state()
        state.beginSubmission(text: "Hello")
        state.apply(.init(type: "message.delta", sessionID: "runtime", payload: .object(["text": .string("Partial")])))
        state.apply(.init(type: "message.complete", sessionID: "runtime", payload: .object(["text": .string("Final"), "status": .string("success")])))
        XCTAssertEqual(state.messages.map(\.text), ["Hello", "Final"])
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.messages.contains(where: \.isStreaming))
    }
    func testToolLifecycleKeepsArgumentsAndOutputTogether() throws {
        var state = try state()
        state.apply(.init(type: "tool.start", sessionID: "runtime", payload: .object([
            "tool_id": .string("t"), "name": .string("terminal"), "args": .object(["command": .string("pwd")])
        ])))
        state.apply(.init(type: "tool.complete", sessionID: "runtime", payload: .object([
            "tool_id": .string("t"), "summary": .string("/tmp/test")
        ])))
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].text, "/tmp/test")
        XCTAssertTrue(state.messages[0].toolInput?.contains("pwd") == true)
        XCTAssertFalse(state.messages[0].isStreaming)
    }
    func testProjectedTranscriptAndInFlightHydration() throws {
        let state = try ConversationState(snapshot: .object([
            "session_id": .string("new-runtime"), "stored_session_id": .string("same-stored"),
            "running": .bool(true), "messages": .array([
                .object(["role": .string("user"), "text": .string("question"), "row_id": .number(1)]),
                .object(["role": .string("system"), "text": .string("hidden"), "display_kind": .string("hidden")])
            ]), "inflight": .object(["user": .string("question"), "assistant": .string("half")])
        ]), owner: owner)
        XCTAssertEqual(state.messages.map(\.text), ["question", "half"])
        XCTAssertTrue(state.messages.last!.isStreaming)
    }
    func testRequestRedeliveryReplacesAndCancellationRemoves() throws {
        var state = try state()
        let request = GatewayServerRequest(id: .string("q"), method: "clarify", params: .object([:]))
        state.receive(request); state.receive(request)
        XCTAssertEqual(state.pendingInputs.count, 1)
        state.apply(.init(type: "request.cancel", sessionID: "runtime", payload: .object(["id": .string("q")])))
        XCTAssertTrue(state.pendingInputs.isEmpty)
    }
    func testInterruptAcknowledgementKeepsTurnLocked() throws {
        var state = try state()
        state.beginSubmission(text: "Work")
        state.markStopping()
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.status, "Stopping…")
        state.apply(.init(type: "message.complete", sessionID: "runtime", payload: .object(["status": .string("interrupted")])))
        XCTAssertFalse(state.isRunning)
    }
    func testWarmSnapshotUsesStoredSessionKey() throws {
        let state = try ConversationState(snapshot: .object([
            "session_id": .string("live"), "session_key": .string("persisted"),
            "info": .object(["stored_session_id": .string("")])
        ]), owner: owner)
        XCTAssertEqual(state.storedID.rawValue, "persisted")
    }
    func testPreviewedFinalSettlesIntoInterimWithoutDuplicate() throws {
        var state = try state()
        state.apply(.init(type: "message.delta", sessionID: "runtime", payload: .object(["text": .string("partial")])))
        state.apply(.init(type: "message.interim", sessionID: "runtime", payload: .object(["text": .string("partial answer")])))
        state.apply(.init(type: "message.complete", sessionID: "runtime", payload: .object([
            "text": .string("partial answer with details"), "response_previewed": .bool(true)
        ])))
        XCTAssertEqual(state.messages.map(\.text), ["partial answer with details"])
    }
    func testHiddenInflightPromptStaysHiddenAndFailedTurnSurvivesReconnect() throws {
        let state = try ConversationState(snapshot: .object([
            "session_id": .string("runtime"), "running": .bool(false), "inflight": .object([
                "user": .string("internal continuation"), "display_kind": .string("hidden"),
                "assistant": .string("partial response"), "error": .string("provider disconnected")
            ])
        ]), owner: owner)
        XCTAssertEqual(state.messages.map(\.text), ["partial response", "provider disconnected"])
        XCTAssertEqual(state.status, "Needs attention")
        XCTAssertFalse(state.messages.contains(where: \.isStreaming))
    }
}
