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
    /// Compact matches the physical housing's own corner tightness; the
    /// open card is much rounder, measured against the Sapphire reference.
    static let compactTopRadius: CGFloat = 8
    static let compactBottomRadius: CGFloat = 12
    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 34

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
    /// Play the emerge-from-the-notch entrance on this content.
    var revealContent: Bool = false
    /// Panel-level chrome for the expanded state, drawn in the band beside
    /// the housing. That band is free here: the wings that use it render
    /// only while compact, and these render only while expanded, so the two
    /// can never overlap. Leading holds navigation (clipboard, back);
    /// trailing holds caffeinate.
    var topLeadingAccessory: AnyView?
    var topTrailingAccessory: AnyView?
    /// The camera housing's x-range in this overlay's own coordinates
    /// (origin at the visible rect's leading edge). The chrome band is
    /// positioned from it: the leading group ends a gutter before
    /// `lowerBound`, the trailing group starts a gutter after `upperBound`,
    /// so no button can be laid out behind the housing, where it would be
    /// invisible and unclickable.
    ///
    /// A *clamp*, not an anchor: the groups hang off the panel's corners
    /// and are pushed inward only if they would otherwise reach the
    /// housing. Anchoring to the housing instead put the trailing group
    /// well inside the panel's trailing edge (user-observed 2026-09-01) —
    /// correct clearance, wrong place. The width floor is sized so the
    /// clamp never fires; `NotchCoordinator` logs at `.error` if it does.
    ///
    /// On a screen with no notch the coordinator derives this from the
    /// fallback strip, the app's stand-in for a housing.
    var housingLocalRange: ClosedRange<CGFloat> = 0...0
    /// The panel's visible width, and the measured chrome group widths:
    /// what `bandLayout` needs to place both groups from the corners in.
    var panelWidth: CGFloat = 0
    var chromeGroups = NotchPanel.ChromeGroupWidths()
    /// The panel is open but has nothing to show below the neck: the band
    /// is the only row. The content region must not render — its fixed
    /// neck+40 of padding survives even an empty view, inflates the root
    /// past the neck-height frame, and NSHostingView silently centres the
    /// overflow, shoving the band up under the screen edge (the clipped-
    /// buttons bug, measured 2026-09-01: root 82pt in a 42pt window).
    var chromeOnly: Bool = false
    /// Capybara theme: draw `CapybaraPanelShape` around the body instead of
    /// the card, and push the content column and the chrome band inward by
    /// `silhouetteInsets` so both stay on the body. Declared after
    /// `chromeOnly` so the memberwise initialiser's existing argument order
    /// is unchanged. Ignored for chrome-only and every collapsed state.
    var capybaraTheme: Bool = false
    var silhouetteInsets: PanelSilhouetteInsets = .none

    /// The panel's visible side border, used by the content column.
    ///
    /// Must stay in lockstep with the coordinator's measuring probe, which
    /// hardcodes the same 32 — they disagree and the measured panel no longer
    /// fits the rendered content.
    nonisolated static let contentSideInset: CGFloat = 32

    /// The chrome band sits nearer the corners than the content column does
    /// (user-requested). Its own constant rather than a smaller
    /// `contentSideInset`, because that one is pinned to the measuring probe
    /// and the band does not feed measurement at all.
    ///
    /// Floored by the corner: `expandedTopRadius` is 14, so anything below
    /// roughly 20 puts a 24pt control into the curve and clips it — the
    /// failure the old comment here recorded when this was tried at 2pt.
    nonisolated static let accessorySideInset: CGFloat = 24

    var body: some View {
        // Expanded (has content) draws the softer card; compact, idle and
        // the chrome-only bar keep the tighter silhouette — chrome-only is
        // neck-height, where the 34pt expanded bottom radius reads as a
        // blob rather than a bar.
        let expanded = content != nil
        let capybara = expanded && !chromeOnly && capybaraTheme
        let lobes = capybara ? silhouetteInsets : .none
        ZStack(alignment: .top) {
            if capybara {
                CapybaraPanelShape(insets: lobes)
                    .fill(Color.black)
            } else {
                NotchShape(
                    topRadius: expanded && !chromeOnly ? NotchShape.expandedTopRadius : NotchShape.compactTopRadius,
                    bottomRadius: expanded && !chromeOnly ? NotchShape.expandedBottomRadius : NotchShape.compactBottomRadius
                )
                .fill(Color.black)
            }
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
            if expanded, topLeadingAccessory != nil || topTrailingAccessory != nil {
                // Both groups hang off their own corner at the same inset —
                // the housing only pushes them in if they would otherwise
                // reach it, which the width floor prevents. See `bandLayout`.
                let band = Self.bandLayout(panelWidth: panelWidth,
                                           housingLocal: housingLocalRange,
                                           groups: chromeGroups,
                                           bodyInsets: lobes)
                HStack(spacing: 0) {
                    if let topLeadingAccessory { topLeadingAccessory }
                    Spacer(minLength: 0)
                    if let topTrailingAccessory { topTrailingAccessory }
                }
                .padding(.leading, band.leadingInset)
                .padding(.trailing, band.trailingInset)
                .frame(height: neckHeight)
            }
            if let content, !chromeOnly {
                // Horizontal padding is the panel's visible side border;
                // keep in lockstep with the coordinator's measuring probe.
                content
                    .padding(.top, neckHeight + 20)
                    .padding(.horizontal, Self.contentSideInset)
                    .padding(.bottom, 20)
                    // The lobes are outside the body: the column shifts by
                    // exactly their width so it stays put on screen. Zero,
                    // and so a no-op, whenever the card is drawn.
                    .padding(.leading, lobes.leading)
                    .padding(.trailing, lobes.trailing)
                    .modifier(RevealFromNotch(enabled: revealContent))
            }
        }
        // The hover halo: the panel frame is inflated by this margin, and
        // the drawing insets back, leaving transparent hover-sensitive
        // pixels around the silhouette. Top stays flush with the screen.
        .padding(.horizontal, NotchPanel.hoverMargin)
        .padding(.bottom, NotchPanel.hoverMargin)
        .ignoresSafeArea()
    }

    /// Breathing room the clamp keeps between a chrome group and the
    /// housing. 6pt: the buttons carry ~6pt of internal padding around
    /// their glyphs already, so the visible glyph-to-housing gap would read
    /// as ~12pt. Only reachable if the clamp fires, which the width floor
    /// is sized to prevent.
    nonisolated static let housingGutter: CGFloat = 6

    /// The band's keep-out span: the housing plus a gutter each side, in
    /// overlay-local x. Pure and `nonisolated` so the clearance tests
    /// exercise the exact geometry the view lays out, not a re-derivation.
    nonisolated static func bandGapRange(housingLocal: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        (housingLocal.lowerBound - housingGutter)...(housingLocal.upperBound + housingGutter)
    }

    /// Where each chrome group sits, as insets from its own panel edge.
    ///
    /// Both default to `accessorySideInset`, mirrored — the band reads as
    /// belonging to the panel's corners, and the two sides are visibly
    /// equidistant. The housing is a clamp on top of that: a group is
    /// pushed inward only if it would otherwise come within
    /// `housingGutter` of the camera, where it would be invisible.
    ///
    /// `NotchPanel.expandedRect`'s width floor is derived so that neither
    /// clamp can fire in any expanded state; the coordinator logs at
    /// `.error` if one does, because that means the floor and this
    /// function have drifted apart.
    struct BandLayout: Equatable {
        var leadingInset: CGFloat
        var trailingInset: CGFloat
        var leadingClamped = false
        var trailingClamped = false
        var isClamped: Bool { leadingClamped || trailingClamped }
    }

    /// `bodyInsets` is the capybara silhouette's sideways growth: the groups
    /// hang off the *body's* corners, not the lobes', so each base inset
    /// grows by its side's lobe. Zero for the card, which leaves every
    /// number below exactly as it was.
    nonisolated static func bandLayout(panelWidth: CGFloat,
                                       housingLocal: ClosedRange<CGFloat>,
                                       groups: NotchPanel.ChromeGroupWidths,
                                       bodyInsets: PanelSilhouetteInsets = .none) -> BandLayout {
        let gap = bandGapRange(housingLocal: housingLocal)
        let leadingBase = accessorySideInset + bodyInsets.leading
        let trailingBase = accessorySideInset + bodyInsets.trailing
        var layout = BandLayout(leadingInset: leadingBase,
                                trailingInset: trailingBase)

        if leadingBase + groups.leading > gap.lowerBound {
            layout.leadingInset = max(0, gap.lowerBound - groups.leading)
            layout.leadingClamped = true
        }
        let trailingGroupMinX = panelWidth - trailingBase - groups.trailing
        if trailingGroupMinX < gap.upperBound {
            layout.trailingInset = max(0, panelWidth - gap.upperBound - groups.trailing)
            layout.trailingClamped = true
        }
        return layout
    }

    @ViewBuilder
    private func wing(_ view: AnyView?, width: CGFloat) -> some View {
        Group {
            if let view { view } else { Color.clear }
        }
        .frame(width: width, height: neckHeight, alignment: .center)
    }
}

/// The entrance for expanded content: pulled out of the notch with the
/// panel's own growth — scaling from the top center — with a fast fade and
/// a settling blur standing in for motion blur. Timed to the expand
/// animation so content and silhouette move as one.
private struct RevealFromNotch: ViewModifier {
    let enabled: Bool
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(revealed || !enabled ? 1 : 0.55, anchor: .top)
            .opacity(revealed || !enabled ? 1 : 0)
            .blur(radius: revealed || !enabled ? 0 : 14)
            .onAppear {
                guard enabled, !revealed else { return }
                // Faster than the panel's expand+settle (0.34s total), so
                // content is locked in before the silhouette is.
                withAnimation(.easeOut(duration: 0.17)) {
                    revealed = true
                }
            }
    }
}
