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
    private(set) lazy var spotifyAccount = SpotifyAccount(settings: settings)
    private let statsService = SystemStatsService()
    /// App-level, not media-level: keeping the Mac awake has nothing to do
    /// with playback. MediaModule only holds a reference so the control can
    /// live in the expanded notch, the same way it holds the Spotify account.
    private(set) lazy var caffeinate = CaffeinateService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()

        // Modules register here, one line each — the Phase 2 goal made real.
        // Order is not precedence: MediaModule arbitrates by what is actually
        // playing. See MediaModule.shouldTakeOver(_:from:).
        let media = MediaModule(sources: [SpotifyAdapter(), MusicAdapter()], account: spotifyAccount, caffeinate: caffeinate)
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
        // Deterministic on a clean quit. The system would reclaim the
        // assertion on exit anyway (verified with SIGKILL), but releasing
        // here means it goes the moment the user quits rather than whenever
        // the process finishes tearing down.
        caffeinate.release()
    }
}
