import SwiftUI
import ServiceManagement
import os

/// The settings window.
struct SettingsView: View {

    let coordinator: NotchCoordinator
    let settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModulesSettingsTab(coordinator: coordinator, settings: settings)
                .tabItem { Label("Modules", systemImage: "square.stack") }
        }
        .frame(width: 420, height: 220)
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
        }
        .formStyle(.grouped)
        .padding()
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
