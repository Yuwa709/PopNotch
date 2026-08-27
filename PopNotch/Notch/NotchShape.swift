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

/// What the panel hosts: the silhouette filled black.
///
/// Pure black for now — matching the physical bezel's black on an XDR panel
/// is task 8, user-verified by eye. The fill color is the single thing that
/// task will tune.
struct NotchOverlayView: View {
    var body: some View {
        NotchShape()
            .fill(Color.black)
            .ignoresSafeArea()
    }
}
