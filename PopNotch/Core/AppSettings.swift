import Foundation

/// Everything the user can configure, in one `Codable` struct.
///
/// Persisted to UserDefaults as JSON by `SettingsStore`. No SwiftData, no
/// Core Data (hard rule 5). Live system state — the notch's actual contents —
/// is never stored here.
///
/// ## Changing this struct
///
/// Every shape change bumps `currentSchemaVersion` and adds a case to
/// `migrate(_:from:)`, plus a test that loads the previous version's JSON and
/// asserts nothing was dropped. Adding a property with a default is still a
/// shape change: old JSON lacks the key, so decoding must tolerate its
/// absence. That is why every property below has a default and the custom
/// decoder falls back to it rather than throwing.
struct AppSettings: Codable, Equatable {

    /// Bump on every shape change. See the note above.
    /// v2: added spotifyClientID.
    /// v3: added visualizerEnabled.
    /// v4: removed spotifyClientID — the Client ID is the app's own, built in.
    /// v5: added showMenuBarIcon.
    /// v6: added preferMusicOverVideo.
    /// v7: added spotifyAccountConnected.
    static let currentSchemaVersion = 7

    var schemaVersion: Int = AppSettings.currentSchemaVersion

    /// Per-module enable state, keyed by permanent `ModuleID`.
    ///
    /// A module absent from this dictionary has never been toggled; the
    /// arbiter treats absence as "use the module's own default" rather than
    /// as disabled, so newly shipped modules can appear without a migration.
    var moduleEnablement: [ModuleID: Bool] = [:]

    /// Seconds the cursor must dwell before the notch expands. User-tuned to
    /// 0.35 on hardware; 0.2 let too much passing traffic through.
    var hoverEnterDelay: TimeInterval = 0.35

    // `spotifyClientID` lived here until v4. It was a per-user field, which
    // was the wrong model: the Client ID identifies *PopNotch* to Spotify, not
    // the user, so every install needs the same one. Shipping it empty meant a
    // fresh install had no Client ID at all and Connect was permanently
    // disabled. It is now a build-time constant on `SpotifyAccount`.

    /// Whether the menu bar icon is inserted. **Defaults to on**: hiding it
    /// is a deliberate choice, and an agent with no Dock icon, no menu bar
    /// icon and no window is invisible to someone who has forgotten it is
    /// running. Everything the menu offered is reachable without it — the
    /// panel's gear opens Settings, and Quit lives in the About tab.
    var showMenuBarIcon: Bool = true

    /// Audio visualiser. Off by default on purpose: it needs the System
    /// Audio Recording permission, and a capture permission is opt-in, never
    /// something the app assumes.
    var visualizerEnabled: Bool = false

    /// Within the system now-playing source, prefer a track that has an album
    /// over one that does not.
    ///
    /// **Defaults to on.** macOS exposes one session at a time, so this is not
    /// a choice between two candidates — it is whether to accept the one on
    /// offer, and `album` is the only field that tells music from video.
    ///
    /// Narrow on purpose: it holds only while the app, the item and the
    /// playing state all still match, so what it actually absorbs is a
    /// payload that drops the album of the track already on screen. A
    /// genuinely different item is a different session and always wins —
    /// holding across one pinned a paused song to the notch with its scrub
    /// bar still running (hardware, 2026-09-01).
    ///
    /// Off means the system source reports whatever the session says, in
    /// arrival order. Has no effect on Spotify or Apple Music, which have
    /// their own adapters and outrank this source either way.
    var preferMusicOverVideo: Bool = true

    /// Whether a Spotify refresh token exists, cached outside the Keychain.
    ///
    /// **Deliberately tri-state.** `true`/`false` are answers; `nil` means
    /// "never recorded" — an install upgraded from v6 or earlier, or a fresh
    /// install whose settings have never been written. Only `nil` may
    /// consult the Keychain, and doing so writes the answer here, so the
    /// question is asked of the Keychain at most once per install.
    ///
    /// A plain `Bool` would collapse "no account" and "don't know" into
    /// `false`, which is precisely the bug that would log existing users out
    /// on upgrade: the Keychain outlives the app bundle, so a token can be
    /// present on an install whose settings are brand new.
    ///
    /// It caches a fact about the Keychain, never a credential — the refresh
    /// token itself stays in the Keychain and never touches UserDefaults.
    var spotifyAccountConnected: Bool?

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, moduleEnablement, hoverEnterDelay, visualizerEnabled
        case showMenuBarIcon, preferMusicOverVideo, spotifyAccountConnected
    }

    init() {}

    /// Decodes leniently: a missing or malformed individual key falls back to
    /// its default rather than failing the whole load. Losing one preference
    /// is recoverable; losing all of them is what "never wipe user settings
    /// silently" is guarding against.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion))
            ?? AppSettings.currentSchemaVersion
        moduleEnablement = (try? container.decode([ModuleID: Bool].self, forKey: .moduleEnablement))
            ?? [:]
        hoverEnterDelay = (try? container.decode(TimeInterval.self, forKey: .hoverEnterDelay))
            ?? 0.35
        // A v2/v3 payload still carries spotifyClientID. It has no CodingKey
        // any more, so it is ignored rather than throwing — the lenient
        // contract above already covers keys this version does not know.
        visualizerEnabled = (try? container.decode(Bool.self, forKey: .visualizerEnabled))
            ?? false
        // Absent in v4 and earlier, which is exactly the shipped default.
        showMenuBarIcon = (try? container.decode(Bool.self, forKey: .showMenuBarIcon))
            ?? true
        // Absent in v5 and earlier; on is the shipped default.
        preferMusicOverVideo = (try? container.decode(Bool.self, forKey: .preferMusicOverVideo))
            ?? true
        // Absent in v6 and earlier, and nil is meaningful here rather than a
        // fallback: it is what sends `SpotifyAccount` to the Keychain once.
        spotifyAccountConnected = try? container.decodeIfPresent(
            Bool.self, forKey: .spotifyAccountConnected)
    }

    // MARK: - Migration

    /// Upgrades settings decoded from an older schema.
    ///
    /// Called by `SettingsStore` after a successful decode, before use. Each
    /// future version adds its own step and falls through to the next, so a
    /// user who skipped several releases still arrives at current.
    static func migrate(_ settings: AppSettings, from version: Int) -> AppSettings {
        var result = settings

        switch version {
        case ..<1:
            // Pre-versioned JSON, if any ever existed in a dev build: the
            // lenient decoder already filled defaults. Nothing to move.
            result.schemaVersion = 1
            fallthrough
        case 1:
            // v2 added spotifyClientID; the lenient decoder fills "" for v1
            // JSON, which is exactly the not-configured state. Nothing moves.
            fallthrough
        case 2:
            // v3 added visualizerEnabled; the lenient decoder fills false for
            // v2 JSON, which is exactly the off-by-default state. Nothing moves.
            fallthrough
        case 3:
            // v4 removed spotifyClientID. Nothing to move: the value it held
            // was either empty (the broken default) or a hand-pasted copy of
            // an ID the app now supplies itself, and in both cases the built-in
            // constant supersedes it. This is the one case where dropping a
            // stored value is correct rather than a silent wipe — the field
            // no longer has a meaning for the user to have configured.
            fallthrough
        case 4:
            // v5 added showMenuBarIcon; the lenient decoder fills true for v4
            // JSON, which is the on-by-default state. Nothing moves.
            fallthrough
        case 5:
            // v6 added preferMusicOverVideo; the lenient decoder fills true
            // for v5 JSON, which is the on-by-default state. Nothing moves.
            fallthrough
        case 6:
            // v7 added spotifyAccountConnected. It stays **nil** here on
            // purpose: this migration cannot know whether a token exists
            // without reading the Keychain, which is the very thing the
            // field was added to avoid at launch. Nil routes the first
            // `SpotifyAccount.init` through one Keychain read, which then
            // records the answer — so an upgrading user who is connected
            // stays connected. Writing `false` here would log them out.
            fallthrough
        default:
            break
        }

        result.schemaVersion = currentSchemaVersion
        return result
    }
}
