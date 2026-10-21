#if EXTENDED_AUTOMATION
import XCTest
@testable import BIT101_iOS

nonisolated final class UIInventoryIdentityTests: XCTestCase {
    func testScrollEndUsesPhysicalPixelPrecision() {
        XCTAssertEqual(UITestScrollGeometry.visibleDistance(1.4210854715202004e-13, scale: 3), 0)
        XCTAssertEqual(UITestScrollGeometry.visibleDistance(-1.4210854715202004e-13, scale: 3), 0)
        XCTAssertEqual(UITestScrollGeometry.visibleDistance(1.0 / 3, scale: 3), 1.0 / 3)
        XCTAssertEqual(UITestScrollGeometry.visibleDistance(280.3333333333335, scale: 3), 280.3333333333333)
    }

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

    func testAccessibilityWrapperAndNativeControlShareTheirIdentity() {
        let control = UITestControlIdentity.key(scope: "Settings / Recovery", ancestors: ["settings"],
            identifier: "confirm", label: "恢复", type: 9)
        XCTAssertEqual(control, UITestControlIdentity.key(scope: "Settings / Recovery", ancestors: ["settings", "confirm", "confirm"],
            identifier: "confirm", label: "恢复", type: 9))
        XCTAssertNotEqual(control, UITestControlIdentity.key(scope: "Settings / Recovery", ancestors: ["account", "confirm"],
            identifier: "confirm", label: "恢复", type: 9))
    }
}
#endif
