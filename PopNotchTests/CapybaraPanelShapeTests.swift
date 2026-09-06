import XCTest
import SwiftUI
import AppKit
@testable import PopNotch

/// The capybara silhouette against the geometry baseline in
/// PROJECT-CONTEXT.md. Three things the feature was specified with are
/// pinned here rather than eyeballed: the silhouette *contains* today's card
/// (nothing moves or shrinks), theme-off is today's geometry to the point,
/// and hover follows the new outline instead of the bounding rectangle.
@MainActor
final class CapybaraPanelShapeTests: XCTestCase {

    /// Today's themed body: 432 × 281, measured 2026-09-06.
    private let body = CGRect(x: 0, y: 0, width: 432, height: 281)
    private let housing = NSRect(x: 647, y: 924, width: 176, height: 32)
    private var lobes: PanelSilhouetteInsets { CapybaraPanelShape.insets(bodyHeight: body.height) }
    private var drawn: CGRect { CGRect(x: 0, y: 0, width: body.width + lobes.total, height: body.height) }
    private var scale: CGFloat { body.height / CapybaraPanelShape.artworkRows }

    private func capybara() -> CGPath { CapybaraPanelShape.outline(in: drawn, insets: lobes).cgPath }
    private func card() -> CGPath {
        NotchShape(topRadius: NotchShape.expandedTopRadius,
                   bottomRadius: NotchShape.expandedBottomRadius).path(in: body).cgPath
    }
    private func inside(_ p: CGPath, _ x: CGFloat, _ y: CGFloat) -> Bool {
        p.contains(CGPoint(x: x, y: y), using: .winding)
    }

    // MARK: - Lobes

    func testLobesScaleWithTheBodyHeight() {
        XCTAssertEqual(lobes, PanelSilhouetteInsets(leading: 71, trailing: 25), "281pt body")
        XCTAssertEqual(CapybaraPanelShape.insets(bodyHeight: 433),
                       PanelSilhouetteInsets(leading: 116, trailing: 46), "lyrics takeover")
        XCTAssertEqual(CapybaraPanelShape.insets(bodyHeight: 40), .none,
                       "lobes inside the flare width need no frame growth")
    }

    // MARK: - Contains today's card

    /// Every point inside the expanded `NotchShape` is inside the capybara
    /// once the body is placed past the head. This is the whole "wraps, does
    /// not squeeze" guarantee, as a test over a 2pt grid.
    func testSilhouetteContainsTodaysCardEverywhere() {
        let c = capybara(), k = card()
        var checked = 0, escaped = 0
        for x in stride(from: 0.5, to: body.width, by: 2.0) {
            for y in stride(from: 0.5, to: body.height, by: 2.0) where inside(k, x, y) {
                checked += 1
                if !inside(c, x + lobes.leading, y) { escaped += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 20_000, "the card sample is real")
        XCTAssertEqual(escaped, 0, "points of today's card outside the capybara")
    }

    func testTopIsTodaysFlareAtExactlyTheBodyWidth() {
        let c = capybara()
        XCTAssertTrue(inside(c, lobes.leading + 6, 0.5), "flare, top row")
        XCTAssertFalse(inside(c, lobes.leading - 1, 0.5), "nothing left of the body at the top")
        XCTAssertFalse(inside(c, lobes.leading + body.width + 1, 0.5), "nothing right of the body at the top")
    }

    // MARK: - The animal

    func testHeadIsOnTheLeftBelowTheNeck() {
        let c = capybara()
        XCTAssertTrue(inside(c, 20, 200), "snout")
        XCTAssertFalse(inside(c, 20, 40), "above the head is empty — the band's row is untouched")
        XCTAssertFalse(inside(c, 20, 84), "at the neck the forehead starts flush with the body")
        XCTAssertTrue(inside(c, 60, 130), "forehead slope")
        XCTAssertFalse(inside(c, 5, 130), "outside the forehead")
    }

    func testBackAndRumpAreOnTheRight() {
        let c = capybara()
        let side = lobes.leading + body.width - NotchShape.expandedTopRadius
        XCTAssertTrue(inside(c, side + 30, 200), "rump")
        XCTAssertFalse(inside(c, side + 30, 20), "above the shoulder the side is straight")
        XCTAssertFalse(inside(c, side + 30, 60), "the shoulder is still curving in")
        XCTAssertTrue(inside(c, side + 10, 60), "but has begun")
    }

    func testUndersideIsFlat() {
        let c = capybara()
        let chinEnd = lobes.leading + NotchShape.expandedTopRadius - CapybaraPanelShape.chinEnd * scale
        let rumpX = lobes.leading + body.width - NotchShape.expandedTopRadius + CapybaraPanelShape.rumpDepth * scale
        for x in stride(from: chinEnd + 2, to: rumpX - 12, by: 10) {
            XCTAssertTrue(inside(c, x, body.height - 0.5), "x=\(x)")
            XCTAssertFalse(inside(c, x, body.height + 0.5), "x=\(x)")
        }
    }

    // MARK: - Frame

    func testExpandedRectAddsLobesOutsideAnUnmovedBody() {
        let content = CGSize(width: 432, height: 281)
        let plain = NotchPanel.expandedRect(housing: housing, contentSize: content)
        let themed = NotchPanel.expandedRect(housing: housing, contentSize: content, capybara: true)
        XCTAssertEqual(plain, NSRect(x: 517, y: 675, width: 432, height: 281), "the baseline")
        XCTAssertEqual(themed.height, plain.height)
        XCTAssertEqual(themed.minX, plain.minX - 71)
        XCTAssertEqual(themed.width, plain.width + 71 + 25)
        XCTAssertEqual(NotchPanel.expandedRect(housing: housing, contentSize: content, capybara: false),
                       plain, "off is today's rect to the point")
        XCTAssertEqual(NotchPanel.expandedRect(housing: housing, contentSize: .zero, chromeOnly: true, capybara: true),
                       NotchPanel.expandedRect(housing: housing, contentSize: .zero, chromeOnly: true),
                       "the chrome-only bar never grows lobes")
    }

    func testChromeBandStaysOnTheBodyCorners() {
        let groups = NotchPanel.ChromeGroupWidths(leading: 76, trailing: 76)
        let rect = NotchPanel.expandedRect(housing: housing, contentSize: CGSize(width: 432, height: 281),
                                           chromeGroups: groups, capybara: true)
        let local = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
        let band = NotchOverlayView.bandLayout(panelWidth: rect.width, housingLocal: local,
                                               groups: groups, bodyInsets: lobes)
        XCTAssertFalse(band.isClamped)
        XCTAssertEqual(band.leadingInset, NotchOverlayView.accessorySideInset + 71)
        XCTAssertEqual(band.trailingInset, NotchOverlayView.accessorySideInset + 25)
        let plainLocal: ClosedRange<CGFloat> = 130...306
        XCTAssertEqual(NotchOverlayView.bandLayout(panelWidth: 432, housingLocal: plainLocal, groups: groups),
                       NotchOverlayView.bandLayout(panelWidth: 432, housingLocal: plainLocal, groups: groups,
                                                   bodyInsets: .none),
                       "no lobes is today's layout")
    }

    // MARK: - Hover

    func testHoverSlabsCoverTheSilhouetteAndNotTheEmptyCorners() {
        let halo = NotchPanel.hoverMargin
        let frame = CGSize(width: drawn.width + 2 * halo, height: drawn.height + halo)
        let slabs = CapybaraPanelShape.hoverSlabs(frameSize: frame, halo: halo, insets: lobes)
        XCTAssertGreaterThan(slabs.count, 10)
        let path = CapybaraPanelShape.outline(
            in: CGRect(x: halo, y: 0, width: drawn.width, height: drawn.height), insets: lobes).cgPath

        var checked = 0, uncovered = 0
        for x in stride(from: 0.5, to: frame.width, by: 3.0) {
            for y in stride(from: 0.5, to: frame.height - halo, by: 3.0)
            where path.contains(CGPoint(x: x, y: y), using: .winding) {
                checked += 1
                if !slabs.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { uncovered += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 5_000)
        XCTAssertEqual(uncovered, 0, "silhouette points no slab covers")

        let bounds = CGRect(origin: .zero, size: frame)
        for slab in slabs { XCTAssertTrue(bounds.contains(slab), "slab leaves the frame: \(slab)") }

        let top = slabs.min { $0.minY < $1.minY }!
        XCTAssertEqual(top.minY, 0, "reaches the screen edge")
        XCTAssertLessThanOrEqual(top.minX, halo + lobes.leading)
        XCTAssertGreaterThanOrEqual(top.maxX, halo + lobes.leading + body.width - NotchShape.expandedTopRadius + halo)

        XCTAssertFalse(slabs.contains { $0.contains(CGPoint(x: 20, y: 40)) },
                       "the empty corner above the head is untracked")
        let bottom = slabs.max { $0.maxY < $1.maxY }!
        XCTAssertEqual(bottom.maxY, frame.height, "the halo below the underside is kept")
    }

    func testMultiRegionExitTestFollowsTheRegions() {
        let screenTop: CGFloat = 956
        let top = NSRect(x: 100, y: 900, width: 400, height: 56)     // flush with the screen
        let lower = NSRect(x: 50, y: 800, width: 500, height: 100)   // wider, below
        let regions = [top, lower]
        XCTAssertTrue(NotchHoverView.isInsideForExit(mouse: NSPoint(x: 200, y: 850), regions: regions, screenTop: screenTop))
        XCTAssertTrue(NotchHoverView.isInsideForExit(mouse: NSPoint(x: 60, y: 850), regions: regions, screenTop: screenTop))
        XCTAssertFalse(NotchHoverView.isInsideForExit(mouse: NSPoint(x: 60, y: 920), regions: regions, screenTop: screenTop),
                       "inside the bounding box, in no region: the empty corner")
        XCTAssertTrue(NotchHoverView.isInsideForExit(mouse: NSPoint(x: 200, y: 956), regions: regions, screenTop: screenTop),
                      "top-edge carve-out holds for the top region")
        XCTAssertFalse(NotchHoverView.isInsideForExit(mouse: NSPoint(x: 60, y: 901), regions: regions, screenTop: screenTop),
                       "no carve-out above a lower region")

        let panel = NSRect(x: 100, y: 800, width: 400, height: 156)
        for p in [NSPoint(x: 200, y: 850), NSPoint(x: 200, y: 956), NSPoint(x: 50, y: 850), NSPoint(x: 200, y: 957)] {
            XCTAssertEqual(NotchHoverView.isInsideForExit(mouse: p, panel: panel, screenTop: screenTop),
                           NotchHoverView.isInsideForExit(mouse: p, regions: [panel], screenTop: screenTop),
                           "one region is the old test: \(p)")
        }
    }
}
