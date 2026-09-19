import XCTest
import HermesCore
import HermesProtocol
@testable import HermesUI

final class WorkspaceInspectorTests: XCTestCase {
    func testDisplayPathShortensOnlyAnExactAbsoluteWorkspacePrefix() {
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace/Sources/App.swift", cwd: "/workspace"), "Sources/App.swift")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace/Sources/App.swift", cwd: "/workspace/"), "Sources/App.swift")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace-other/App.swift", cwd: "/workspace"), "/workspace-other/App.swift")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace", cwd: "/workspace"), "/workspace")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/elsewhere/App.swift", cwd: "/workspace"), "/elsewhere/App.swift")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace/App.swift", cwd: "workspace"), "/workspace/App.swift")
        XCTAssertEqual(InspectorTreePresentation.displayPath("/workspace/App.swift", cwd: ""), "/workspace/App.swift")
    }

    func testHistoricalRelativePathsRemainOpaqueAndDistinctFromShortenedAbsolutePaths() {
        for path in ["notes.md", "../old/report.md", "./notes.md", "workspace/report.md", "C:\\remote\\report.md"] {
            XCTAssertEqual(InspectorTreePresentation.displayPath(path, cwd: "/workspace"), path)
        }
        let files = [InspectorFile(path: "/workspace/notes.md", kind: "Recorded file"),
                     InspectorFile(path: "notes.md", kind: "Referenced attachment")]
        let rows = InspectorTreePresentation.rows(InspectorTreePresentation.nodes(files: files, cwd: "/workspace"), collapsed: [])
        XCTAssertEqual(rows.map(\.node.name), ["notes.md", "notes.md"])
        XCTAssertEqual(Set(rows.compactMap(\.node.fileID)), ["/workspace/notes.md", "notes.md"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "The same display name must not merge distinct host references.")
    }

    func testTreeCollapseHidesOnlyDescendantsAndRetainsStableIdentities() throws {
        let files = ["/workspace/Sources/Feature/One.swift", "/workspace/Sources/Other.swift",
                     "/workspace/README.md", "/external/log.txt"].map { InspectorFile(path: $0, kind: "Recorded file") }
        let tree = InspectorTreePresentation.nodes(files: files, cwd: "/workspace")
        let expanded = InspectorTreePresentation.rows(tree, collapsed: [])
        let sources = try XCTUnwrap(expanded.first { $0.node.name == "Sources" })
        let feature = try XCTUnwrap(expanded.first { $0.node.name == "Feature" })
        XCTAssertEqual(expanded.first { $0.node.fileID == "/workspace/Sources/Feature/One.swift" }?.depth, 2)

        let nestedCollapse = InspectorTreePresentation.rows(tree, collapsed: [feature.id])
        XCTAssertTrue(nestedCollapse.contains { $0.id == feature.id })
        XCTAssertFalse(nestedCollapse.contains { $0.node.fileID == "/workspace/Sources/Feature/One.swift" })
        XCTAssertTrue(nestedCollapse.contains { $0.node.fileID == "/workspace/Sources/Other.swift" })

        let collapsed = InspectorTreePresentation.rows(tree, collapsed: [sources.id])
        XCTAssertTrue(collapsed.contains { $0.id == sources.id })
        XCTAssertFalse(collapsed.contains { $0.id == feature.id })
        XCTAssertEqual(Set(collapsed.compactMap(\.node.fileID)), ["/workspace/README.md", "/external/log.txt"])
        XCTAssertEqual(InspectorTreePresentation.rows(tree, collapsed: []).map(\.id), expanded.map(\.id))

        let updated = InspectorTreePresentation.nodes(files: files + [InspectorFile(path: "/workspace/Sources/New.swift", kind: "Recorded file")], cwd: "/workspace")
        let updatedRows = InspectorTreePresentation.rows(updated, collapsed: [sources.id])
        XCTAssertEqual(updatedRows.map(\.id), collapsed.map(\.id), "A new descendant must not reopen a collapsed directory or change visible row identities.")
    }

    func testReadPreviewUsesRecordedContentAndPreservesOpaqueHostPath() throws {
        let hostPath = "/srv/remote-workspace/../notes.md"
        let snapshot = try inspect([
            tool("read_file", args: ["path": .string("../notes.md")], result: [
                "resolved_path": .string(hostPath), "content": .string("8|# Remote note\n9|One | two"),
                "truncated": .bool(true)
            ])
        ])
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertEqual(file.path, hostPath, "A host path must not be standardized or resolved on this device.")
        XCTAssertEqual(file.content, "# Remote note\nOne | two")
        XCTAssertTrue(file.isMarkdown)
        XCTAssertTrue(file.isTruncated)
    }

    func testMentionedLocalPathDoesNotReadDeviceContents() throws {
        let snapshot = try inspect([
            tool("read_file", args: ["path": .string("/etc/hosts")], result: ["error": .string("Unavailable on remote host")]),
            ChatMessage(role: .user, text: "Please inspect it.\n@file:../private/report.md")
        ])
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["/etc/hosts", "../private/report.md"])
        XCTAssertTrue(snapshot.files.allSatisfy { $0.content == nil })
    }

    func testLaterPatchInvalidatesEarlierFullPreviewAndWriteFailureIsLabeled() throws {
        let snapshot = try inspect([
            tool("read_file", args: ["path": .string("draft.md")], result: ["content": .string("1|Old text")]),
            tool("patch", result: ["success": .bool(true), "files_modified": .array([.string("draft.md")]),
                                   "diff": .string("-Old\n+New")]),
            tool("write_file", args: ["path": .string("failed.md"), "content": .string("Unwritten content")],
                 result: ["error": .string("Permission denied")])
        ])
        XCTAssertNil(snapshot.files.first(where: { $0.path == "draft.md" })?.content)
        XCTAssertEqual(snapshot.files.first(where: { $0.path == "failed.md" })?.kind, "Failed write · submitted content")
        XCTAssertEqual(snapshot.files.first(where: { $0.path == "failed.md" })?.content, "Unwritten content")
    }

    func testBinaryReadIsNotMistakenForAnEmptyTextFile() throws {
        let snapshot = try inspect([
            tool("read_file", args: ["path": .string("image.png")],
                 result: ["content": .string(""), "is_image": .bool(true), "base64_content": .string("aGVsbG8=")])
        ])
        XCTAssertEqual(snapshot.files.first?.kind, "Recorded image")
        XCTAssertNil(snapshot.files.first?.content)
    }

    func testSearchSupportsArrayCompactAndCountModesWithoutTreatingMatchTextAsPaths() throws {
        let snapshot = try inspect([
            tool("search_files", result: ["matches": .array([
                .object(["path": .string("Sources/One.swift"), "line": .number(2), "content": .string("let a = 1")])
            ])]),
            tool("search_files", result: [
                "matches_format": .string("path-grouped: each file path on its own line, followed by indented '<line>: <content>' rows for matches in that file"),
                "matches_text": .string("Sources/Two.swift\n  3: /not/a/file/path\n  5: text\nREADME.md\n  1: # Title")
            ]),
            tool("search_files", result: ["counts": .object(["Tests/One.swift": .number(3)])]),
            tool("search_files", result: ["files": .array([.string("Package.swift")])]),
            tool("search_files", result: ["matches_text": .string("untyped-prose.md\n  1: not a declared compact result")])
        ])
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["Sources/One.swift", "Sources/Two.swift", "README.md", "Tests/One.swift", "Package.swift"])
        XCTAssertTrue(snapshot.files.allSatisfy { $0.content == nil }, "Search excerpts do not establish complete file contents.")
    }

    func testSourcesComeOnlyFromSuccessfulStructuredWebResults() throws {
        let snapshot = try inspect([
            ChatMessage(role: .assistant, text: "[Invented](https://invented.example/)"),
            tool("terminal", result: ["output": .string("https://terminal.example/")]),
            tool("web_search", result: ["success": .bool(true), "data": .object(["web": .array([
                .object(["url": .string("https://docs.example/page"), "title": .string("Recorded page"), "description": .string("Actual result")]),
                .object(["url": .string("javascript:alert(1)"), "title": .string("Rejected")]),
                .object(["url": .string("file:///private/etc/hosts")])
            ])])]),
            tool("web_extract", result: ["results": .array([
                .object(["url": .string("https://docs.example/page"), "title": .string("Extracted page")]),
                .object(["url": .string("https://failed.example/"), "error": .string("Blocked")])
            ])])
        ])
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources.first?.url.absoluteString, "https://docs.example/page")
        XCTAssertEqual(snapshot.sources.first?.title, "Extracted page")
    }

    func testSourceURLValidationRejectsSchemesCredentialsAndControlCharacters() {
        for unsafe in ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,test", "mailto:user@example.com",
                       "//example.com/path", "https://user:password@example.com/", "https://example.com/\nother", "https:///", ""] {
            XCTAssertNil(InspectorSnapshot.safeWebURL(unsafe), unsafe)
        }
        XCTAssertEqual(InspectorSnapshot.safeWebURL("https://docs.example/a?b=c#section")?.host, "docs.example")
        XCTAssertEqual(InspectorSnapshot.safeWebURL("http://localhost:8080/page")?.port, 8080)
        XCTAssertNil(InspectorSnapshot.safeWebURL("https://example.com/" + String(repeating: "x", count: 4_096)))
    }

    func testSourceOverflowRetainsLaterSearchesAndRefreshesExistingMetadata() throws {
        var messages = (0..<105).map { index in
            tool("web_search", result: ["data": .object(["web": .array([
                .object(["url": .string("https://docs.example/\(index)"), "title": .string("Original \(index)")])
            ])])])
        }
        messages.append(tool("web_extract", result: ["results": .array([
            .object(["url": .string("https://docs.example/5"), "title": .string("Refreshed source"),
                     "description": .string("New metadata")]),
            .object(["url": .string("https://docs.example/new"), "title": .string("Later search")])
        ])]))
        let snapshot = try inspect(messages)
        XCTAssertEqual(snapshot.sources.count, 100)
        XCTAssertTrue(snapshot.isLimited)
        XCTAssertNotNil(snapshot.sources.first { $0.url.absoluteString == "https://docs.example/new" })
        XCTAssertNil(snapshot.sources.first { $0.url.absoluteString == "https://docs.example/0" })
        XCTAssertNil(snapshot.sources.first { $0.url.absoluteString == "https://docs.example/6" },
                     "Refreshing source 5 must promote it before the next oldest source is evicted.")
        let refreshed = try XCTUnwrap(snapshot.sources.first { $0.url.absoluteString == "https://docs.example/5" })
        XCTAssertEqual(refreshed.title, "Refreshed source")
        XCTAssertEqual(refreshed.summary, "New metadata")
    }

    func testOversizedSourceBatchRetainsNewestRecordedEntries() throws {
        let rows = (0..<105).map { index in
            JSONValue.object(["url": .string("https://docs.example/\(index)")])
        }
        let snapshot = try inspect([tool("web_search", result: ["data": .object(["web": .array(rows)])])])
        XCTAssertEqual(Set(snapshot.sources.map { $0.url.lastPathComponent }), Set((5..<105).map(String.init)))
        XCTAssertTrue(snapshot.isLimited)
    }

    func testTerminalRecordsKeepCommandOutputAndExitCodeTogether() throws {
        let snapshot = try inspect([
            tool("terminal", args: ["command": .string("printf 'hello'"), "workdir": .string("/remote/work")],
                 result: ["output": .string("hello"), "exit_code": .number(7)]),
            ChatMessage(id: "plain-output", role: .tool, text: "Legacy result text", toolName: "terminal"),
            ChatMessage(id: "running", role: .tool, text: "Starting command", toolName: "terminal",
                        toolInput: "{\"command\":\"long-running-command\"}", isStreaming: true)
        ])
        XCTAssertEqual(snapshot.commands.map(\.status), ["Working…", "Recorded output", "Exit 7"])
        XCTAssertEqual(snapshot.commands[2].command, "printf 'hello'")
        XCTAssertEqual(snapshot.commands[2].workdir, "/remote/work")
        XCTAssertEqual(snapshot.commands[2].output, "hello")
        XCTAssertEqual(snapshot.commands[1].output, "Legacy result text")
        XCTAssertEqual(snapshot.commands[0].output, "", "A tool-start summary is not terminal output.")
    }

    func testScopeChangesForConnectionProfileStoredSessionAndCWDOnly() throws {
        let connectionID = UUID()
        let owner = SessionOwner(connectionID: connectionID, profile: "default")
        let original = try state(owner: owner)
        let originalScope = InspectorInput(state: original, attachments: []).scope
        XCTAssertNotEqual(originalScope, InspectorInput(state: try state(owner: .init(connectionID: UUID(), profile: "default")), attachments: []).scope)
        XCTAssertNotEqual(originalScope, InspectorInput(state: try state(owner: .init(connectionID: connectionID, profile: "other")), attachments: []).scope)
        XCTAssertNotEqual(originalScope, InspectorInput(state: try state(owner: owner, stored: "other"), attachments: []).scope)
        XCTAssertNotEqual(originalScope, InspectorInput(state: try state(owner: owner, cwd: "/other"), attachments: []).scope)
        var reconnected = original
        reconnected.runtimeID = RuntimeSessionID(rawValue: "new-runtime")
        XCTAssertEqual(originalScope, InspectorInput(state: reconnected, attachments: []).scope)
        XCTAssertNil(InspectorInput(state: nil, attachments: []).scope)
    }

    func testAssistantStreamingDoesNotInvalidateInputAndNilConversationHidesAttachments() throws {
        var conversation = try state()
        conversation.messages = [ChatMessage(id: "assistant", role: .assistant, text: "Partial", isStreaming: true)]
        let input = InspectorInput(state: conversation, attachments: [])
        conversation.messages[0].text += " answer"
        XCTAssertEqual(input, InspectorInput(state: conversation, attachments: []))
        let attachment = AttachmentItem(id: UUID(), filename: "report.txt", state: .ready, destination: "/remote/report.txt")
        XCTAssertTrue(InspectorSnapshot(input: InspectorInput(state: nil, attachments: [attachment])).files.isEmpty)
        XCTAssertEqual(InspectorSnapshot(input: InspectorInput(state: conversation, attachments: [attachment])).files.first?.path, "/remote/report.txt")
    }

    private func state(owner: SessionOwner = .init(connectionID: UUID(), profile: "default"),
                       stored: String = "stored", cwd: String = "/remote/work") throws -> ConversationState {
        try ConversationState(snapshot: .object([
            "session_id": .string("runtime"), "stored_session_id": .string(stored),
            "messages": .array([]), "info": .object(["cwd": .string(cwd)])
        ]), owner: owner)
    }

    private func inspect(_ messages: [ChatMessage]) throws -> InspectorSnapshot {
        var conversation = try state()
        conversation.messages = messages
        return InspectorSnapshot(input: InspectorInput(state: conversation, attachments: []))
    }

    private func tool(_ name: String, args: [String: JSONValue] = [:], result: [String: JSONValue]) -> ChatMessage {
        ChatMessage(role: .tool, text: ConversationState.describe(.object(result)), toolName: name,
                    toolInput: ConversationState.describe(.object(args)))
    }
}
