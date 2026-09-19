#if os(macOS)
import XCTest
import HermesCore
@testable import HermesUI

final class MacTranscriptGroupTests: XCTestCase {
    func testToolsStayWithTheirIssuingAssistantWithoutChangingChronology() {
        let messages = [row("u", .user), row("a", .assistant), row("t1", .tool),
                        row("t2", .tool), row("reply", .assistant)]
        let groups = MacTranscriptGroup.make(messages)
        XCTAssertEqual(groups.map(\.id), ["u", "a", "reply"])
        XCTAssertEqual(groups[1].tools.map(\.id), ["t1", "t2"])
        XCTAssertEqual(groups.flatMap { ($0.message.map { [$0] } ?? []) + $0.tools }, messages)
    }

    func testOrphanToolsDoNotBecomeUserOrSystemBubbleText() {
        let messages = [row("t0", .tool), row("u", .user), row("t1", .tool),
                        row("s", .system), row("t2", .tool), row("t3", .tool)]
        let groups = MacTranscriptGroup.make(messages)
        XCTAssertEqual(groups.map(\.id), ["t0", "u", "t1", "s", "t2"])
        XCTAssertNil(groups[0].message)
        XCTAssertNil(groups[2].message)
        XCTAssertEqual(groups[4].tools.map(\.id), ["t2", "t3"])
        XCTAssertTrue(groups[1].tools.isEmpty)
        XCTAssertTrue(groups[3].tools.isEmpty)
        XCTAssertEqual(groups.flatMap { ($0.message.map { [$0] } ?? []) + $0.tools }, messages)
    }

    private func row(_ id: String, _ role: MessageRole) -> ChatMessage {
        ChatMessage(id: id, role: role, text: id)
    }
}
#endif
