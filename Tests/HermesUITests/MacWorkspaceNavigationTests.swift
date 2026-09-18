#if os(macOS)
import XCTest
import HermesCore
@testable import HermesUI

final class MacWorkspaceNavigationTests: XCTestCase {
    private let first = StoredSessionID(rawValue: "first")
    private let second = StoredSessionID(rawValue: "second")
    private let rotated = StoredSessionID(rawValue: "first-continued")
    private let firstRuntime = RuntimeSessionID(rawValue: "runtime-first")
    private let secondRuntime = RuntimeSessionID(rawValue: "runtime-second")

    func testFailedOpenRestoresAuthoritativeSelectionWithoutCreatingATab() {
        var state = MacWorkspaceNavigationState()
        let runtimes = [first: firstRuntime]
        state.synchronize(selectedID: first, runtimes: runtimes)
        state.selection = second // A pending UI selection may differ before navigation finishes.

        state.synchronize(selectedID: first, runtimes: runtimes, revealSelection: false)

        XCTAssertEqual(state.selection, first)
        XCTAssertEqual(state.tabIDs, [first])
        XCTAssertFalse(state.showsStartPage)
    }

    func testClosingActiveTabHidesItsDetailEvenWhenReplacementCannotOpen() {
        var state = twoOpenTabs()
        XCTAssertEqual(state.closeTab(second), first)
        XCTAssertTrue(state.showsStartPage)
        XCTAssertNil(state.selection)

        // A disconnected or failed resume leaves the model on the closed session.
        state.synchronize(selectedID: second, runtimes: [first: firstRuntime, second: secondRuntime],
                          revealSelection: false)

        XCTAssertEqual(state.tabIDs, [first])
        XCTAssertTrue(state.showsStartPage)
    }

    func testReplacementBecomesVisibleOnlyAfterModelSelectsIt() {
        var state = twoOpenTabs()
        _ = state.closeTab(second)

        state.synchronize(selectedID: first, runtimes: [first: firstRuntime, second: secondRuntime])

        XCTAssertEqual(state.selection, first)
        XCTAssertEqual(state.tabIDs, [first])
        XCTAssertFalse(state.showsStartPage)
    }

    func testStoredIdentityRotationReplacesTheActiveTabInPlace() {
        var state = twoOpenTabs()
        state.synchronize(selectedID: first, runtimes: [first: firstRuntime, second: secondRuntime])

        state.synchronize(selectedID: rotated, runtimes: [rotated: firstRuntime, second: secondRuntime])

        XCTAssertEqual(state.selection, rotated)
        XCTAssertEqual(state.tabIDs, [rotated, second])
        XCTAssertFalse(state.showsStartPage)
    }

    func testStoredIdentityRotationAlsoUpdatesBackgroundTabs() {
        var state = twoOpenTabs()

        state.synchronize(selectedID: second, runtimes: [rotated: firstRuntime, second: secondRuntime])

        XCTAssertEqual(state.selection, second)
        XCTAssertEqual(state.tabIDs, [rotated, second])
    }

    func testBackgroundRotationDoesNotReopenTheLastClosedTab() {
        var state = MacWorkspaceNavigationState()
        state.synchronize(selectedID: first, runtimes: [first: firstRuntime])
        XCTAssertNil(state.closeTab(first))

        state.synchronize(selectedID: rotated, runtimes: [rotated: firstRuntime])

        XCTAssertTrue(state.tabIDs.isEmpty)
        XCTAssertTrue(state.showsStartPage)
        // An explicit click on that session is allowed to reveal it again.
        state.synchronize(selectedID: rotated, runtimes: [rotated: firstRuntime], revealSelection: true)
        XCTAssertEqual(state.tabIDs, [rotated])
        XCTAssertFalse(state.showsStartPage)
    }

    private func twoOpenTabs() -> MacWorkspaceNavigationState {
        var state = MacWorkspaceNavigationState()
        let runtimes = [first: firstRuntime, second: secondRuntime]
        state.synchronize(selectedID: first, runtimes: runtimes)
        state.synchronize(selectedID: second, runtimes: runtimes)
        return state
    }
}
#endif
