import AppKit
import os

/// Fills the notch panel and reports debounced hover state.
///
/// Entry is debounced: the cursor must dwell `enterDebounce` seconds before
/// hover reports true, so passing traffic across the top of the screen does
/// not trigger it. Exit is verified: the panel resizes underneath the cursor
/// while animating, which makes AppKit fire spurious mouseExited events —
/// an exit only counts if the cursor is really outside the panel frame
/// `exitGrace` later.
final class NotchHoverView: NSView {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Hover")

    /// User-tuned: 200ms let too much passing traffic through. Overridable
    /// from settings via `NotchPanel.hoverEnterDelay`.
    var enterDebounce: TimeInterval = 0.35
    private static let exitGrace: TimeInterval = 0.1

    /// Fires on every debounced state change.
    var onHoverChange: ((Bool) -> Void)?

    private var isHovering = false
    private var pendingEnter: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?

    // Tracking areas do not follow a resized or moved window. AppKit calls
    // this on every geometry change, so rebuilding here keeps the area
    // matched to the panel wherever reposition() puts it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    /// Whether the cursor still counts as over the panel, for the purpose of
    /// confirming an exit.
    ///
    /// `NSRect.contains` is half-open on maxY, and this panel's top edge sits
    /// flush with the screen's maxY. A cursor pinned to the top screen edge
    /// therefore reports `y == maxY` and reads as *outside* in every panel
    /// state, at every size — measured 2026-08-29: enter fired with
    /// `contains=false`, the panel expanded, the verification agreed the
    /// cursor was outside, and it collapsed straight back, oscillating on a
    /// ~320ms cycle one pixel row from the top.
    ///
    /// The enter path uses the tracking area, which is inclusive at its edge;
    /// this test was exclusive. Closing that one-row disagreement is the
    /// entire fix. Nothing is widened downward or sideways: the x test keeps
    /// `contains`'s own half-open semantics, and the y extension reaches only
    /// from the panel's top to the screen's, which is normally the same row.
    nonisolated static func isInsideForExit(mouse: NSPoint,
                                            panel: NSRect,
                                            screenTop: CGFloat) -> Bool {
        if panel.contains(mouse) { return true }
        return mouse.x >= panel.minX && mouse.x < panel.maxX
            && mouse.y >= panel.maxY && mouse.y <= screenTop
    }

    override func mouseEntered(with event: NSEvent) {
        // Re-entry cancels a pending exit — the cursor never really left.
        pendingExit?.cancel()
        pendingExit = nil
        guard !isHovering else { return }

        pendingEnter?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            self.isHovering = true
            Self.logger.notice("Hover began")
            self.onHoverChange?(true)
        }
        pendingEnter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDebounce, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pendingEnter?.cancel()
        pendingEnter = nil
        guard isHovering else { return }

        // Verify before collapsing: mid-animation resizes fire exits even
        // though the cursor is still over the panel.
        pendingExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovering, let window = self.window else { return }
            // The screen the panel is on; falling back to the panel's own top
            // still closes the exact-maxY case, which is the one that breaks.
            let screenTop = window.screen?.frame.maxY ?? window.frame.maxY
            guard !Self.isInsideForExit(mouse: NSEvent.mouseLocation,
                                        panel: window.frame,
                                        screenTop: screenTop) else {
                Self.logger.debug("Spurious exit ignored; cursor still inside panel")
                return
            }
            self.isHovering = false
            Self.logger.notice("Hover ended")
            self.onHoverChange?(false)
        }
        pendingExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: work)
    }

    deinit {
        pendingEnter?.cancel()
        pendingExit?.cancel()
    }
}
