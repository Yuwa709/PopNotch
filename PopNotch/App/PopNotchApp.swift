//
//  PopNotchApp.swift
//  PopNotch
//
//  Created by Joshua Pham on 8/27/26.
//

import SwiftUI

@main
struct PopNotchApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Background agent (LSUIElement): no main window, ever. The notch
        // panel is created by AppDelegate; this menu bar item is the only
        // other UI surface.
        MenuBarExtra("PopNotch", systemImage: "rectangle.topthird.inset.filled") {
            SettingsMenuItem()
            Divider()
            Button("Quit PopNotch") {
                NSApp.terminate(nil)
            }
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
