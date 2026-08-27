import AppKit
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

        isOpaque = true
        backgroundColor = .red
        hasShadow = false
        isMovable = false
        // NSPanel defaults this to true, which would hide the overlay whenever
        // this background agent resigns active — it must stay up permanently.
        hidesOnDeactivate = false

        contentView = NotchHoverView()

        setFrame(notchRect, display: false)
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
}
