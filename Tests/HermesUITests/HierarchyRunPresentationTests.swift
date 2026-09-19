import XCTest
@testable import HermesUI

final class HierarchyRunPresentationTests: XCTestCase {
    func testPreviewSeparatesMarkdownBlocksAndRemovesFormatting() {
        let text = "## Friday, 18 September\n\n**Three meetings.** One moved to 3.\n\n- The landlord replied.\n- Your Lisbon budget is unchanged."
        XCTAssertEqual(HierarchyRunPresentation.preview(text),
                       "Friday, 18 September Three meetings. One moved to 3. The landlord replied. Your Lisbon budget is unchanged.")
    }

    func testPreviewPreservesCodeAndLinkLabelsWithoutMarkdownSyntax() {
        XCTAssertEqual(HierarchyRunPresentation.preview("Run `swift test`.\n\nSee [the result](https://example.com/result)."),
                       "Run swift test. See the result.")
    }
}
