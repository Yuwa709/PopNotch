import Foundation
import os

/// The track queued after the current one, when the player exposes one.
///
/// Only Music.app can answer this from its scripting dictionary. Spotify's
/// has no playlist, context, or queue — its `next track` is a *command* that
/// skips, not data — so `SpotifyAdapter` always reports nil here and Up Next
/// for Spotify comes from the optional Web API instead.
struct UpNextTrack: Equatable {
    let title: String
    let artist: String
}

/// Kept so the Web API layer and its tests keep their original name while
/// both sources now speak the same type.
typealias SpotifyUpNext = UpNextTrack

/// Whether the current track is favourited, and whether this source can
/// change it.
///
/// The distinction is forced by the dictionaries, not by preference:
/// Spotify's `starred` is `access="r"` — readable, never writable — while
/// Music's `favorited` is read-write. A UI that offers a toggle for Spotify
/// would be offering something the scripting interface cannot do.
enum FavoriteState: Equatable {
    /// No favourite concept is reachable for this source right now.
    case unsupported
    /// Known, but this source cannot change it (Spotify's `starred`).
    case readOnly(Bool)
    /// Known and changeable (Music's `favorited`).
    case editable(Bool)

    var value: Bool? {
        switch self {
        case .unsupported: nil
        case .readOnly(let on), .editable(let on): on
        }
    }

    var isEditable: Bool {
        if case .editable = self { return true }
        return false
    }
}

/// One music player PopNotch can read and control.
///
/// Adapters (Spotify, Apple Music) implement this; `MediaModule` owns a list
/// of them and is the only thing that talks to them. A MediaRemote-based
/// source can slot in here if Apple ever lifts the caller gate — see
/// FINDINGS.md.
@MainActor
protocol MediaSource: AnyObject {

    /// Stable identifier, e.g. "spotify".
    var sourceID: String { get }

    var isPlayerRunning: Bool { get }

    /// The user declined the Automation prompt for this player. The module
    /// degrades: metadata that arrives without Apple Events still shows, and
    /// the expanded view explains how to grant access. Never re-prompts in a
    /// loop.
    var permissionDenied: Bool { get }

    /// Fires with the latest snapshot, or nil when the player has nothing
    /// (stopped, quit). Always on the main actor.
    var onUpdate: ((NowPlaying?) -> Void)? { get set }

    /// Begin listening for changes. Push-based (distributed notifications) —
    /// no timers, so this may run for the app's lifetime without violating
    /// hard rule 9; a source must still not poll here.
    func startObserving()
    func stopObserving()

    /// Fetch current state now (Apple Event). Called when the module becomes
    /// visible and on track changes; the first call triggers the system's
    /// one-time Automation permission prompt.
    func refresh()

    func send(_ command: MediaCommand)

    /// Jump playback to an absolute position, for scrubbing.
    func seek(to seconds: TimeInterval)

    /// Next track in the player's own queue, refreshed by `refresh()` rather
    /// than fetched on access — reading it costs an Apple Event, and this is
    /// read from view code.
    var upNext: UpNextTrack? { get }

    /// Favourite state for the current track, refreshed by `refresh()`.
    var favorite: FavoriteState { get }

    /// Changes the favourite flag. A no-op unless `favorite` is `.editable`;
    /// callers should still check first so the UI never offers a dead control.
    func setFavorite(_ on: Bool)
}

/// Defaults for sources whose player exposes neither concept, so an adapter
/// only implements what its dictionary actually supports.
extension MediaSource {
    var upNext: UpNextTrack? { nil }
    var favorite: FavoriteState { .unsupported }
    func setFavorite(_ on: Bool) {}
}

/// Runs an AppleScript source and reports the result or the error code.
///
/// Main-actor only: NSAppleScript is not thread-safe. Scripts here are static
/// strings against a running player and return in milliseconds; the one slow
/// case is the first-ever call, which blocks on the system permission dialog —
/// user-driven and one-time.
@MainActor
enum AppleScriptRunner {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AppleScript")

    /// errAEEventNotPermitted: the user declined the Automation prompt.
    static let permissionDeniedCode = -1743

    struct Failure: Error {
        let code: Int
        var isPermissionDenied: Bool { code == AppleScriptRunner.permissionDeniedCode }
    }

    static func run(_ source: String) -> Result<NSAppleEventDescriptor, Failure> {
        guard let script = NSAppleScript(source: source) else {
            logger.error("Script failed to compile")
            return .failure(Failure(code: 0))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            logger.notice("Apple Event failed (\(code, privacy: .public))")
            return .failure(Failure(code: code))
        }
        return .success(descriptor)
    }
}
