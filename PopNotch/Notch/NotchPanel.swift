import AppKit
import SwiftUI
import os

/// A borderless panel that sits directly over the camera notch.
///
/// The three properties that make the overlay work at all:
/// - `styleMask` includes `.nonactivatingPanel` so interacting with the panel
///   never pulls focus from the frontmost app
/// - `level` is one step above the main menu bar so the panel draws over it
/// - `canBecomeKey` is false so the panel can never become the key window
@MainActor
final class NotchPanel: NSPanel {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "NotchPanel")

    override var canBecomeKey: Bool { false }

    init(screen: NSScreen) {
        let notchRect = Self.notchRect(on: screen)
        super.init(
            contentRect: notchRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

        // The third property the overlay depends on, alongside level and
        // styleMask. Without these the panel vanishes on Space switch
        // (.canJoinAllSpaces), disappears under fullscreen apps
        // (.fullScreenAuxiliary), and moves during Exposé transitions
        // (.stationary).
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Transparent panel; the SwiftUI shape draws the visible silhouette.
        // (The development-era solid red is gone with the verification lip.)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // NSPanel defaults this to true, which would hide the overlay whenever
        // this background agent resigns active — it must stay up permanently.
        hidesOnDeactivate = false

        let hoverView = NotchHoverView()
        let hosting = NSHostingView(rootView: NotchOverlayView(neckHeight: notchRect.height))
        hosting.frame = hoverView.bounds
        hosting.autoresizingMask = [.width, .height]
        hoverView.addSubview(hosting)
        hostingView = hosting
        contentView = hoverView

        setFrame(notchRect, display: false)
    }

    /// Retained so the coordinator can swap what the notch displays without
    /// rebuilding the panel.
    private var hostingView: NSHostingView<NotchOverlayView>?

    /// Tracked so the haptic fires only on the transition into expanded.
    private var currentState: State = .idle

    /// Replaces the notch's contents. All nil shows the bare silhouette.
    /// `reveal` plays the emerge-from-the-notch entrance — pass true only on
    /// the transition into expanded, not on content updates mid-display.
    func setContent(
        _ content: AnyView?,
        leadingWing: AnyView? = nil,
        trailingWing: AnyView? = nil,
        neckHeight: CGFloat,
        reveal: Bool = false
    ) {
        hostingView?.rootView = NotchOverlayView(
            content: content,
            leadingWing: leadingWing,
            trailingWing: trailingWing,
            neckHeight: neckHeight,
            revealContent: reveal
        )
    }

    /// Seconds the cursor must dwell before hover reports true.
    var hoverEnterDelay: TimeInterval {
        get { (contentView as? NotchHoverView)?.enterDebounce ?? 0.35 }
        set { (contentView as? NotchHoverView)?.enterDebounce = newValue }
    }

    /// Debounced hover state from the tracking view. Task 7 wires
    /// expand/collapse here.
    var onHoverChange: ((Bool) -> Void)? {
        get { (contentView as? NotchHoverView)?.onHoverChange }
        set { (contentView as? NotchHoverView)?.onHoverChange = newValue }
    }

    /// The notch's frame in screen coordinates, derived from the gap between
    /// the auxiliary top-left and top-right areas. Falls back to a centered
    /// strip on screens without a notch so development on external displays
    /// still shows something.
    static func notchRect(on screen: NSScreen) -> NSRect {
        let topInset = screen.safeAreaInsets.top

        guard topInset > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea
        else {
            let fallbackSize = NSSize(width: 200, height: 32)
            let fallbackRect = NSRect(
                x: screen.frame.midX - fallbackSize.width / 2,
                y: screen.frame.maxY - fallbackSize.height,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
            logger.notice("No notch on screen \(screen.localizedName, privacy: .public); using fallback rect \(NSStringFromRect(fallbackRect), privacy: .public)")
            return fallbackRect
        }

        // The gap between the auxiliary areas is not guaranteed symmetric —
        // on a 15" Air it measures 1pt wider on the right, which is visible
        // as a 2px overhang on Retina. The camera housing itself is always
        // centered, so symmetrize around midX using the tighter side.
        //
        // Then inset per side: user-verified on hardware that even the
        // symmetrized rect overhangs the housing by a pixel. Rule: always
        // undershoot — an edge inside the housing sits in the deadzone and
        // is invisible, an edge outside paints live pixels. A full point,
        // not half: AppKit snaps fractional window origins to integers,
        // which silently shifts the panel off the computed rect.
        let horizontalInset: CGFloat = 1.0
        let center = screen.frame.midX
        let halfWidth = min(center - leftArea.maxX, rightArea.minX - center) - horizontalInset
        let notchRect = NSRect(
            x: center - halfWidth,
            y: screen.frame.maxY - topInset,
            width: halfWidth * 2,
            height: topInset
        )
        logger.notice("Computed notch rect \(NSStringFromRect(notchRect), privacy: .public) on screen \(screen.localizedName, privacy: .public) (auxiliary gap: \(leftArea.maxX, privacy: .public)...\(rightArea.minX, privacy: .public), safeAreaInsets.top: \(topInset, privacy: .public))")
        return notchRect
    }

    // MARK: - States

    /// The three sizes the panel occupies.
    enum State: String {
        /// Exactly the notch: invisible, the at-rest state.
        case idle
        /// Menu-bar-height wings flanking the housing — the "something is
        /// playing" indicator. Costs menu bar coverage on both sides; that
        /// trade-off is deliberate and shared by every notch app.
        case compact
        /// The open panel.
        case expanded
    }

    /// Wing widths, tuned by eye on hardware across four rounds. Asymmetric
    /// on purpose: with equal wings the right side consistently read as
    /// wider than the left (user-confirmed twice) — the housing does not
    /// sit perfectly on the panel's center — so the left wing carries a few
    /// extra points to balance the appearance.
    static let leadingWingWidth: CGFloat = 48
    static let trailingWingWidth: CGFloat = 44

    /// The physical housing reads about 2pt left of the geometric screen
    /// center on this machine — confirmed independently in the compact state
    /// (equal wings looked right-heavy; +4 left balanced them) and the
    /// expanded state (right of the housing obviously wider). Anything that
    /// centers on the screen applies this to center on the *housing*.
    static let opticalCenterOffset: CGFloat = -2

    /// Invisible hover halo: every state's frame extends this far beyond the
    /// visible silhouette (sides and below; the top is the screen edge), so
    /// the notch snaps open when the cursor gets near, not only dead-on.
    /// The overlay insets its drawing to match. Transparent pixels do not
    /// capture clicks, so the halo steals nothing from the menu bar.
    static let hoverMargin: CGFloat = 10

    /// Extra black beyond the wings at each end of the compact panel —
    /// user-requested breathing room. The wing slots are inset by the same
    /// amount in the overlay, so widening this moves no content.
    static let compactEdgeExtra: CGFloat = 2

    static func compactRect(on screen: NSScreen) -> NSRect {
        let base = notchRect(on: screen)
        return NSRect(
            x: base.minX - leadingWingWidth - compactEdgeExtra,
            y: base.minY,
            width: base.width + leadingWingWidth + trailingWingWidth + compactEdgeExtra * 2,
            height: base.height
        )
    }

    /// The hovered frame, sized by what it will display: the coordinator
    /// measures the content and passes its size, so a player-only panel is
    /// snug and a player-plus-stats panel is taller — no guessed constants
    /// leaving voids (user-verified problem when stats were toggled off).
    ///
    /// Clamps keep degenerate measurements from producing a sliver or a
    /// window-sized slab, and coordinates stay integral: AppKit snaps
    /// fractional origins, which desyncs the computed and actual frames.
    static func expandedRect(on screen: NSScreen, contentSize: CGSize) -> NSRect {
        let base = notchRect(on: screen)
        let minWidth = base.width + (leadingWingWidth + 24) * 2
        let width = (min(max(contentSize.width, minWidth), 540)).rounded(.up)
        let minHeight = base.height + 56
        // Ceiling raised from 300: the lyrics takeover needs more, and
        // clamping below the content's real height compressed it upward
        // (badge slid under the bezel) and spilled it past the rounded
        // silhouette, where the square window edge cut it into a hard box.
        let height = (min(max(contentSize.height, minHeight), 460)).rounded(.up)
        return NSRect(
            x: (screen.frame.midX + opticalCenterOffset - width / 2).rounded(),
            y: base.maxY - height,
            width: width,
            height: height
        )
    }

    /// Animates the panel frame to a state's rect. Resizes the panel itself,
    /// not the inner view — the hosting view and tracking area follow via
    /// autoresizing and updateTrackingAreas.
    func setState(_ state: State, on screen: NSScreen, expandedContentSize: CGSize = .zero) {
        let visible: NSRect
        switch state {
        case .idle: visible = Self.notchRect(on: screen)
        case .compact: visible = Self.compactRect(on: screen)
        case .expanded: visible = Self.expandedRect(on: screen, contentSize: expandedContentSize)
        }
        // Inflate by the hover halo: sides and downward, top stays flush.
        var target = visible
        target.origin.x -= Self.hoverMargin
        target.size.width += Self.hoverMargin * 2
        target.origin.y -= Self.hoverMargin
        target.size.height += Self.hoverMargin

        let wasExpanded = currentState == .expanded
        currentState = state
        // The trackpad ticks as the notch snaps open — only on the way in,
        // and only when the hand is on the trackpad (the system's rule).
        if state == .expanded && !wasExpanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }

        guard target != frame else { return }

        // Hard rule 8: with Reduce Motion on, snap instead of animating.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setFrame(target, display: true)
            Self.logger.notice("State \(state.rawValue, privacy: .public) (reduced motion) at \(NSStringFromRect(target), privacy: .public)")
            return
        }

        if state == .expanded {
            // Two-stage bounce: overshoot past the target in BOTH axes, then
            // settle back. Explicit stages because window-frame animation
            // clamps overshooting timing curves (control-point y > 1 was
            // silently flattened — user never felt the bounce it promised).
            // The sideways component of the overshoot is what makes opening
            // read as blooming outward, not just dropping down.
            // User-tuned subtle: half the first attempt's travel.
            var overshoot = target
            overshoot.origin.x -= 4
            overshoot.size.width += 8
            overshoot.origin.y -= 5
            overshoot.size.height += 5

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.21
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.90, 0.45, 1.0)
                self.animator().setFrame(overshoot, display: true)
            }, completionHandler: { [weak self] in
                // AppKit invokes animation completions on the main thread;
                // assumeIsolated states that fact to the compiler (and traps
                // if it were ever violated) without deferring a runloop turn
                // the way Task would — the settle must start this tick or
                // the bounce reads as a hitch.
                MainActor.assumeIsolated {
                    guard let self, self.currentState == .expanded else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.13
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        self.animator().setFrame(target, display: true)
                    }
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup { context in
                // Closing and wing transitions ease out with no bounce so
                // they read as tidy.
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.30, 0.90, 0.55, 1.0)
                animator().setFrame(target, display: true)
            }
        }
        Self.logger.notice("State \(state.rawValue, privacy: .public) at \(NSStringFromRect(target), privacy: .public)")
    }
}
