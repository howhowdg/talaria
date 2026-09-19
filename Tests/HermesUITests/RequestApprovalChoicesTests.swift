import XCTest
import HermesProtocol
@testable import HermesUI

final class RequestApprovalChoicesTests: XCTestCase {
    func testKeepsHostOrderAndNeverAddsAnOmittedScope() {
        let value: JSONValue = .object(["choices": .array([.string("deny"), .string("once")])])
        XCTAssertEqual(RequestApprovalChoices.allowed(in: value), ["deny", "once"])
    }
    func testExplicitRestrictionsWinOverContradictoryChoices() {
        let value: JSONValue = .object(["choices": .array([.string("always"), .string("session"), .string("once"), .string("deny")]), "smart_denied": .bool(true)])
        XCTAssertEqual(RequestApprovalChoices.allowed(in: value), ["once", "deny"])
    }
    func testAbsentChoicesDoNotInventPersistentPermission() {
        XCTAssertEqual(RequestApprovalChoices.allowed(in: .object([:])), ["once", "deny"])
        XCTAssertEqual(RequestApprovalChoices.allowed(in: .object(["choices": .array([])])), [])
    }
}
