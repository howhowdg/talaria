#if os(macOS)
import XCTest
import HermesCore
@testable import HermesUI

final class MacWorkspaceNavigationTests: XCTestCase {
    func testRunKeepsItsAutomationSelected() {
        XCTAssertEqual(MacHierarchyNavigation.sidebarSelection(.run("run-1"), home: nil,
            runParent: { $0 == "run-1" ? "automation-1" : nil }, workspace: { _ in nil }), .automation("automation-1"))
    }
    func testUnknownRunUsesAutomationsWithoutInventingAParent() {
        XCTAssertEqual(MacHierarchyNavigation.sidebarSelection(.run("unmapped"), home: nil,
            runParent: { _ in nil }, workspace: { _ in nil }), .automations)
    }
    func testExplicitWorkspaceMembershipKeepsParentSelected() {
        let id = UUID(), session = StoredSessionID(rawValue: "session-1")
        XCTAssertEqual(MacHierarchyNavigation.sidebarSelection(.conversation(session), home: nil,
            runParent: { _ in nil }, workspace: { $0 == session ? id : nil }), .workspace(id))
    }
    func testHomeAndUnmappedConversationsNeverDependOnTitleOrRecency() {
        let home = StoredSessionID(rawValue: "chosen"), other = StoredSessionID(rawValue: "latest")
        XCTAssertEqual(MacHierarchyNavigation.sidebarSelection(.conversation(home), home: home,
            runParent: { _ in nil }, workspace: { _ in nil }), .home)
        XCTAssertEqual(MacHierarchyNavigation.sidebarSelection(.conversation(other), home: home,
            runParent: { _ in nil }, workspace: { _ in nil }), .conversation(other))
    }
}
#endif
