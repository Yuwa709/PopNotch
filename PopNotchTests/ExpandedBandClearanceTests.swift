import XCTest
import AppKit
@testable import PopNotch

/// For EVERY expanded state, at both observed housing geometries: neither
/// chrome group's x-range may intersect the housing's x-range, and both
/// must sit inside the panel, clear of its rounded corners.
///
/// This is the assertion that would have caught both band regressions:
/// the corner-anchored band sliding under the housing on a narrow panel
/// (2026-09-01, first report), and the width-floored-but-centred spacer
/// doing the same thing two fixes later (2026-09-01, stats-only standby,
/// photo-confirmed). The group positions come from
/// `NotchOverlayView.bandGapRange` — the same function the view lays out
/// from — and the frames from `NotchPanel.expandedRect`, the same function
/// the coordinator and the panel size from, so there is no re-derived model
/// here to drift out of date.
@MainActor
final class ExpandedBandClearanceTests: XCTestCase {

    /// 1470×956 default scale and 1710×1112 more-space scale, both from the
    /// app's own notchRect logs.
    private let housings = [
        NSRect(x: 647, y: 924, width: 176, height: 32),
        NSRect(x: 752, y: 1074, width: 206, height: 38),
    ]

    /// Every expanded state the panel can be in, as (name, content size,
    /// chromeOnly, band groups). Content widths are the pinned real ones
    /// (see ChromeBandFitTests); .zero is anything at or below the width
    /// floor, which is where both regressions lived. Standby carries
    /// settings + both doors leading; navigated screens carry Back alone.
    private var states: [(name: String, content: CGSize, chromeOnly: Bool,
                          groups: NotchPanel.ChromeGroupWidths)] {
        let standby = NotchPanel.ChromeGroupWidths(leading: 76, trailing: 50)
        let navigated = NotchPanel.ChromeGroupWidths(leading: 24, trailing: 50)
        return [
            ("chrome-only bar", .zero, true, standby),
            ("standby at the width floor (stats only)", .zero, false, standby),
            ("standby, media playing", CGSize(width: 432, height: 300), false, standby),
            ("navigated: clipboard", CGSize(width: 484, height: 260), false, navigated),
            ("navigated: shelf drop chooser", CGSize(width: 540, height: 220), false, navigated),
            ("navigated: resting shelf", CGSize(width: 690, height: 230), false, navigated),
        ]
    }

    func testNoChromeGroupIntersectsTheHousingInAnyExpandedState() {
        for housing in housings {
            for state in states {
                let rect = NotchPanel.expandedRect(housing: housing,
                                                   contentSize: state.content,
                                                   chromeOnly: state.chromeOnly,
                                                   chromeGroups: state.groups)
                let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
                let band = NotchOverlayView.bandLayout(panelWidth: rect.width,
                                                       housingLocal: housingLocal,
                                                       groups: state.groups)
                let leading = band.leadingInset...(band.leadingInset + state.groups.leading)
                let trailingStart = rect.width - band.trailingInset - state.groups.trailing
                let trailing = trailingStart...(trailingStart + state.groups.trailing)
                let label = "\(state.name), housing \(Int(housing.width))×\(Int(housing.height)), panel \(rect.width)pt"

                XCTAssertFalse(leading.overlaps(housingLocal),
                    "leading group \(leading) intersects housing \(housingLocal): \(label)")
                XCTAssertFalse(trailing.overlaps(housingLocal),
                    "trailing group \(trailing) intersects housing \(housingLocal): \(label)")

                // Inside the panel, clear of the rounded corner — a group
                // pushed off the edge is as unusable as one behind the
                // camera.
                XCTAssertGreaterThanOrEqual(leading.lowerBound, NotchShape.expandedTopRadius,
                    "leading group runs into the corner: \(label)")
                XCTAssertLessThanOrEqual(trailing.upperBound, rect.width - NotchShape.expandedTopRadius,
                    "trailing group runs into the corner: \(label)")
            }
        }
    }

    /// The housing is a clamp, not an anchor: in every expanded state both
    /// groups sit the same distance from their own panel edge, and that
    /// distance is `accessorySideInset`. A clamp firing anywhere means the
    /// width floor and `bandLayout` have drifted apart — the panel would
    /// still clear the housing (asserted above) but a button would sit
    /// somewhere other than its corner, which is the bug this pairs with.
    func testBothGroupsSitEquidistantFromTheirPanelEdges() {
        for housing in housings {
            for state in states {
                let rect = NotchPanel.expandedRect(housing: housing,
                                                   contentSize: state.content,
                                                   chromeOnly: state.chromeOnly,
                                                   chromeGroups: state.groups)
                let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
                let band = NotchOverlayView.bandLayout(panelWidth: rect.width,
                                                       housingLocal: housingLocal,
                                                       groups: state.groups)
                let label = "\(state.name), housing \(Int(housing.width))×\(Int(housing.height)), panel \(rect.width)pt"

                XCTAssertFalse(band.isClamped,
                    "clamp fired — width floor is short: \(label), floor \(NotchPanel.bandMinWidth(housingWidth: housing.width, groups: state.groups))")
                XCTAssertEqual(band.leadingInset, band.trailingInset,
                    "groups sit at different distances from their edges: \(label)")
                XCTAssertEqual(band.leadingInset, NotchOverlayView.accessorySideInset,
                    "band no longer hangs off the corner: \(label)")
            }
        }
    }

    /// The floor is what keeps the clamp dormant, so it has to be at least
    /// the geometry's own requirement — and a panel one point narrower must
    /// actually clamp, or the floor is loose and the guarantee is luck.
    func testWidthFloorIsExactlyWhatTheClampNeeds() {
        for housing in housings {
            for groups in [NotchPanel.ChromeGroupWidths(leading: 76, trailing: 50),
                           NotchPanel.ChromeGroupWidths(leading: 24, trailing: 50)] {
                let floor = NotchPanel.bandMinWidth(housingWidth: housing.width, groups: groups)
                // One point under the floor, placed the way expandedRect
                // places a panel, must clamp.
                let narrow = floor - 1
                let minX = (housing.midX + NotchPanel.opticalCenterOffset - narrow / 2)
                let housingLocal = (housing.minX - minX)...(housing.maxX - minX)
                let band = NotchOverlayView.bandLayout(panelWidth: narrow,
                                                       housingLocal: housingLocal,
                                                       groups: groups)
                XCTAssertTrue(band.isClamped,
                    "floor \(floor) is loose: \(narrow)pt did not clamp, housing \(housing.width), groups \(groups)")
            }
        }
    }
}
