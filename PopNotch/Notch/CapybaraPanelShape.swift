import SwiftUI

/// Sideways growth of the expanded silhouette beyond the body, per side, in
/// points. Zero on both sides is today's card; the panel frame, the content
/// padding and the chrome band all shift by exactly these so the body — and
/// everything laid out inside it — stays where it was on screen.
/// `nonisolated`: it is passed into the pure geometry functions, which are
/// themselves nonisolated so the tests can run them without a main actor.
nonisolated struct PanelSilhouetteInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    static let none = PanelSilhouetteInsets()
    var total: CGFloat { leading + trailing }
}

/// The capybara-themed expanded silhouette: today's card with a head grafted
/// onto its left side and a rounded back-and-rump onto its right, over a flat
/// underside. It strictly *contains* the `NotchShape` card it replaces, so the
/// artwork, scrub bar and lyrics neither move nor shrink — the lobes are added
/// outside the body, never carved out of it.
///
/// ## Derived from `capybaraLying`
///
/// Every curve is traced from the 61×40 1x rendition (alpha > 64, i.e. the
/// visually solid outline). The artwork's character lives entirely in its top
/// edge — forehead, ear, hump, rump — and its sides and belly are a near
/// rectangle; but the panel's top edge is the screen edge and the chrome band
/// lives in its top 32pt, so the back can only read on the sides. So:
///
/// - **Head** (left): the artwork's left-edge profile for rows 12–39, as
///   protrusion left of the crown column (col 12): forehead from 0 at row 12
///   to 12px at row 24, vertical snout rows 24–33, chin curving back to 6px at
///   the bottom row. Quadratics fitted to the measured rows (forehead control
///   at (6, 12) reproduces 9px at row 18; chin control at (11.5, 39)
///   reproduces 10px at row 37).
/// - **Back and rump** (right): the right-edge profile, as protrusion right
///   of col 54.5: shoulder from 0 at row 4.7 to 5.5px by row 19 (control
///   (3, 6) reproduces 3px at row 9), then vertical to the bottom with the
///   artwork's ~1.5px corner.
/// - **Vertical scale is exact**: the artwork's 40 rows map onto the body's
///   height, so the head tops out at 30% of the height and the shoulder
///   starts at 12%, as drawn. The body between them is the protected
///   rectangle, so horizontally the animal is stretched — a long loaf.
/// - **Top**: `NotchShape`'s own flare, untouched. The hump is flat in the
///   artwork (rows 0–2 for cols 25–49) and here it is the screen edge; the
///   panel still grows out of the notch.
///
/// Both lobes attach at the body's straight sides (inset `expandedTopRadius`
/// from the flare), so the frame grows by `protrusion − topRadius` per side.
struct CapybaraPanelShape: Shape {

    var insets: PanelSilhouetteInsets

    // Artwork units: pixels of the 1x rendition, rows from its top.
    nonisolated static let artworkRows: CGFloat = 40
    nonisolated static let headDepth: CGFloat = 12
    nonisolated static let foreheadTop: CGFloat = 12
    nonisolated static let snoutTop: CGFloat = 24
    nonisolated static let snoutBottom: CGFloat = 33
    nonisolated static let chinEnd: CGFloat = 6
    nonisolated static let rumpDepth: CGFloat = 5.5
    nonisolated static let shoulderTop: CGFloat = 4.7
    nonisolated static let shoulderEnd: CGFloat = 19
    nonisolated static let rumpCornerRadius: CGFloat = 1.5

    /// How far the frame must grow per side to hold the lobes, for a body of
    /// this height. Integral, rounded up: AppKit snaps fractional origins.
    nonisolated static func insets(bodyHeight: CGFloat) -> PanelSilhouetteInsets {
        let s = bodyHeight / artworkRows
        let r = NotchShape.expandedTopRadius
        return PanelSilhouetteInsets(
            leading: max(0, (headDepth * s - r).rounded(.up)),
            trailing: max(0, (rumpDepth * s - r).rounded(.up)))
    }

    func path(in rect: CGRect) -> Path {
        Self.outline(in: rect, insets: insets)
    }

    /// The silhouette in `rect`, whose body is `rect` less `insets`. Pure and
    /// `nonisolated` so the containment and hover tests exercise the exact
    /// geometry the view draws.
    nonisolated static func outline(in rect: CGRect, insets: PanelSilhouetteInsets) -> Path {
        let body = CGRect(x: rect.minX + insets.leading, y: rect.minY,
                          width: max(0, rect.width - insets.total), height: rect.height)
        let s = body.height / artworkRows
        let topR = min(NotchShape.expandedTopRadius, body.width / 4, body.height / 2)
        let top = body.minY, bottom = body.maxY
        let ls = body.minX + topR          // left straight side
        let rs = body.maxX - topR          // right straight side
        let neckY = top + max(foreheadTop * s, topR)
        let shoulderY = top + max(shoulderTop * s, topR)
        let shoulderCtrlY = max(top + 6 * s, shoulderY + 1)
        let rumpX = rs + rumpDepth * s
        let cornerR = max(0, min(rumpCornerRadius * s, (bottom - (top + shoulderEnd * s)) / 2))

        var p = Path()
        p.move(to: CGPoint(x: body.minX, y: top))
        // Left flare, as NotchShape draws it.
        p.addQuadCurve(to: CGPoint(x: ls, y: top + topR), control: CGPoint(x: ls, y: top))
        p.addLine(to: CGPoint(x: ls, y: neckY))
        // Forehead: crown to snout tip.
        p.addQuadCurve(to: CGPoint(x: ls - headDepth * s, y: top + snoutTop * s),
                       control: CGPoint(x: ls - headDepth * s / 2, y: neckY))
        // Snout: the face front.
        p.addLine(to: CGPoint(x: ls - headDepth * s, y: top + snoutBottom * s))
        // Chin, back to the underside.
        p.addQuadCurve(to: CGPoint(x: ls - chinEnd * s, y: bottom),
                       control: CGPoint(x: ls - 11.5 * s, y: top + 39 * s))
        // Flat underside.
        p.addLine(to: CGPoint(x: rumpX - cornerR, y: bottom))
        p.addQuadCurve(to: CGPoint(x: rumpX, y: bottom - cornerR),
                       control: CGPoint(x: rumpX, y: bottom))
        // Back end, vertical.
        p.addLine(to: CGPoint(x: rumpX, y: top + shoulderEnd * s))
        // Shoulder: the back curving in to the body.
        p.addQuadCurve(to: CGPoint(x: rs, y: shoulderY),
                       control: CGPoint(x: rs + 3 * s, y: shoulderCtrlY))
        p.addLine(to: CGPoint(x: rs, y: top + topR))
        // Right flare.
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: top), control: CGPoint(x: rs, y: top))
        p.closeSubpath()
        return p
    }

    // MARK: - Hover

    /// Horizontal slabs covering the silhouette plus its hover halo, in the
    /// panel frame's top-left space. `NSTrackingArea` is rectangular, so the
    /// outline is followed by stacking one area per slab: leaving the
    /// silhouette sideways now crosses a slab edge and fires `mouseExited`,
    /// where one bounds-sized area would fire nothing and hold the panel
    /// open from an empty corner. Slabs are supersets of their band of the
    /// path (widest sampled row, plus the halo), never subsets.
    nonisolated static func hoverSlabs(frameSize: CGSize, halo: CGFloat,
                                       insets: PanelSilhouetteInsets,
                                       count: Int = 20) -> [CGRect] {
        let frame = CGRect(origin: .zero, size: frameSize)
        let drawn = CGRect(x: halo, y: 0, width: frameSize.width - 2 * halo,
                           height: frameSize.height - halo)
        guard drawn.width > 0, drawn.height > 0, count > 0 else { return [frame] }
        let path = outline(in: drawn, insets: insets).cgPath
        let cx = drawn.minX + insets.leading + (drawn.width - insets.total) / 2
        let slabH = drawn.height / CGFloat(count)
        var slabs: [CGRect] = []
        for i in 0..<count {
            let t0 = drawn.minY + slabH * CGFloat(i)
            var left = CGFloat.greatestFiniteMagnitude
            var right = -CGFloat.greatestFiniteMagnitude
            let samples = 5
            for k in 0..<samples {
                let y = t0 + slabH * (CGFloat(k) + 0.5) / CGFloat(samples)
                guard path.contains(CGPoint(x: cx, y: y), using: .winding) else { continue }
                left = min(left, edge(of: path, atY: y, inside: cx, outside: drawn.minX - 1))
                right = max(right, edge(of: path, atY: y, inside: cx, outside: drawn.maxX + 1))
            }
            guard left <= right else { continue }
            var slab = CGRect(x: left - halo, y: t0, width: right - left + 2 * halo, height: slabH)
            if i == count - 1 { slab.size.height += halo }   // the halo below the underside
            slab = slab.intersection(frame)
            if !slab.isEmpty { slabs.append(slab) }
        }
        return slabs.isEmpty ? [frame] : slabs
    }

    /// The path's edge on one row, by bisection between a point known to be
    /// inside and one known to be outside. Every row of this shape is a
    /// single interval, so the crossing is unique.
    private nonisolated static func edge(of path: CGPath, atY y: CGFloat,
                                         inside: CGFloat, outside: CGFloat) -> CGFloat {
        var lo = outside, hi = inside
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if path.contains(CGPoint(x: mid, y: y), using: .winding) { hi = mid } else { lo = mid }
        }
        return hi
    }
}
