import AppKit
import SwiftUI
import Sparkle
import os

/// Thin by design: it owns the app's long-lived objects and nothing else.
/// Panel placement, hover, arbitration, and expiry all live in
/// `NotchCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppDelegate")

    let settings = SettingsStore()
    /// Session-only; see PinState. Held here so the menu bar and the panel
    /// chrome read the same flag.
    let pinState = PinState()
    private(set) lazy var coordinator = NotchCoordinator(
        settings: settings, caffeinate: caffeinate, audioVisualizer: audioViz,
        pinState: pinState, statsPage: statsPage)
    /// Given the settings store so launch reads the cached connected flag
    /// instead of the Keychain.
    private(set) lazy var spotifyAccount = SpotifyAccount(settings: settings)
    private let statsService = SystemStatsService()
    /// The stats page's own data layer. Both hold no timer until the page
    /// opens — the coordinator starts and stops them on the destination —
    /// so creating them here costs nothing at launch.
    private let batteryService = BatteryService()
    private lazy var statsHistory = SystemStatsHistory(stats: statsService,
                                                       battery: batteryService)
    private lazy var statsPage = NotchCoordinator.StatsPageServices(
        stats: statsService, battery: batteryService, history: statsHistory)
    private let clipboardService = ClipboardService()
    private let fileShelfService = FileShelfService()
    /// App-level. The control renders as panel chrome via the coordinator,
    /// so no module needs to know about it.
    private(set) lazy var caffeinate = CaffeinateService()

    /// Panel-level, like caffeinate: enabled from the stored setting, made
    /// visible by the coordinator only while the panel is expanded.
    private(set) lazy var audioViz = AudioVisualizerService()

    /// The system now-playing source, held only so the music-over-video
    /// preference can be applied live from Settings. MediaModule owns it as
    /// one of its sources; this is a reference, not ownership.
    private(set) var systemMediaSource: SystemMediaAdapter?

    /// The media sources to register, honouring `SystemMediaAdapter.isRegistered`.
    ///
    /// Split out so the flag is consulted in exactly one place rather than
    /// being encoded as a literal array that someone has to remember to edit.
    private func mediaSources(includingSystem system: SystemMediaAdapter) -> [any MediaSource] {
        var sources: [any MediaSource] = [SpotifyAdapter(), MusicAdapter()]
        if SystemMediaAdapter.isRegistered { sources.append(system) }
        return sources
    }

    // MARK: - Updates

    /// Sparkle's updater, owned here because it must outlive any view.
    ///
    /// **Manual checks only** — `startingUpdater: true` starts the updater so
    /// a check can be requested, and `automaticallyChecksForUpdates` is forced
    /// off in `applicationDidFinishLaunching`. Scheduled background checks are
    /// deliberately not enabled: Sparkle logs a specific warning for
    /// `LSUIElement` apps that schedule them without implementing gentle
    /// reminders, because an update alert behind other windows is easy to miss
    /// when there is no Dock icon to bounce. Turning them on is a separate
    /// decision that owes the user a visible surface — most likely the notch.
    ///
    /// Both delegates are nil: the feed URL and public key come from
    /// `PopNotch/Info.plist` (`SUFeedURL`, `SUPublicEDKey`), and the standard
    /// user driver's own UI is what we want.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Whether a check can be started right now. The About tab's button binds
    /// to this so it disables while one is already running.
    var canCheckForUpdates: Bool { updaterController.updater.canCheckForUpdates }

    /// User-initiated check. Sparkle activates the app itself when showing its
    /// windows for a background app (`SPUStandardUserDriver` calls
    /// `_activateApplication` when `activationPolicy == .accessory`), which is
    /// the same narrow click-driven carve-out to hard rule 4 that the settings
    /// gear and menu item already document. No hover path reaches this.
    func checkForUpdates() {
        Self.logger.notice("Update check requested from Settings")
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Settings window

    /// Owned here, not by a SwiftUI `Settings` scene.
    ///
    /// The scene version could not be opened from the notch panel:
    /// `@Environment(\.openSettings)` is only populated inside the App's
    /// scene graph, and the panel is an `NSHostingView` outside it. The
    /// workaround was an observer living in `MenuBarExtra`'s label — which
    /// dies the moment the menu bar icon becomes optional, silently taking
    /// the panel's gear button with it. Owning the window here has no scene
    /// dependency at all, so nothing about the icon can reach it.
    private var settingsWindow: NSWindow?

    /// Creates the window on first use and brings it forward.
    func showSettings() {
        // Hard rule 4 carve-out, the same narrow click-driven one as before:
        // without activation the window opens behind the frontmost app. No
        // hover path activates anything, ever.
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 715, height: 500),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "PopNotch Settings"
            window.contentView = NSHostingView(rootView: SettingsView(
                coordinator: coordinator,
                settings: settings,
                spotify: spotifyAccount,
                visualizer: audioViz,
                updater: updaterController.updater,
                onQuit: { NSApp.terminate(nil) }
            ))
            // Closing must not deallocate it; this delegate holds the only
            // reference and reopening has to work.
            window.isReleasedWhenClosed = false
            // contentMinSize, not minSize: the latter is the *frame*, so it
            // silently gains the titlebar and stops matching the number the
            // view asks for. Below this the split view collapses the sidebar
            // into a toolbar menu, which is the failure the sidebar replaced.
            window.contentMinSize = NSSize(width: 715, height: 500)
            window.center()
            window.setFrameAutosaveName("PopNotchSettings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        Self.logger.notice("Settings window shown")
    }

    @objc private func openSettingsRequested() {
        showSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        installSignalHandling()

        // Manual only. Set every launch rather than once, so a stale stored
        // preference — or a future Sparkle default — cannot quietly turn
        // background checking on for an app with no Dock icon to notify from.
        updaterController.updater.automaticallyChecksForUpdates = false

        // The panel's gear posts this. Observed here rather than in a view so
        // it survives whatever the scene graph is doing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsRequested),
            name: .popNotchOpenSettings,
            object: nil
        )

        // Modules register here, one line each — the Phase 2 goal made real.
        // Order is not precedence: MediaModule arbitrates by what is actually
        // playing. See MediaModule.shouldTakeOver(_:from:).
        let systemMedia = SystemMediaAdapter()
        // Applied from the stored preference before the source starts, the
        // same way the visualiser's flag is applied below.
        systemMedia.prefersMusicOverVideo = settings.settings.preferMusicOverVideo
        let media = MediaModule(
            // Order is not precedence — MediaModule.shouldTakeOver decides.
            //
            // `systemMedia` is DELIBERATELY ABSENT from this array (1.0.3).
            // `SystemMediaAdapter` shells out to `/opt/homebrew/bin/media-control`,
            // an absolute path into Homebrew that is not in the app bundle, so
            // the source works only on a machine that happens to have that
            // formula installed. Shipped in 1.0.2, it was inert for every
            // other user and failed silently: a missing tool logs one
            // `.notice` and is otherwise indistinguishable from "nothing is
            // playing" (reported by a user on YouTube Music in Chrome with
            // neither Spotify nor Music installed).
            //
            // The unblock is vendoring the tool into the bundle and resolving
            // it via `Bundle`, never an absolute path. That is real work, not
            // a chore: media-control 0.7.6 is a Perl script plus
            // `mediaremote-adapter.pl`, `MediaRemoteAdapter.framework` and a
            // Mach-O test client, on top of Apple-deprecated `/usr/bin/perl`
            // — two Mach-O objects to sign under Hardened Runtime and carry
            // through notarization. See the TODO on `SystemMediaAdapter.toolPath`
            // and record the decision in PROJECT-CONTEXT.md before re-adding
            // it here. The file stays in the target so the work resumes from
            // a built, tested read path rather than from scratch.
            sources: mediaSources(includingSystem: systemMedia),
            account: spotifyAccount, visualizer: audioViz)
        // Held so the Settings toggle can apply live rather than at next
        // launch — and so the source is ready the moment `isRegistered`
        // flips, without this wiring having to be rebuilt.
        self.systemMediaSource = systemMedia
        media.onLiveActivityRequest = { [weak self] request in
            self?.coordinator.requestLiveActivity(request)
        }
        media.onPresenceChange = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        media.onContentReflow = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        let clipboard = ClipboardModule(service: clipboardService)
        let modules: [any NotchModule] = [
            media,
            SystemStatsModule(service: statsService)
        ]
        // register() applies the stored preference itself, so a module can
        // never start in a state that disagrees with the user's choice.
        modules.forEach { coordinator.register($0) }
        // Off by default: it records everything the user copies, which is
        // not something to opt someone into. Its `isEnabled` setter is what
        // starts and stops the poll, so registering it disabled leaves no
        // timer running.
        coordinator.register(clipboard, enabledByDefault: false)
        // Off by default too: it touches the user's files, and holding
        // references to them is opt-in.
        coordinator.register(FileShelfModule(service: fileShelfService),
                             enabledByDefault: false)
        // The shelf's drag chooser needs to know when a drag is over the
        // panel; the coordinator hears it, the service displays it.
        coordinator.onFileDragActive = { [weak fileShelfService] active in
            fileShelfService?.setDragHovering(active)
        }

        Self.logger.notice("Launched with \(modules.count, privacy: .public) modules registered")

        // The stored preference; off by default. Visibility is the
        // coordinator's job, so no setPanelVisible here.
        audioViz.setEnabled(settings.settings.visualizerEnabled)
    }

    /// Kept alive for the process lifetime; a released source stops firing.
    private var sigtermSource: DispatchSourceSignal?

    /// Turns SIGTERM into an orderly quit so the adapter child dies with us.
    ///
    /// `applicationWillTerminate` covers Cmd-Q, but a signal bypasses AppKit
    /// entirely — the process dies without unwinding, and the child process
    /// is reparented to launchd still streaming. `scripts/install.sh` does
    /// exactly this on every install (`pkill -x PopNotch`), and each one
    /// leaked a `perl ... stream` until this existed (measured 2026-09-02).
    ///
    /// SIGKILL is deliberately not handled, because it cannot be: the child
    /// then outlives us until its next write hits the closed pipe and takes
    /// SIGPIPE. That is bounded by the next media event on the system, not
    /// unbounded, and is the residual this cannot reach.
    private func installSignalHandling() {
        // The default disposition must go first, or the process still dies
        // before the dispatch source ever runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Routed through AppKit rather than exiting here, so the normal
            // teardown below runs exactly once and by one path.
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        // The adapter runs as a child process, and a child is not reclaimed
        // the way an in-process timer is: on exit it is reparented to launchd
        // and keeps streaming. It only notices we are gone when its next
        // write hits a closed pipe, which for a paused session may be never.
        // Nothing else in the app forks, so this is the one source that needs
        // an explicit stop rather than letting deinit handle it.
        systemMediaSource?.stopObserving()
        // Deterministic on a clean quit. The system would reclaim the
        // assertion on exit anyway (verified with SIGKILL), but releasing
        // here means it goes the moment the user quits rather than whenever
        // the process finishes tearing down.
        caffeinate.release()
    }
}
