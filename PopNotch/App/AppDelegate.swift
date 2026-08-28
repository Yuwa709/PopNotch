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
        let media = MediaModule(sources: [SpotifyAdapter()])
        media.onLiveActivityRequest = { [weak self] request in
            self?.coordinator.requestLiveActivity(request)
        }
        media.onPresenceChange = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        media.onContentReflow = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        let modules: [any NotchModule] = [
            media,
            SystemStatsModule(service: statsService)
        ]
        // register() applies the stored preference itself, so a module can
        // never start in a state that disagrees with the user's choice.
        modules.forEach { coordinator.register($0) }

        Self.logger.notice("Launched with \(modules.count, privacy: .public) modules registered")
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
