import XCTest
import AppKit
@testable import PopNotch

/// The top-edge exit check. `NSRect.contains` is half-open on maxY and the
/// panel's top sits flush with the screen's, so a cursor pinned to the top
/// edge read as outside in every panel state — the panel collapsed one row
/// from the top and oscillated on a ~320ms cycle.
final class HoverEdgeTests: XCTestCase {

    /// The measured geometry: screen 956 tall, panel flush with its top.
    private let screenTop: CGFloat = 956
    private let compact = NSRect(x: 587, y: 914, width: 292, height: 42)
    private let expanded = NSRect(x: 507, y: 681, width: 452, height: 275)

    private func inside(_ p: NSPoint, _ panel: NSRect) -> Bool {
        NotchHoverView.isInsideForExit(mouse: p, panel: panel, screenTop: screenTop)
    }

    // MARK: - The bug

    func testCursorExactlyAtTheTopEdgeCountsAsInside() {
        // y == maxY == screenTop. This is the case that oscillated.
        XCTAssertFalse(compact.contains(NSPoint(x: 735, y: 956)),
                       "precondition: NSRect.contains rejects it, which is the bug")
        XCTAssertTrue(inside(NSPoint(x: 735, y: 956), compact))
        XCTAssertTrue(inside(NSPoint(x: 735, y: 956), expanded),
                      "and in the expanded state too — the top edge never moves")
    }

    func testTopEdgeHoldsAcrossBothPanelStates() {
        // The oscillation was a loop between states, so neither may disagree.
        let atEdge = NSPoint(x: 735, y: 956)
        XCTAssertEqual(inside(atEdge, compact), inside(atEdge, expanded))
    }

    // MARK: - Nothing widened

    func testNotWidenedDownward() {
        // One row below the panel's bottom is still outside.
        XCTAssertFalse(inside(NSPoint(x: 735, y: expanded.minY - 1), expanded))
        XCTAssertFalse(inside(NSPoint(x: 735, y: compact.minY - 1), compact))
    }

    func testNotWidenedSideways() {
        // Left and right of the panel, at the top edge, stay outside.
        XCTAssertFalse(inside(NSPoint(x: compact.minX - 1, y: 956), compact))
        XCTAssertFalse(inside(NSPoint(x: compact.maxX, y: 956), compact),
                       "x keeps contains's half-open semantics")
    }

    func testNotWidenedAboveTheScreen() {
        // Nothing beyond the screen edge counts, however unreachable.
        XCTAssertFalse(inside(NSPoint(x: 735, y: 957), compact))
    }

    // MARK: - Ordinary cases unchanged

    func testOrdinaryInsidePointStillInside() {
        XCTAssertTrue(inside(NSPoint(x: 735, y: 936), compact))
        XCTAssertTrue(inside(NSPoint(x: 735, y: 800), expanded))
    }

    func testGenuineExitBelowThePanelStillExits() {
        // The 23:30:39 case from the diagnostic: cursor moved away properly.
        XCTAssertFalse(inside(NSPoint(x: 834, y: 430), expanded))
    }

    func testPanelNotFlushWithScreenTopOnlyExtendsToItsOwnTop() {
        // Defensive: if the fallback screenTop equals the panel's own maxY,
        // the extension is exactly one row and nothing more.
        let panel = NSRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertTrue(NotchHoverView.isInsideForExit(
            mouse: NSPoint(x: 150, y: 200), panel: panel, screenTop: 200))
        XCTAssertFalse(NotchHoverView.isInsideForExit(
            mouse: NSPoint(x: 150, y: 201), panel: panel, screenTop: 200))
    }
}
