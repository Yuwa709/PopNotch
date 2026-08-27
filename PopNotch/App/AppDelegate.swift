import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppDelegate")

    /// TEMPORARY, remove with Phase 1 task 6 (expand/collapse animation).
    /// The notch rect is exactly the camera housing's deadzone, so a panel
    /// that fits it perfectly is invisible on a real MacBook. Extending the
    /// frame this many points below the menu bar leaves a visible red lip —
    /// the only way the user can confirm position before hover exists.
    private static let verificationLip: CGFloat = 4

    private var notchPanel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = ScreenPolicy.targetScreen() else {
            Self.logger.error("No target screen; panel not created")
            return
        }

        let panel = NotchPanel(screen: screen)

        var frame = panel.frame
        frame.origin.y -= Self.verificationLip
        frame.size.height += Self.verificationLip
        panel.setFrame(frame, display: true)

        // orderFrontRegardless, not orderFront: this background agent is never
        // the active app, and must never become it (hard rule 4).
        panel.orderFrontRegardless()
        notchPanel = panel

        Self.logger.info("Panel ordered front at \(NSStringFromRect(frame), privacy: .public) on \(screen.localizedName, privacy: .public)")
    }
}
