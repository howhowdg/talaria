import Foundation
import XCTest
import HermesCore
import HermesProtocol
@testable import HermesUI

final class WorkspaceActivityTests: XCTestCase {
    private func todo(_ id: String, _ status: String, content: String? = nil, parent: String? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "content": .string(content ?? "Task \(id)"), "status": .string(status)]
        if let parent { item["parent"] = .string(parent) }
        return .object(item)
    }

    private func result(_ todos: [JSONValue], revision: JSONValue? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["todos": .array(todos)]
        if let revision { value["revision"] = revision }
        return .object(value)
    }

    private func tool(_ value: JSONValue, name: String = "todo_list", role: MessageRole = .tool,
                      streaming: Bool = false, isError: Bool = false, input: String? = nil) throws -> ChatMessage {
        ChatMessage(role: role, text: try json(value), toolName: name, toolInput: input,
                    isStreaming: streaming, isError: isError)
    }

    private func json(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func conversation(messages: [ChatMessage], connection: UUID = UUID(), profile: String = "work",
                              storedID: String = "session-1") throws -> ConversationState {
        var state = try ConversationState(snapshot: .object([
            "session_id": .string("runtime-1"), "stored_session_id": .string(storedID)
        ]), owner: SessionOwner(connectionID: connection, profile: profile))
        state.messages = messages
        return state
    }

    func testTodoCacheDoesNotReparseForAssistantTokensOrUnrelatedToolChanges() throws {
        var state = try conversation(messages: [
            tool(result([todo("plan", "in_progress")], revision: .number(1))),
            ChatMessage(role: .assistant, text: "", isStreaming: true)
        ])
        let initial = WorkspaceTodoInput(state: state)
        var cache = WorkspaceTodoCache(), parses = 0
        let parse: ([String]) -> [ReportedTodo]? = { values in
            parses += 1
            return ActivityPresentation.reportedTodos(in: values)
        }
        cache.update(initial, parse: parse)
        for token in 0..<40 {
            state.messages[1].text += "token \(token) "
            state.messages[0].toolInput = "Arguments changed \(token)"
            state.messages[0].toolSummary = "Updated summary \(token)"
            state.status = "Writing…"
            let input = WorkspaceTodoInput(state: state)
            XCTAssertEqual(input, initial)
            cache.update(input, parse: parse)
        }
        state.messages.append(try tool(.object(["exit_code": .number(0)]), name: "terminal"))
        cache.update(WorkspaceTodoInput(state: state), parse: parse)
        XCTAssertEqual(parses, 1)
        XCTAssertEqual(cache.todos(matching: WorkspaceTodoInput(state: state))?.map(\.id), ["plan"])
    }

    func testTodoCacheInvalidatesForConfirmedCompletionChangedResultAndError() throws {
        var state = try conversation(messages: [
            tool(result([todo("plan", "pending")]), streaming: true)
        ])
        var cache = WorkspaceTodoCache(), parses = 0
        let parse: ([String]) -> [ReportedTodo]? = { values in
            parses += 1
            return ActivityPresentation.reportedTodos(in: values)
        }
        cache.update(WorkspaceTodoInput(state: state), parse: parse)
        XCTAssertNil(cache.todos(matching: WorkspaceTodoInput(state: state)))
        state.messages[0].isStreaming = false
        cache.update(WorkspaceTodoInput(state: state), parse: parse)
        XCTAssertEqual(cache.todos(matching: WorkspaceTodoInput(state: state))?.first?.status, .pending)
        state.messages[0].text = try json(result([todo("plan", "completed")]))
        cache.update(WorkspaceTodoInput(state: state), parse: parse)
        XCTAssertEqual(cache.todos(matching: WorkspaceTodoInput(state: state))?.first?.status, .completed)
        state.messages[0].isError = true
        cache.update(WorkspaceTodoInput(state: state), parse: parse)
        XCTAssertNil(cache.todos(matching: WorkspaceTodoInput(state: state)))
        XCTAssertEqual(parses, 4)
    }

    func testTodoCacheCannotExposePreviousScopeBeforeChangeHandlerRuns() throws {
        let connection = UUID()
        let messages = try [tool(result([todo("private", "pending")]))]
        let original = try conversation(messages: messages, connection: connection)
        let initial = WorkspaceTodoInput(state: original)
        var cache = WorkspaceTodoCache()
        let alternatives: [ConversationState?] = try [
            conversation(messages: messages, connection: UUID()),
            conversation(messages: messages, connection: connection, profile: "personal"),
            conversation(messages: messages, connection: connection, storedID: "session-2"),
            nil
        ]
        for alternative in alternatives {
            cache.update(initial)
            let next = WorkspaceTodoInput(state: alternative)
            XCTAssertNotEqual(next, initial)
            // This is the first-frame read, before SwiftUI invokes onChange.
            XCTAssertNil(cache.todos(matching: next))
            cache.update(next)
            if alternative == nil { XCTAssertNil(cache.todos(matching: next)) }
            else { XCTAssertEqual(cache.todos(matching: next)?.map(\.id), ["private"]) }
            XCTAssertNil(cache.todos(matching: initial))
        }
    }

    func testTodoCacheDoesNotReviveTasksAfterClearOrHistoryReplacement() throws {
        var state = try conversation(messages: [tool(result([todo("old", "pending")], revision: .number(1)))])
        var cache = WorkspaceTodoCache()
        cache.update(WorkspaceTodoInput(state: state))
        state.messages.append(try tool(result([], revision: .number(2))))
        let cleared = WorkspaceTodoInput(state: state)
        XCTAssertNil(cache.todos(matching: cleared))
        cache.update(cleared)
        XCTAssertEqual(cache.todos(matching: cleared), [])
        state.messages = []
        let replaced = WorkspaceTodoInput(state: state)
        cache.update(replaced)
        XCTAssertNil(cache.todos(matching: replaced))
        XCTAssertNil(cache.todos(matching: cleared))
    }

    func testOnlyConfirmedTodoToolResultsBecomeTaskState() throws {
        let snapshot = result([todo("real", "in_progress")])
        let source = try json(snapshot)
        let proposed = ChatMessage(role: .tool, text: "", toolName: "todo_list", toolInput: source)
        let ignored = try [
            tool(snapshot, role: .assistant), tool(snapshot, role: .user),
            tool(snapshot, name: "terminal"), tool(snapshot, streaming: true), tool(snapshot, isError: true)
        ] + [proposed]
        XCTAssertNil(ActivityPresentation.latestTodos(ignored))
        let accepted = try ActivityPresentation.latestTodos(ignored + [tool(snapshot)])
        XCTAssertEqual(accepted?.map(\.id), ["real"])
        XCTAssertEqual(accepted?.first?.status, .inProgress)
    }

    func testFullSnapshotReplacesInsteadOfMergingWithPreviousTasks() throws {
        let first = try tool(result([todo("old", "pending"), todo("kept", "pending")], revision: .number(1)))
        let replacement = try tool(result([todo("kept", "completed")], revision: .number(2)))
        let parsed = ActivityPresentation.latestTodos([first, replacement])
        XCTAssertEqual(parsed?.map(\.id), ["kept"])
        XCTAssertEqual(parsed?.first?.status, .completed)
    }

    func testExplicitClearSurvivesLateOlderRevision() throws {
        let started = try tool(result([todo("work", "in_progress")], revision: .number(2)))
        let cleared = try tool(result([], revision: .number(4)))
        let stale = try tool(result([todo("work", "completed")], revision: .number(3)))
        XCTAssertEqual(ActivityPresentation.latestTodos([started, cleared, stale]), [])
        XCTAssertEqual(ActivityPresentation.latestTodos([started, cleared, stale, cleared]), [])
        // A malformed payload is not a clear and cannot resurrect the old state.
        let malformed = ChatMessage(role: .tool, text: "{not JSON", toolName: "todo_list")
        XCTAssertEqual(ActivityPresentation.latestTodos([started, cleared, malformed]), [])
    }

    func testHigherRevisionWinsRegardlessOfMessagePositionAndMalformedRevisionCannotBypassIt() throws {
        let current = try tool(result([todo("new", "completed")], revision: .number(8)))
        let stale = try tool(result([todo("old", "pending")], revision: .number(7)))
        XCTAssertEqual(ActivityPresentation.latestTodos([current, stale])?.map(\.id), ["new"])
        for revision in [JSONValue.number(-1), .number(8.5), .string("9"), .bool(true), .number(9_007_199_254_740_992)] {
            let invalid = try tool(result([todo("bad", "pending")], revision: revision))
            XCTAssertEqual(ActivityPresentation.latestTodos([current, invalid])?.map(\.id), ["new"])
        }
    }

    func testLegacyToolNameAndUnrevisionedResultsStillWork() throws {
        let first = try tool(.array([todo("a", "pending")]), name: "todo")
        let second = try tool(result([todo("b", "cancelled")]), name: "todo")
        XCTAssertEqual(ActivityPresentation.latestTodos([first, second])?.map(\.id), ["b"])
        let cleared = try tool(result([]), name: "todo")
        XCTAssertEqual(ActivityPresentation.latestTodos([first, second, cleared]), [])
    }

    func testJSONStringResultsAndStringifiedTodosAreDecodedWithinBound() throws {
        let payload = result([todo("nested", "pending")], revision: .number(6))
        let stringified = try tool(.string(json(payload)))
        XCTAssertEqual(ActivityPresentation.latestTodos([stringified])?.map(\.id), ["nested"])
        let wrappedArray = try tool(.object(["todos": .string(json(.array([todo("array", "completed")])))]))
        XCTAssertEqual(ActivityPresentation.latestTodos([wrappedArray])?.map(\.id), ["array"])
        let tooDeep = try tool(.string(json(.string(json(payload)))))
        XCTAssertNil(ActivityPresentation.latestTodos([tooDeep]))
    }

    func testInvalidRowsAreNotInventedAndDuplicateIDsUseLastOccurrence() throws {
        let values: [JSONValue] = [
            todo("duplicate", "pending", content: "Old description"),
            todo("unknown", "future_status"),
            todo("blank", "pending", content: "  \n"),
            todo("", "pending"),
            .null,
            .object(["id": .number(4), "content": .string("Wrong id type"), "status": .string("pending")]),
            todo("other", "cancelled"),
            todo("duplicate", "completed", content: "Confirmed description")
        ]
        let parsed = try ActivityPresentation.latestTodos([tool(result(values))])
        XCTAssertEqual(parsed?.map(\.id), ["other", "duplicate"])
        XCTAssertEqual(parsed?.last?.content, "Confirmed description")
        XCTAssertEqual(parsed?.last?.status, .completed)
        let invalidOnly = try tool(result([todo("bad", "unknown")]))
        XCTAssertNil(ActivityPresentation.latestTodos([invalidOnly]))
    }

    func testOversizedPayloadsAndListsDoNotErasePriorValidatedState() throws {
        let valid = try tool(result([todo("valid", "pending")]))
        let oversizedList = try tool(result((0..<257).map { todo("\($0)", "pending") }))
        let oversizedContent = try tool(result([todo("large", "pending", content: String(repeating: "x", count: 4_001))]))
        let oversizedPayload = try tool(.object([
            "todos": .array([]), "padding": .string(String(repeating: "x", count: 512_001))
        ]))
        for invalid in [oversizedList, oversizedContent, oversizedPayload] {
            XCTAssertNil(ActivityPresentation.latestTodos([invalid]))
            XCTAssertEqual(ActivityPresentation.latestTodos([valid, invalid])?.map(\.id), ["valid"])
        }
        let boundary = try tool(result([todo("boundary", "pending", content: String(repeating: "x", count: 4_000))]))
        XCTAssertEqual(ActivityPresentation.latestTodos([boundary])?.first?.content.count, 4_000)
    }

    func testTaskNestingRejectsCyclesAndMissingParents() {
        let rows = [
            ReportedTodo(id: "root", content: "Root", status: .completed, parent: nil),
            ReportedTodo(id: "child", content: "Child", status: .inProgress, parent: "root"),
            ReportedTodo(id: "grandchild", content: "Grandchild", status: .pending, parent: "child"),
            ReportedTodo(id: "missing", content: "Missing", status: .pending, parent: "unknown"),
            ReportedTodo(id: "cycle-a", content: "A", status: .pending, parent: "cycle-b"),
            ReportedTodo(id: "cycle-b", content: "B", status: .pending, parent: "cycle-a"),
            ReportedTodo(id: "self", content: "Self", status: .pending, parent: "self")
        ]
        XCTAssertEqual(rows.map { ActivityPresentation.depth(of: $0, in: rows) }, [0, 1, 2, 0, 0, 0, 0])
    }

    func testFailureDetectionUsesExplicitResultFieldsInsteadOfProse() throws {
        let failures: [JSONValue] = [
            .object(["error": .string("Permission denied")]), .object(["error": .bool(true)]),
            .object(["is_error": .bool(true)]), .object(["success": .bool(false)]),
            .object(["status": .string("failed")]), .object(["status": .string("error")]),
            .object(["exit_code": .number(1)]), .object(["exit_code": .number(-9)])
        ]
        for value in failures { XCTAssertTrue(try ActivityPresentation.reportsFailure(json(value))) }
        let valid: [JSONValue] = [
            .object(["error": .null]), .object(["error": .bool(false)]), .object(["error": .string("  ")]),
            .object(["success": .bool(true)]), .object(["exit_code": .number(0)]),
            .object(["status": .string("yielded_to_background"), "exit_code": .null]),
            .object(["output": .string("Found the error-handling test")])
        ]
        for value in valid { XCTAssertFalse(try ActivityPresentation.reportsFailure(json(value))) }
        XCTAssertFalse(ActivityPresentation.reportsFailure("error: a word in unstructured output"))
    }

    func testFailedOrPartialTodoResultCannotReplaceConfirmedList() throws {
        let valid = try tool(result([todo("confirmed", "pending")], revision: .number(3)))
        let reportedFailure = try tool(.object([
            "todos": .array([]), "revision": .number(4), "error": .string("Store unavailable")
        ]))
        let streaming = try tool(result([], revision: .number(5)), streaming: true)
        let partialArguments = ChatMessage(role: .tool, text: "", toolName: "todo_list",
            toolInput: #"{"merge":true,"todos":[{"id":"confirmed","status":"completed"}]}"#)
        XCTAssertEqual(ActivityPresentation.latestTodos([valid, reportedFailure, streaming, partialArguments])?.first?.status, .pending)
    }

    func testToolPhaseDistinguishesRunningErrorsAndOutputWithoutClaimingSuccess() throws {
        XCTAssertEqual(ToolPhase(ChatMessage(role: .tool, text: "", isStreaming: true)), .running)
        XCTAssertEqual(ToolPhase(ChatMessage(role: .tool, text: "", isError: true)), .failed)
        XCTAssertEqual(ToolPhase(ChatMessage(role: .tool, text: "")), .idle)
        let returned = ToolPhase(ChatMessage(role: .tool, text: "Reported output"))
        XCTAssertEqual(returned, .result)
        let unsuccessful = try tool(.object(["exit_code": .number(2)]), name: "terminal")
        XCTAssertEqual(ToolPhase(unsuccessful), .failed)
    }

    func testArgumentSummaryChoosesUsefulKnownFieldsAndBoundsLongStringArguments() throws {
        let input = try json(.object(["command": .string("swift\n  test"), "workdir": .string("/host/project")]))
        XCTAssertEqual(ActivityPresentation.argumentPreview(input), "swift test")
        XCTAssertEqual(ActivityPresentation.argumentPreview(#"{"path":"/host/notes.md"}"#), "/host/notes.md")
        XCTAssertNil(ActivityPresentation.argumentPreview("{}"))
        XCTAssertNil(ActivityPresentation.argumentPreview("  \n"))
        let longArgument = try json(.object(["description": .string(String(repeating: "x", count: 1_000))]))
        let summary = try XCTUnwrap(ActivityPresentation.argumentPreview(longArgument))
        XCTAssertLessThanOrEqual(summary.count, 60)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testToolSpecificSummariesPreferConfirmedArgumentFields() throws {
        let cases: [(String, JSONValue, String, Bool)] = [
            ("read_file", .object(["path": .string("/host/notes.md"), "description": .string("Read notes")]), "/host/notes.md", true),
            ("write_file", .object(["content": .string("Full document contents"), "path": .string("report.md")]), "report.md", true),
            ("terminal", .object(["command": .string("swift\n  test"), "workdir": .string("/host/workspace")]), "swift test", true),
            ("web_search", .object(["query": .string("SwiftUI materials"), "limit": .number(4)]), "SwiftUI materials", false)
        ]
        for (name, value, expected, isCode) in cases {
            let summary = try XCTUnwrap(ActivityPresentation.argumentSummary(json(value), toolName: name))
            XCTAssertEqual(summary.text, expected)
            XCTAssertEqual(summary.isCode, isCode)
        }
    }

    func testCollapsedArgumentsNeverShowRawOrNestedJSON() throws {
        for raw in ["{broken JSON", "unstructured raw text", "{}", "[]",
                    #"{"limit":4,"options":{"query":"nested"}}"#,
                    #"{"a":"{\"nested\":true}"}"#] {
            XCTAssertNil(ActivityPresentation.argumentPreview(raw))
        }
        let value = JSONValue.object([
            "a": .number(1), "b": .object(["path": .string("not a top-level string")]),
            "c": .string("Useful description"), "d": .string("Other value")
        ])
        XCTAssertEqual(try ActivityPresentation.argumentPreview(json(value)), "Useful description")
        let long = try json(.object(["query": .string(String(repeating: "🌱", count: 100))]))
        let summary = try XCTUnwrap(ActivityPresentation.argumentSummary(long, toolName: "web_search"))
        XCTAssertLessThanOrEqual(summary.text.count, 60)
        XCTAssertTrue(summary.text.hasSuffix("…"))
    }

    func testTrailingMetadataComesOnlyFromReportedResultFields() throws {
        let cases: [(String, JSONValue, String)] = [
            ("read_file", .object(["total_lines": .number(12)]), "12 lines"),
            ("read_file", .object(["content": .string("one\ntwo")]), ""),
            ("write_file", .object(["lines_added": .number(298)]), "+298"),
            ("write_file", .object(["bytes_written": .number(298)]), "298 bytes"),
            ("web_search", .object(["data": .object(["web": .array([.object(["url": .string("https://example.com")])])])]), "1 source"),
            ("terminal", .object(["exit_code": .number(0), "output": .string("Done")]), "exit 0"),
            ("terminal", .object(["status": .string("yielded_to_background"), "exit_code": .null]), "background"),
            ("terminal", .object(["exit_code": .number(1)]), "error"),
            ("other", .object(["total_lines": .number(30)]), ""),
            ("read_file", .object(["total_lines": .number(-1)]), ""),
            ("read_file", .object(["total_lines": .string("40")]), "")
        ]
        for (name, value, expected) in cases {
            XCTAssertEqual(try ActivityPresentation.trailingMetadata(tool(value, name: name)), expected)
        }
        let running = try tool(.object(["total_lines": .number(12)]), name: "read_file", streaming: true)
        XCTAssertEqual(ActivityPresentation.trailingMetadata(running), "running")
        let withSummary = ChatMessage(role: .tool, text: "", toolName: "read_file", toolSummary: "Read 20 lines")
        XCTAssertEqual(ActivityPresentation.trailingMetadata(withSummary), "")
    }



}
