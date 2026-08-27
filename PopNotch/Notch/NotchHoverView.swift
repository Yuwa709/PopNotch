import AppKit
import os

/// Fills the notch panel and reports debounced hover state.
///
/// Entry is debounced: the cursor must dwell `enterDebounce` seconds before
/// hover reports true, so dragging across the top of the screen does not
/// constantly trigger it. Exit cancels a pending entry and reports
/// immediately.
final class NotchHoverView: NSView {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Hover")

    /// Middle of the 150–250ms range the roadmap prescribes. Tune on feel.
    private static let enterDebounce: TimeInterval = 0.2

    /// Fires on every debounced state change. Task 7 wires expansion here.
    var onHoverChange: ((Bool) -> Void)?

    private var isHovering = false
    private var pendingEnter: DispatchWorkItem?

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

    override func mouseEntered(with event: NSEvent) {
        pendingEnter?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            self.isHovering = true
            Self.logger.notice("Hover began")
            self.onHoverChange?(true)
        }
        pendingEnter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enterDebounce, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pendingEnter?.cancel()
        pendingEnter = nil
        guard isHovering else {
            // Exited before the debounce fired: a drive-by, deliberately
            // not reported. Logged at debug only; no forensic value.
            Self.logger.debug("Drive-by ignored")
            return
        }
        isHovering = false
        Self.logger.notice("Hover ended")
        onHoverChange?(false)
    }

    deinit {
        pendingEnter?.cancel()
    }
}
