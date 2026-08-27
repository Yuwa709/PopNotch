import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppDelegate")

    /// TEMPORARY, remove with Phase 1 task 7 (expand/collapse animation).
    /// The notch rect is exactly the camera housing's deadzone, so a panel
    /// that fits it perfectly is invisible on a real MacBook. Extending the
    /// frame this many points below the menu bar leaves a visible red lip —
    /// the only way the user can confirm position before hover exists.
    private static let verificationLip: CGFloat = 3

    private var notchPanel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("No target screen; panel not created")
            return
        }

        notchPanel = NotchPanel(screen: screen)
        reposition(reason: "launch")

        // Fires on monitor plug/unplug, resolution change, lid close/open,
        // and Dock/menu bar changes. Recompute everything on every fire;
        // stale geometry here is where most notch apps break.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        reposition(reason: "screen parameters changed")
    }

    /// Recomputes the target screen and notch geometry, then moves the panel
    /// there. Called at launch and on every screen parameter change.
    private func reposition(reason: String) {
        guard let panel = notchPanel else { return }

        guard let screen = ScreenPolicy.targetScreen() else {
            // Transient during display reconfiguration; hide rather than
            // leave the panel stranded at coordinates that no longer exist.
            // The next notification re-evaluates and brings it back.
            Self.logger.error("Reposition (\(reason, privacy: .public)): no target screen; hiding panel")
            panel.orderOut(nil)
            return
        }

        var frame = NotchPanel.notchRect(on: screen)
        frame.origin.y -= Self.verificationLip
        frame.size.height += Self.verificationLip
        panel.setFrame(frame, display: true)

        // orderFrontRegardless, not orderFront: this background agent is never
        // the active app, and must never become it (hard rule 4).
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        Self.logger.notice("Reposition (\(reason, privacy: .public)): panel at \(NSStringFromRect(frame), privacy: .public) on \(screen.localizedName, privacy: .public)")
    }
}
