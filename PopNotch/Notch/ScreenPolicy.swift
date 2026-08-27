import AppKit
import os

/// The single place that decides which screen owns the notch panel.
///
/// Policy (ROADMAP Phase 1, task 4): the panel lives on the built-in display,
/// always, even when an external monitor is primary. Only when no built-in
/// display is available (clamshell mode) does it fall back to the main screen,
/// where `NotchPanel` draws its no-notch fallback strip.
enum ScreenPolicy {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "ScreenPolicy")

    static func targetScreen() -> NSScreen? {
        let builtIn = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }

        if let builtIn {
            logger.info("Target screen: built-in \(builtIn.localizedName, privacy: .public)")
            return builtIn
        }

        if let main = NSScreen.main {
            logger.info("No built-in display; falling back to main screen \(main.localizedName, privacy: .public)")
            return main
        }

        logger.error("No screens available")
        return nil
    }
}
