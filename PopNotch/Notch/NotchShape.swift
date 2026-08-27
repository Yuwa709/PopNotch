import SwiftUI

/// The expanded-notch silhouette, anchored at the notch corners.
///
/// Through the menu bar band (`neckHeight`) the shape stays exactly as wide
/// as the notch — the neck — with small concave fillets where it meets the
/// screen top. Below the menu bar it flares smoothly outward to the full
/// panel width, then closes with convex rounded bottom corners. Expansion
/// therefore reads as downward growth from the notch's own corners, never
/// as sideways growth along the menu bar.
///
/// At collapsed size (height == neckHeight) the flare degenerates and the
/// path reduces to the plain anchored silhouette, so animation morphs
/// smoothly between the two.
struct NotchShape: Shape {

    /// Shared with NotchPanel.expandedRect so the neck lands exactly on the
    /// notch edges: the panel widens beyond the notch by topRadius + flare
    /// per side, and the shape insets the same amounts back.
    static let defaultTopRadius: CGFloat = 8
    static let defaultBottomRadius: CGFloat = 12
    static let defaultFlare: CGFloat = 28

    var topRadius: CGFloat = NotchShape.defaultTopRadius
    var bottomRadius: CGFloat = NotchShape.defaultBottomRadius
    var flare: CGFloat = NotchShape.defaultFlare
    /// The menu bar / notch height on the current screen; the region that
    /// stays neck-width.
    var neckHeight: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        let topR = min(topRadius, rect.width / 4, rect.height / 2)
        let botR = min(bottomRadius, rect.width / 4, rect.height / 2)

        let spaceBelowNeck = rect.height - neckHeight
        guard spaceBelowNeck > 1 else {
            return neckOnlyPath(in: rect, topR: topR, botR: botR)
        }

        // Flare and junction grow with available space so intermediate
        // animation frames stay well-formed.
        let f = min(flare, spaceBelowNeck)
        let junctionDrop = min(14, spaceBelowNeck / 2)
        let neckL = rect.minX + f + topR
        let neckR = rect.maxX - f - topR
        let bodyTop = neckHeight + junctionDrop

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + f, y: rect.minY))
        // Concave fillet from screen top into the left neck side.
        p.addQuadCurve(
            to: CGPoint(x: neckL, y: rect.minY + topR),
            control: CGPoint(x: neckL, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: neckL, y: neckHeight))
        // Flare outward below the menu bar to the full panel width.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyTop),
            control: CGPoint(x: neckL, y: bodyTop)
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - botR))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - botR, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: bodyTop))
        // Mirror flare back into the right neck side.
        p.addQuadCurve(
            to: CGPoint(x: neckR, y: neckHeight),
            control: CGPoint(x: neckR, y: bodyTop)
        )
        p.addLine(to: CGPoint(x: neckR, y: rect.minY + topR))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - f, y: rect.minY),
            control: CGPoint(x: neckR, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }

    /// The collapsed silhouette: no flare, body inset by the top fillet.
    private func neckOnlyPath(in rect: CGRect, topR: CGFloat, botR: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - botR))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + botR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR - botR, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - botR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
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
/// The fill measures #000000 at the window buffer — the darkest displayable
/// value. Solid, no stroke, no effects; any residual mismatch against the
/// bezel is LCD backlight, not color.
struct NotchOverlayView: View {
    var neckHeight: CGFloat

    var body: some View {
        NotchShape(neckHeight: neckHeight)
            .fill(Color.black)
            .ignoresSafeArea()
    }
}
