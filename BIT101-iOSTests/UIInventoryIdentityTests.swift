#if EXTENDED_AUTOMATION
import XCTest
@testable import BIT101_iOS

nonisolated final class UIInventoryIdentityTests: XCTestCase {
    func testNewRowsRemainPendingAfterScrollAndVisitedRowsSurviveReordering() {
        func row(_ id: String) -> String {
            UITestControlIdentity.key(scope: "Scores", ancestors: ["interaction.list"],
                identifier: "ui.score-list-page.score.\(id)", label: "课程", type: 9) + "#0"
        }
        let firstPage = [row("a"), row("b")]
        let visited = Set(firstPage)
        let nextPage = [row("c"), row("d")]
        let observed = visited.union(nextPage)
        XCTAssertEqual(observed.subtracting(visited), Set(nextPage))
        XCTAssertEqual(Set([row("b"), row("a")]), visited)
    }

    func testRowAncestorsSeparateRepeatedActionsAndKeepStateChangesStable() {
        func action(_ row: String, label: String) -> String {
            UITestControlIdentity.key(scope: "Comments", ancestors: ["list", "comment.\(row)"],
                identifier: "ui.comment.delete", label: label, type: 9)
        }
        XCTAssertNotEqual(action("a", label: "删除"), action("b", label: "删除"))
        XCTAssertEqual(action("a", label: "删除"), action("a", label: "确认删除"))
        XCTAssertNotEqual(UITestControlIdentity.key(scope: "a:b", ancestors: [], identifier: "c", label: "", type: 9),
            UITestControlIdentity.key(scope: "a", ancestors: ["b"], identifier: "c", label: "", type: 9))
    }
}
#endif
