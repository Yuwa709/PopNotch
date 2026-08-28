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
    private let statsService = SystemStatsService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()

        // Modules register here, one line each — the Phase 2 goal made real.
        let modules: [any NotchModule] = [
            SystemStatsModule(service: statsService)
        ]
        for module in modules {
            module.isEnabled = settings.isEnabled(module.id, default: true)
            coordinator.register(module)
        }

        Self.logger.notice("Launched with \(modules.count, privacy: .public) modules registered")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
