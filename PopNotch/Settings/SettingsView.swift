import SwiftUI

/// The settings window. Tabs fill in as their features land: launch at
/// login arrives with Phase 1 task 10, module toggles with Phase 2.
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
    var body: some View {
        VStack(spacing: 8) {
            Text("PopNotch")
                .font(.headline)
            Text("Settings arrive alongside their features — launch at login is next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
