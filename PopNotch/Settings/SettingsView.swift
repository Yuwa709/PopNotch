import SwiftUI
import ServiceManagement
import Sparkle
import Combine
import os

/// One sidebar row. An enum rather than free-floating views so the order,
/// the labels and the detail switch cannot drift apart.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, modules, music, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .modules: "Modules"
        case .music: "Music"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .modules: "square.stack"
        case .music: "music.note"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// The settings window.
///
/// A sidebar rather than a `TabView`: the tab bar collapsed into a toolbar
/// overflow menu whenever the window was narrow, which put every section
/// three clicks away. `minWidth` below is what guarantees the sidebar can
/// never collapse into that state again, so it is load-bearing rather than
/// cosmetic.
struct SettingsView: View {

    let coordinator: NotchCoordinator
    let settings: SettingsStore
    let spotify: SpotifyAccount

    let visualizer: AudioVisualizerService
    /// Optional so the tab stays constructible without a live Sparkle
    /// updater — tests build it with nil, and the Check for Updates row
    /// simply does not render.
    let updater: SPUUpdater?
    /// Injected rather than calling `NSApp.terminate` inline, so the view
    /// stays free of app lifecycle and a test can build one.
    let onQuit: () -> Void

    /// Optional because that is the shape `List` selection binds to; the
    /// detail falls back to General so the pane is never blank.
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            detail(for: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Roughly System Settings' own proportions. The minimum is the point:
        // below it the split view starts collapsing the sidebar.
        .frame(minWidth: 715, minHeight: 500)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsTab(coordinator: coordinator, settings: settings)
        case .modules:
            ModulesSettingsTab(coordinator: coordinator, settings: settings)
        case .music:
            MusicSettingsTab(account: spotify, settings: settings, visualizer: visualizer)
        case .permissions:
            PermissionsSettingsTab()
        case .about:
            AboutSettingsTab(updater: updater, onQuit: onQuit)
        }
    }
}

/// Everything about what is playing, in one place.
///
/// Was a Spotify-only tab, with the audio visualiser stranded over in
/// Modules despite being purely a now-playing concern. Both are here now;
/// Modules keeps only the on/off switches that every feature has.
///
/// The Spotify half has deliberately nothing to configure. The Client ID is
/// PopNotch's own and is built into the app (see `SpotifyAccount.clientID`);
/// it used to be a text field here, which meant a fresh install could not
/// connect at all until the user went and registered their own developer app.
struct MusicSettingsTab: View {

    @Bindable var account: SpotifyAccount
    @Bindable var settings: SettingsStore
    let visualizer: AudioVisualizerService

    var body: some View {
        Form {
            // Hidden while no source reads the preference — see
            // `SystemMediaAdapter.isRegistered`. A control that changes
            // nothing is worse than a missing one: it invites the user to
            // fix a problem it cannot affect. The stored value and its
            // schema field are untouched, so the choice already made comes
            // back with the section when the source ships.
            if SystemMediaAdapter.isRegistered {
                Section {
                    Toggle("Prefer music over video", isOn: musicOverVideoBinding)
                } header: {
                    Text("Other Players")
                } footer: {
                    Text("For players without their own integration — a browser, say — the notch ignores an update that drops the album of the track it is already showing, so a song does not flicker into looking like a video. Starting something genuinely different always takes over. Spotify and Apple Music are unaffected; they always take priority. On by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show a live spectrum", isOn: visualizerBinding)
            } header: {
                Text("Audio Visualizer")
            } footer: {
                Text("Draws what's playing in the notch. Needs the System Audio Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Spotify") {
            if account.isConnected {
                LabeledContent("Account") {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Connected")
                        Spacer()
                        Button("Disconnect") { account.disconnect() }
                    }
                }
            } else {
                Button("Connect Spotify…") { account.beginAuthorization() }
                Text("Opens Spotify in your browser to authorize PopNotch. Enables Up Next and liking the current track. You can disconnect at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = account.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Persists the choice and applies it to the live source in one place,
    /// exactly as `visualizerBinding` does.
    private var musicOverVideoBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.preferMusicOverVideo },
            set: { on in
                settings.update { $0.preferMusicOverVideo = on }
                (NSApp.delegate as? AppDelegate)?.systemMediaSource?
                    .prefersMusicOverVideo = on
            }
        )
    }

    /// Moved here from Modules unchanged: persists the choice and applies it
    /// live in one place.
    private var visualizerBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.visualizerEnabled },
            set: { on in
                settings.update { $0.visualizerEnabled = on }
                visualizer.setEnabled(on)
            }
        )
    }
}

/// One row per registered module. The player is listed like anything else —
/// it simply defaults to on.
struct ModulesSettingsTab: View {

    let coordinator: NotchCoordinator
    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(coordinator.moduleSummaries, id: \.id) { module in
                    Toggle(module.displayName, isOn: binding(for: module.id, current: module.isEnabled))
                }
            } footer: {
                Text("Disabled features stop sampling entirely — they use no CPU and no battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func binding(for id: ModuleID, current: Bool) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(id, default: current) },
            set: { coordinator.setEnabled($0, for: id) }
        )
    }
}

struct GeneralSettingsTab: View {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Settings")

    let coordinator: NotchCoordinator
    @Bindable var settings: SettingsStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var registrationError: String?

    var body: some View {
        Form {
            Toggle("Launch PopNotch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enable in
                    apply(enable)
                }
            if let registrationError {
                Text(registrationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section {
                Toggle("Show menu bar icon", isOn: menuBarIconBinding)
            } footer: {
                Text("With it hidden, Settings is still reachable from the gear in the notch, and Quit lives in the About tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Hover delay") {
                HStack(spacing: 10) {
                    Slider(value: hoverDelayBinding, in: 0...1, step: 0.05)
                    Text("\(Int((settings.settings.hoverEnterDelay * 1000).rounded())) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Writes straight through to the store; `MenuBarExtra(isInserted:)`
    /// observes the same value, so the icon appears and disappears live.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.showMenuBarIcon },
            set: { on in settings.update { $0.showMenuBarIcon = on } }
        )
    }

    /// How long the cursor must dwell before the notch opens. Applies live.
    private var hoverDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { settings.settings.hoverEnterDelay },
            set: { coordinator.setHoverDelay($0) }
        )
    }

    private func apply(_ enable: Bool) {
        // A failed attempt reverts the toggle, which re-fires onChange;
        // matching against the real status makes that re-fire a no-op.
        guard (SMAppService.mainApp.status == .enabled) != enable else { return }

        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            registrationError = nil
            Self.logger.notice("Launch at login \(enable ? "registered" : "unregistered", privacy: .public)")
        } catch {
            registrationError = "Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            Self.logger.error("Launch at login \(enable ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            launchAtLogin = !enable
        }
    }
}


/// Identity, licence, and the app's only guaranteed way out.
///
/// Quit lives here because the menu bar icon is optional: with it hidden
/// there is no Dock icon, no app menu, and no other menu to reach. It is a
/// tab rather than a category of its own — a sidebar entry holding one
/// destructive button would be worse than a footer under the information it
/// belongs with.
///
/// **Check for Updates belongs beside it** when Sparkle lands (Phase 5), for
/// exactly the same reason: an updater reachable only from a menu that may
/// not exist is not reachable. The spacer below is the room for it.
struct AboutSettingsTab: View {

    let updater: SPUUpdater?
    let onQuit: () -> Void

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (build \(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PopNotch")
                    .font(.system(size: 20, weight: .semibold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("MIT licensed. Free and open source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Must stay the same account the appcast is served from
                // (SUFeedURL in Info.plist), or the About tab points somewhere
                // other than where updates come from.
                Link("github.com/Yuwa709/PopNotch",
                     destination: URL(string: "https://github.com/Yuwa709/PopNotch")!)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let updater {
                Spacer(minLength: 16)
                UpdateCheckRow(updater: updater)
            }

            // Keeps Quit pinned to the bottom.
            Spacer(minLength: 16)

            Divider()
            HStack {
                Spacer()
                Button("Quit PopNotch", role: .destructive, action: onQuit)
            }
            .padding(.top, 12)
        }
        .padding()
    }
}


/// Manual update check, in About because the menu bar icon is optional — an
/// updater reachable only from a menu that may not exist is not reachable.
///
/// Its own view so the `@StateObject` below only exists when there is an
/// updater to observe.
private struct UpdateCheckRow: View {

    let updater: SPUUpdater
    @StateObject private var model: UpdateCheckModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: UpdateCheckModel(updater: updater))
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Updates")
                    .font(.callout)
                Text("PopNotch does not check on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!model.canCheckForUpdates)
        }
    }
}

/// Bridges Sparkle's `canCheckForUpdates` into SwiftUI.
///
/// The property is KVO-compliant but `SPUUpdater` is not an
/// `ObservableObject`, so a button bound straight to it would never re-render
/// — it would sit enabled through a running check and disabled forever after
/// one. This is the bridge Sparkle's own SwiftUI guidance describes.
@MainActor
private final class UpdateCheckModel: ObservableObject {

    @Published var canCheckForUpdates: Bool
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }
}
