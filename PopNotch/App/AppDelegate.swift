import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppDelegate")

    private var notchPanel: NotchPanel?

    /// The screen the panel currently lives on. Set by reposition(reason:),
    /// read by the hover handler so expansion always targets the same screen
    /// the panel was placed on.
    private var currentScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("No target screen; panel not created")
            return
        }

        let panel = NotchPanel(screen: screen)
        panel.onHoverChange = { [weak self] hovering in
            guard let self, let screen = self.currentScreen else { return }
            panel.setExpanded(hovering, on: screen)
        }
        notchPanel = panel
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
    /// there, always in the collapsed state — a display change mid-hover
    /// invalidates the hover anyway. Called at launch and on every screen
    /// parameter change.
    private func reposition(reason: String) {
        guard let panel = notchPanel else { return }

        guard let screen = ScreenPolicy.targetScreen() else {
            // Transient during display reconfiguration; hide rather than
            // leave the panel stranded at coordinates that no longer exist.
            // The next notification re-evaluates and brings it back.
            Self.logger.error("Reposition (\(reason, privacy: .public)): no target screen; hiding panel")
            currentScreen = nil
            panel.orderOut(nil)
            return
        }

        currentScreen = screen
        let frame = NotchPanel.notchRect(on: screen)
        panel.setFrame(frame, display: true)

        // orderFrontRegardless, not orderFront: this background agent is never
        // the active app, and must never become it (hard rule 4).
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        Self.logger.notice("Reposition (\(reason, privacy: .public)): panel at \(NSStringFromRect(frame), privacy: .public) on \(screen.localizedName, privacy: .public)")
    }
}
