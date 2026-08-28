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
    static let currentSchemaVersion = 2

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

    /// The Spotify developer app's Client ID (public information under
    /// PKCE — there is no secret). Empty until the user pastes theirs in
    /// Settings; account features stay hidden while empty.
    var spotifyClientID: String = ""

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, moduleEnablement, hoverEnterDelay, spotifyClientID
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
        spotifyClientID = (try? container.decode(String.self, forKey: .spotifyClientID))
            ?? ""
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
        default:
            break
        }

        result.schemaVersion = currentSchemaVersion
        return result
    }
}
