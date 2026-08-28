import AppKit
import os

/// Thin by design: it owns the app's long-lived objects and nothing else.
/// Panel placement, hover, arbitration, and expiry all live in
/// `NotchCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppDelegate")

    let settings = SettingsStore()
    private(set) lazy var coordinator = NotchCoordinator(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()

        // Modules register here, one line each. Phase 3 and 4 add real ones;
        // until then the notch shows its silhouette and nothing else.
        Self.logger.notice("Launched with \(0, privacy: .public) modules registered")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
