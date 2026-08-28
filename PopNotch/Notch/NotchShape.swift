import SwiftUI

/// The expanded-notch silhouette: top edge flush with the screen top, concave
/// corners flaring into the menu bar, straight sides, convex rounded bottom
/// corners. The body is inset from the panel edges by `topRadius`; the flare
/// spans the full width at the very top.
///
/// Radii clamp to the available rect so the collapsed (exact-notch) size
/// stays drawable without artifacts.
struct NotchShape: Shape {

    /// Per-state radii, user-tuned: the open card is softer than the
    /// compact bar.
    static let compactTopRadius: CGFloat = 10
    static let compactBottomRadius: CGFloat = 20
    static let expandedTopRadius: CGFloat = 12
    static let expandedBottomRadius: CGFloat = 26

    var topRadius: CGFloat = NotchShape.compactTopRadius
    var bottomRadius: CGFloat = NotchShape.compactBottomRadius

    func path(in rect: CGRect) -> Path {
        let topR = min(topRadius, rect.width / 4, rect.height / 2)
        let botR = min(bottomRadius, rect.width / 4, rect.height / 2)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Concave top-left fillet: full-width at the screen edge, easing
        // inward to the body.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
        // Convex bottom-left corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))
        // Convex bottom-right corner.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        // Concave top-right fillet.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

/// What the panel hosts: the silhouette, plus whatever the arbiter says
/// should be inside it.
///
/// The fill measures #000000 at the window buffer — the darkest displayable
/// value. Solid, no stroke; any residual mismatch against the bezel is LCD
/// backlight, not colour.
///
/// Content is inset below the menu bar band so it never renders behind the
/// physical camera housing, where it would be invisible.
struct NotchOverlayView: View {

    var content: AnyView?
    /// Compact-state wing contents, drawn in the menu bar band flanking the
    /// housing. The gap between them is exactly the housing's deadzone.
    var leadingWing: AnyView?
    var trailingWing: AnyView?
    /// The menu bar band, which the housing occupies. Content starts below it.
    var neckHeight: CGFloat = 32

    var body: some View {
        // Expanded (has content) draws the softer card; compact and idle
        // keep the tighter bar silhouette.
        let expanded = content != nil
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: expanded ? NotchShape.expandedTopRadius : NotchShape.compactTopRadius,
                bottomRadius: expanded ? NotchShape.expandedBottomRadius : NotchShape.compactBottomRadius
            )
            .fill(Color.black)
            if leadingWing != nil || trailingWing != nil {
                // Centered in each wing: hugging the outer corners looked
                // crowded, hugging the housing looked glued to it (both
                // user-verified on hardware, the latter by photo). Center
                // splits the margin evenly.
                HStack(spacing: 0) {
                    wing(leadingWing, width: NotchPanel.leadingWingWidth)
                    Spacer(minLength: 0)
                    wing(trailingWing, width: NotchPanel.trailingWingWidth)
                }
                // Matches compactEdgeExtra: the panel is wider than the
                // wings by this per side, so content stays put as it grows.
                .padding(.horizontal, NotchPanel.compactEdgeExtra)
                .frame(height: neckHeight)
            }
            if let content {
                // Horizontal padding is the panel's visible side border;
                // keep in lockstep with the coordinator's measuring probe.
                content
                    .padding(.top, neckHeight + 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func wing(_ view: AnyView?, width: CGFloat) -> some View {
        Group {
            if let view { view } else { Color.clear }
        }
        .frame(width: width, height: neckHeight, alignment: .center)
    }
}
