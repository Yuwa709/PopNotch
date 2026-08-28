import SwiftUI

/// The expanded-notch silhouette: top edge flush with the screen top, concave
/// corners flaring into the menu bar, straight sides, convex rounded bottom
/// corners. The body is inset from the panel edges by `topRadius`; the flare
/// spans the full width at the very top.
///
/// Radii clamp to the available rect so the collapsed (exact-notch) size
/// stays drawable without artifacts.
struct NotchShape: Shape {

    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 12

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
        ZStack(alignment: .top) {
            NotchShape().fill(Color.black)
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
                .frame(height: neckHeight)
            }
            if let content {
                content
                    .padding(.top, neckHeight + 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
