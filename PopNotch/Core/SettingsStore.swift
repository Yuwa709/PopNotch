import Foundation
import Observation
import os

/// Loads and saves `AppSettings` as JSON in UserDefaults.
///
/// Injectable `UserDefaults` so tests can run against a scratch suite instead
/// of the real domain.
@MainActor
@Observable
final class SettingsStore {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Settings")

    @ObservationIgnored
    static let storageKey = "com.techie.PopNotch.settings"
    /// Where unreadable JSON is parked instead of being overwritten.
    @ObservationIgnored
    static let salvageKey = "com.techie.PopNotch.settings.unreadable"

    private(set) var settings: AppSettings

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    // MARK: - Reading

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey) else {
            logger.notice("No stored settings; starting from defaults")
            return AppSettings()
        }

        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            let migrated = AppSettings.migrate(decoded, from: decoded.schemaVersion)
            if migrated.schemaVersion != decoded.schemaVersion {
                logger.notice("Migrated settings from schema \(decoded.schemaVersion) to \(migrated.schemaVersion)")
            }
            return migrated
        } catch {
            // Never wipe user settings silently: park the unreadable payload
            // under a separate key so it can be inspected or recovered, and
            // say so loudly, rather than overwriting it with defaults.
            defaults.set(data, forKey: salvageKey)
            logger.error("Settings unreadable (\(error.localizedDescription, privacy: .public)); preserved under \(salvageKey, privacy: .public) and continuing with defaults")
            return AppSettings()
        }
    }

    // MARK: - Writing

    /// Mutates settings and persists. The only write path, so every change
    /// is saved and logged in one place.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.logger.error("Could not encode settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Module enablement

    /// Whether a module should run, honouring its own default when the user
    /// has never expressed a preference.
    func isEnabled(_ id: ModuleID, default fallback: Bool) -> Bool {
        settings.moduleEnablement[id] ?? fallback
    }

    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        update { $0.moduleEnablement[id] = enabled }
        Self.logger.notice("Module \(id, privacy: .public) \(enabled ? "enabled" : "disabled", privacy: .public)")
    }
}
