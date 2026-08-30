import SwiftUI
import ServiceManagement
import os

/// The settings window.
struct SettingsView: View {

    let coordinator: NotchCoordinator
    let settings: SettingsStore
    let spotify: SpotifyAccount

    let visualizer: AudioVisualizerService

    var body: some View {
        TabView {
            GeneralSettingsTab(coordinator: coordinator, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModulesSettingsTab(coordinator: coordinator, settings: settings, visualizer: visualizer)
                .tabItem { Label("Modules", systemImage: "square.stack") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            SpotifySettingsTab(settings: settings, account: spotify)
                .tabItem { Label("Spotify", systemImage: "music.note") }
        }
        .frame(width: 460, height: 320)
    }
}

/// Connecting a Spotify account for queue and likes: official OAuth with
/// PKCE. The Client ID is the user's own developer-app registration —
/// public information under PKCE, no secret involved.
struct SpotifySettingsTab: View {

    @Bindable var settings: SettingsStore
    @Bindable var account: SpotifyAccount

    var body: some View {
        Form {
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
                TextField("Client ID", text: clientIDBinding, prompt: Text("Spotify app Client ID"))
                    .textFieldStyle(.roundedBorder)
                Button("Connect Spotify…") { account.beginAuthorization() }
                    .disabled(settings.settings.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Create a free app at developer.spotify.com/dashboard, add the redirect URI \(SpotifyAccount.redirectURI) exactly, then paste its Client ID here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = account.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var clientIDBinding: Binding<String> {
        Binding(
            get: { settings.settings.spotifyClientID },
            set: { value in settings.update { $0.spotifyClientID = value } }
        )
    }
}

/// One row per registered module. The player is listed like anything else —
/// it simply defaults to on.
struct ModulesSettingsTab: View {

    let coordinator: NotchCoordinator
    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore
    let visualizer: AudioVisualizerService

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
            Section {
                Toggle("Audio Visualizer", isOn: visualizerBinding)
            } footer: {
                Text("Shows a live spectrum of what's playing. Needs the System Audio Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Persists the choice and applies it live in one place.
    private var visualizerBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.visualizerEnabled },
            set: { on in
                settings.update { $0.visualizerEnabled = on }
                visualizer.setEnabled(on)
            }
        )
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
