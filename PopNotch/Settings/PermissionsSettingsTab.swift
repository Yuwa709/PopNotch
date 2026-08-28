import SwiftUI
import AppKit
import os

/// Whether PopNotch may drive one scriptable player.
enum AutomationPermission: Equatable {
    case notInstalled
    case granted
    case denied
    /// Installed, but closed, so the check has not been made. Kept separate
    /// from `denied` deliberately: reporting "denied" for an app we never
    /// asked about would send the user to System Settings to fix nothing.
    case undetermined
}

/// Determines Automation permission by actually attempting an Apple Event
/// and reading the authorization error, never by assuming.
///
/// The probe is wrapped in a non-launching guard, which is not cosmetic.
/// Measured on this machine 2026-08-28: `tell application "Music" to return
/// player state` **launched Music** from closed, while `application "Music"
/// is running` returned false and left it closed. Without the guard, opening
/// this settings tab would launch Spotify and Music every time.
///
/// The cost is that a closed player reports `.undetermined` rather than a
/// definite answer. That is the honest result — macOS offers no way to test
/// an Automation grant without sending an event, and sending one launches
/// the app. The adapters settle it for real on first playback.
@MainActor
enum AutomationProbe {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Permissions")

    /// One property fetch inside the `tell`, so a real Apple Event crosses
    /// the TCC boundary. A bare `return` would stay inside AppleScript and
    /// prove nothing.
    private static func script(for appName: String) -> String {
        """
        if application "\(appName)" is running then
            tell application "\(appName)" to set s to (player state as text)
            return "ok"
        else
            return "idle"
        end if
        """
    }

    static func check(appName: String, bundleID: String) -> AutomationPermission {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            logger.notice("\(appName, privacy: .public): not installed")
            return .notInstalled
        }
        switch AppleScriptRunner.run(script(for: appName)) {
        case .success(let descriptor):
            if descriptor.stringValue == "idle" {
                logger.notice("\(appName, privacy: .public): installed, not running — permission undetermined")
                return .undetermined
            }
            logger.notice("\(appName, privacy: .public): Automation granted")
            return .granted
        case .failure(let failure):
            if failure.isPermissionDenied {
                logger.notice("\(appName, privacy: .public): Automation denied (-1743)")
                return .denied
            }
            // Any other script error tells us nothing about the grant.
            logger.notice("\(appName, privacy: .public): probe failed (\(failure.code, privacy: .public))")
            return .undetermined
        }
    }

    /// Privacy & Security → Automation.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        logger.notice("Opening System Settings at Privacy & Security -> Automation")
        NSWorkspace.shared.open(url)
    }
}

/// One scriptable player PopNotch can be granted access to.
struct AutomationTarget: Identifiable {
    let id: String
    let displayName: String
    let appName: String

    static let spotify = AutomationTarget(
        id: SpotifyAdapter.bundleID, displayName: "Spotify", appName: "Spotify")
    static let music = AutomationTarget(
        id: MusicAdapter.bundleID, displayName: "Music", appName: "Music")
}

/// Automation permission per player.
///
/// Apple Music needs no account — it is AppleScript only — so there is
/// deliberately no connection UI here. Spotify's account toggle stays on its
/// own tab; that is for the optional Web API extras, not for playback.
struct PermissionsSettingsTab: View {

    private static let targets: [AutomationTarget] = [.spotify, .music]

    @State private var states: [String: AutomationPermission] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(Self.targets) { target in
                    PermissionRow(target: target, state: states[target.id] ?? .undetermined)
                }
            } footer: {
                Text("PopNotch reads and controls playback with AppleScript. Apple Music needs no account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Check again") { probeAll() }
        }
        .formStyle(.grouped)
        .padding()
        // On appear and on demand only. Never on a timer: an Automation
        // grant changes when the user changes it, and hard rule 9 forbids
        // a poll with no suspend path.
        .onAppear { probeAll() }
    }

    private func probeAll() {
        for target in Self.targets {
            states[target.id] = AutomationProbe.check(
                appName: target.appName, bundleID: target.id)
        }
    }
}

/// One player's row. Denied is the only state that offers a remedy.
private struct PermissionRow: View {

    let target: AutomationTarget
    let state: AutomationPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(target.displayName) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(label)
                    if state == .denied {
                        Spacer()
                        Button("Open System Settings…") { AutomationProbe.openSystemSettings() }
                    }
                }
            }
            if state == .denied {
                Text("PopNotch needs Automation access to read and control playback in \(target.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch state {
        case .notInstalled: "minus.circle"
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .undetermined: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .notInstalled: .secondary
        case .granted: .green
        case .denied: .orange
        case .undetermined: .secondary
        }
    }

    private var label: String {
        switch state {
        case .notInstalled: "Not installed"
        case .granted: "Allowed"
        case .denied: "Denied"
        case .undetermined: "Checked when \(target.displayName) is open"
        }
    }
}
