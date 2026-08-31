//
//  PopNotchApp.swift
//  PopNotch
//
//  Created by Joshua Pham on 8/27/26.
//

import SwiftUI

extension Notification.Name {
    /// Asks the App scene graph to open Settings.
    ///
    /// The notch panel cannot do it itself. `@Environment(\.openSettings)` is
    /// only populated for views inside the `App`'s scene graph, and the panel
    /// is built by `AppDelegate` and hosted in an `NSHostingView` outside it.
    /// The documented fallback — `NSApp.sendAction(Selector(("showSettingsWindow:")))`
    /// — is worse than useless here: measured 2026-08-30 it returns **true**
    /// while creating no window at all, so it reports success and does
    /// nothing. This notification hands the request to a view that genuinely
    /// has the environment action.
    static let popNotchOpenSettings = Notification.Name("com.techie.PopNotch.openSettings")
}

@main
struct PopNotchApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Background agent (LSUIElement): no main window, ever. The notch
        // panel is created by AppDelegate; this menu bar item is the only
        // other UI surface.
        MenuBarExtra {
            SettingsMenuItem()
            Divider()
            Button("Quit PopNotch") {
                NSApp.terminate(nil)
            }
        } label: {
            // The label, not the menu content: content is built lazily when
            // the menu opens, so an observer there would be asleep exactly
            // when the panel needs it. The label renders for as long as the
            // menu bar item exists, which is the whole session.
            SettingsOpenBridge()
        }

        Settings {
            SettingsView(
                coordinator: appDelegate.coordinator,
                settings: appDelegate.settings,
                spotify: appDelegate.spotifyAccount,
                visualizer: appDelegate.audioViz
            )
        }
    }
}

/// Draws the menu bar icon, and doubles as the notch panel's way into
/// Settings: it lives in the scene graph, so `openSettings` actually works
/// here. The panel posts, this opens.
private struct SettingsOpenBridge: View {

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label("PopNotch", systemImage: "rectangle.topthird.inset.filled")
            .onReceive(NotificationCenter.default.publisher(for: .popNotchOpenSettings)) { _ in
                openSettings()
            }
    }
}

private struct SettingsMenuItem: View {

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            // Hard rule 4 carve-out, deliberate and narrow: activation here
            // is a direct response to the user clicking this menu item —
            // without it the settings window opens behind the frontmost
            // app. No hover path activates anything, ever.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
