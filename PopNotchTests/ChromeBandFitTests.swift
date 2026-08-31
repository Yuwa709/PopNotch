import XCTest
import SwiftUI
import AppKit
@testable import PopNotch

/// Does the top-trailing chrome band clear the notch housing?
///
/// The band is drawn as an overlay in the neck: it does **not** feed into
/// `measureExpandedContent`, so the panel never widens to accommodate it. A
/// band that outgrows its side of the housing therefore slides silently under
/// the camera cutout instead of pushing anything aside. That makes this a
/// geometry question with a right answer, which is exactly the kind CLAUDE.md
/// says to test rather than eyeball.
///
/// Widths come from laying each screen out in a throwaway `NSHostingView`
/// with the coordinator's own padding, so they are measured, not assumed.
@MainActor
final class ChromeBandFitTests: XCTestCase {

    /// Measured on hardware 2026-08-30: `{{647, 924}, {176, 32}}`.
    private let notchWidth: CGFloat = 176
    private let neckHeight: CGFloat = 32

    /// One 24pt control per button, `HStack(spacing: 2)`.
    private func bandWidth(buttons: Int) -> CGFloat {
        CGFloat(buttons) * 24 + CGFloat(max(0, buttons - 1)) * 2
    }

    /// Mirrors `NotchCoordinator.measureExpandedContent` exactly. If that
    /// padding ever changes, this drifts and the test stops meaning anything,
    /// which is why it is spelled out rather than approximated.
    private func panelWidth<V: View>(for content: V) -> CGFloat {
        let probe = NSHostingView(rootView:
            content
                .padding(.top, neckHeight + 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        )
        let measured = probe.fittingSize.width
        let minWidth = notchWidth + (NotchPanel.leadingWingWidth + 24) * 2
        return min(max(measured, minWidth), 690).rounded(.up)
    }

    /// Gap between the trailing band's left edge and the housing's right edge.
    ///
    /// The panel centres on the housing via `opticalCenterOffset`, so the
    /// housing sits that far right of panel centre — which is the side this
    /// band is on, and therefore costs clearance rather than granting it.
    private func trailingClearance(panelWidth W: CGFloat, buttons: Int) -> CGFloat {
        let housingRightEdge = W / 2 - NotchPanel.opticalCenterOffset + notchWidth / 2
        let bandLeftEdge = W - NotchOverlayView.accessorySideInset - bandWidth(buttons: buttons)
        return bandLeftEdge - housingRightEdge
    }

    /// The mirror on the leading side, where the optical offset works *for*
    /// the band: the housing sits 2pt right of panel centre, so this side has
    /// 2pt more room than the trailing one at the same button count.
    private func leadingClearance(panelWidth W: CGFloat, buttons: Int) -> CGFloat {
        let housingLeftEdge = W / 2 + NotchPanel.opticalCenterOffset - notchWidth / 2
        let bandRightEdge = NotchOverlayView.accessorySideInset + bandWidth(buttons: buttons)
        return housingLeftEdge - bandRightEdge
    }

    /// Anchors the arithmetic to a real observation: the standby panel
    /// measured `{{507, 681}, {452, 275}}` on hardware. At the time it
    /// carried three trailing buttons at the 32pt content inset and read as
    /// +28pt clear; the band has since moved out to `accessorySideInset`, so
    /// the same arrangement now reads 8pt roomier.
    func testClearanceFormulaMatchesTheHardwareMeasurement() {
        let atOldInset = trailingClearance(panelWidth: 452, buttons: 3)
            - (NotchOverlayView.contentSideInset - NotchOverlayView.accessorySideInset)
        XCTAssertEqual(atOldInset, 28, accuracy: 0.5,
                       "formula must still reproduce the measured standby panel")
    }

    func testCaffeineOnlyFitsOnEveryScreen() {
        // A fresh install has both doors off, so this is the shipped default.
        for width in stride(from: CGFloat(320), through: 690, by: 4) {
            XCTAssertGreaterThanOrEqual(
                trailingClearance(panelWidth: width, buttons: 1), 0,
                "the lone caffeine cup must clear the housing at \(width)pt")
        }
    }

    /// Navigated screens carry Back plus caffeine alone: doors are a way *to*
    /// a screen, so they do not render once you are on one. That is the rule
    /// `leadingAccessory()` always had, which moving the doors to the trailing
    /// side dropped by accident and which took the clipboard screen 6pt past
    /// the housing.
    func testNavigatedClipboardScreenFits() {
        let width = panelWidth(for: ClipboardExpandedView(service: ClipboardService()))
        // Keep-awake plus the pin; the doors are a standby-only group.
        let clearance = trailingClearance(panelWidth: width, buttons: 2)
        // 484 since the filter-tab redesign widened the content 320 -> 420;
        // it was 384 before that, and the tight case that motivated this file.
        XCTAssertEqual(width, 484, accuracy: 0.5, "clipboard screen width")
        XCTAssertGreaterThanOrEqual(clearance, 0,
            "clipboard screen is \(width)pt; the band overruns by \(-clearance)pt")
        XCTAssertEqual(clearance, 78, accuracy: 0.5, "keep-awake plus pin clears by 78pt")
    }

    func testNavigatedFileShelfScreenFits() {
        let width = panelWidth(for: FileShelfExpandedView(service: FileShelfService()))
        let clearance = trailingClearance(panelWidth: width, buttons: 2)
        XCTAssertEqual(width, 690, accuracy: 0.5,
            "shelf content is 626pt by design — the panel width ceiling")
        XCTAssertGreaterThanOrEqual(clearance, 0,
            "file shelf screen is \(width)pt; caffeine alone overruns by \(-clearance)pt")
    }

    /// The two shelf modes are deliberately different sizes — the chooser
    /// hugs its zones (user-requested), the resting shelf is wider. That is
    /// safe only because a mode swap cannot happen under a mid-drag cursor
    /// any more: a shelf-originated drag never shows the chooser, so its
    /// transitions coincide with a drag arriving at or leaving the panel.
    /// The pins keep both from drifting.
    func testShelfModeWidthsArePinned() {
        let service = FileShelfService()
        XCTAssertEqual(panelWidth(for: FileShelfExpandedView(service: service)),
                       690, accuracy: 0.5, "resting shelf: 626pt content")
        service.setDragHovering(true)
        XCTAssertEqual(panelWidth(for: FileShelfExpandedView(service: service)),
                       540, accuracy: 0.5, "chooser hugs its 230×125 zones: 476pt content")
    }


    /// Splitting the band across both sides is what bought back the headroom
    /// the pin had eaten.
    ///
    /// Everything on the trailing side was 4 controls / 102pt clearing the
    /// housing by **2pt** on the 452pt standby screen — no margin at all.
    /// Navigation now lives leading (settings + both doors, 76pt) and the
    /// panel-level toggles trailing (keep-awake + pin, 50pt), so the worst
    /// case is +36 instead of +2.
    func testStandbySplitBandClearsBothSides() {
        XCTAssertEqual(leadingClearance(panelWidth: 452, buttons: 3), 36, accuracy: 0.5,
                       "settings plus both doors")
        XCTAssertEqual(trailingClearance(panelWidth: 452, buttons: 2), 62, accuracy: 0.5,
                       "keep-awake plus pin")
    }

    /// Navigated screens replace the whole leading group with Back, so both
    /// sides get roomier still.
    func testNavigatedScreensClearBothSides() {
        for width in [CGFloat(484), 540, 690] {
            XCTAssertGreaterThanOrEqual(leadingClearance(panelWidth: width, buttons: 1), 0,
                "Back must clear the housing at \(width)pt")
            XCTAssertGreaterThanOrEqual(trailingClearance(panelWidth: width, buttons: 2), 0,
                "keep-awake plus pin must clear the housing at \(width)pt")
        }
    }

    /// The band sits nearer the corner than the content column, and must not
    /// reach the rounded corner itself.
    func testAccessoryInsetIsOutsideTheCornerRadius() {
        XCTAssertLessThan(NotchOverlayView.accessorySideInset,
                          NotchOverlayView.contentSideInset,
                          "chrome hugs the corner more tightly than content")
        XCTAssertGreaterThan(NotchOverlayView.accessorySideInset,
                             NotchShape.expandedTopRadius,
                             "inside the corner radius the control gets clipped")
    }
}
