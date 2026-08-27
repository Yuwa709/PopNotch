import SwiftUI
import ServiceManagement
import os

/// The settings window. Tabs fill in as their features land: module
/// toggles arrive with Phase 2.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 380, height: 180)
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
