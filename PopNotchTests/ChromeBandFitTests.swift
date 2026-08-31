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
        return min(max(measured, minWidth), 540).rounded(.up)
    }

    /// Gap between the trailing band's left edge and the housing's right edge.
    ///
    /// The panel centres on the housing via `opticalCenterOffset`, so the
    /// housing sits that far right of panel centre — which is the side the
    /// band is on, and therefore costs clearance rather than granting it.
    private func trailingClearance(panelWidth W: CGFloat, buttons: Int) -> CGFloat {
        let housingRightEdge = W / 2 - NotchPanel.opticalCenterOffset + notchWidth / 2
        let bandLeftEdge = W - NotchOverlayView.contentSideInset - bandWidth(buttons: buttons)
        return bandLeftEdge - housingRightEdge
    }

    /// Anchors the arithmetic to a real observation: the standby panel
    /// measured `{{507, 681}, {452, 275}}` on hardware with all three buttons
    /// showing, and read as +28pt clear.
    func testClearanceFormulaMatchesTheHardwareMeasurement() {
        XCTAssertEqual(trailingClearance(panelWidth: 452, buttons: 3), 28, accuracy: 0.5,
                       "formula must reproduce the measured standby panel")
    }

    func testCaffeineOnlyFitsOnEveryScreen() {
        // A fresh install has both doors off, so this is the shipped default.
        for width in stride(from: CGFloat(320), through: 540, by: 4) {
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
        let clearance = trailingClearance(panelWidth: width, buttons: 1)
        XCTAssertEqual(width, 384, accuracy: 0.5, "clipboard screen width")
        XCTAssertGreaterThanOrEqual(clearance, 0,
            "clipboard screen is \(width)pt; caffeine alone overruns by \(-clearance)pt")
        XCTAssertEqual(clearance, 46, accuracy: 0.5, "caffeine alone clears by 46pt")
    }

    func testNavigatedFileShelfScreenFits() {
        let width = panelWidth(for: FileShelfExpandedView(service: FileShelfService()))
        let clearance = trailingClearance(panelWidth: width, buttons: 1)
        XCTAssertGreaterThanOrEqual(clearance, 0,
            "file shelf screen is \(width)pt; caffeine alone overruns by \(-clearance)pt")
    }

    /// Standby is the only state that shows all three, and it is the widest
    /// of the expanded screens, measured at 452pt on hardware.
    func testStandbyBandWithBothDoorsFits() {
        XCTAssertGreaterThanOrEqual(trailingClearance(panelWidth: 452, buttons: 3), 0,
            "standby carries caffeine plus both doors")
    }
}
