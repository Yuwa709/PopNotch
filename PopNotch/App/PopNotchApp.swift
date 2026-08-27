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
        // Background agent (LSUIElement): no main window, ever. The panel is
        // created by AppDelegate. Settings is the only scene, and nothing
        // opens at launch; a real settings window arrives in Phase 1 task 9.
        Settings {
            EmptyView()
        }
    }
}
