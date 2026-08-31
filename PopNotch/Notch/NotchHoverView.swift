import AppKit
import os

/// Fills the notch panel and reports debounced hover state, from the cursor
/// or from a file drag.
///
/// Entry is debounced: the cursor must dwell `enterDebounce` seconds before
/// hover reports true, so passing traffic across the top of the screen does
/// not trigger it. Exit is verified: the panel resizes underneath the cursor
/// while animating, which makes AppKit fire spurious mouseExited events —
/// an exit only counts if the cursor is really outside the panel frame
/// `exitGrace` later.
///
/// A file drag opens the notch through exactly the same debounced path. A
/// tracking area sees only the pointer, and during a drag session AppKit
/// delivers dragging messages instead of mouse-entered ones, so without this
/// the panel stays shut and the shelf's drop zones are unreachable — there
/// is no way to drop a file into a panel that will not open. Routing drags
/// through `beginEnter`/`beginExit` rather than a parallel mechanism is what
/// keeps the debounce, the exit verification and the top-edge fix applying
/// identically to both.
final class NotchHoverView: NSView {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Hover")

    /// User-tuned: 200ms let too much passing traffic through. Overridable
    /// from settings via `NotchPanel.hoverEnterDelay`.
    var enterDebounce: TimeInterval = 0.35
    private static let exitGrace: TimeInterval = 0.1

    /// Fires on every debounced state change.
    var onHoverChange: ((Bool) -> Void)?

    /// Fires the instant a file drag arrives over the notch, and again when
    /// it leaves — ahead of the debounced expansion, so a listener can choose
    /// what the panel should open *to* before it opens.
    ///
    /// Separate from `onHoverChange` on purpose: a pointer and a file
    /// arriving are different intents, and the panel should answer them
    /// differently. Folding this into the hover callback would make every
    /// listener re-derive which one happened.
    var onFileDragChange: ((Bool) -> Void)?

    private var isHovering = false
    private var pendingEnter: DispatchWorkItem?
    private var pendingExit: DispatchWorkItem?
    /// True between a file drag entering and leaving, so the exit path is
    /// only driven once per session however AppKit reports the ending.
    private var isDragActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // File URLs only. Registering for everything would open the notch on
        // a text selection dragged across the menu bar.
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

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
        beginEnter(fromDrag: false)
    }

    /// The one way the notch opens, whether the pointer or a file arrived.
    private func beginEnter(fromDrag: Bool) {
        // Re-entry cancels a pending exit — the cursor never really left.
        pendingExit?.cancel()
        pendingExit = nil
        guard !isHovering else { return }

        pendingEnter?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovering else { return }
            self.isHovering = true
            Self.logger.notice("\(fromDrag ? "Drag expanded the notch" : "Hover began", privacy: .public)")
            self.onHoverChange?(true)
        }
        pendingEnter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + enterDebounce, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        beginExit()
    }

    private func beginExit() {
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

    // MARK: - Dragging destination

    /// A file drag arriving over the collapsed notch opens it, so the
    /// shelf's drop zones become reachable.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.carriesFiles(sender) else { return [] }
        isDragActive = true
        Self.logger.notice("Drag entered the notch")
        // Announced before the expansion is scheduled, so the destination is
        // already chosen by the time the panel opens.
        onFileDragChange?(true)
        beginEnter(fromDrag: true)
        // `.copy` keeps the session tracking us so `draggingExited` arrives.
        // It does not mean this view will take the drop: that is refused
        // below, leaving the expanded content's own zones to accept it.
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrag(reason: "exited")
    }

    /// Belt and braces: a session that ends by dropping elsewhere, or is
    /// cancelled, may not send `draggingExited`. Without this the notch
    /// would stay open until the pointer happened to leave.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag(reason: "ended")
    }

    private func endDrag(reason: String) {
        guard isDragActive else { return }
        isDragActive = false
        Self.logger.notice("Drag \(reason, privacy: .public); collapsing by the normal exit rules")
        onFileDragChange?(false)
        // The same verified, grace-delayed exit the pointer uses, so the
        // top-edge fix and the spurious-exit guard apply unchanged.
        beginExit()
    }

    /// This view never consumes a drop. It exists to open the panel; the
    /// shelf's own zones, which sit above it once expanded, do the accepting.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    static func carriesFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}
