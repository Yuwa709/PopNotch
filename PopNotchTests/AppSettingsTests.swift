import XCTest
@testable import PopNotch

/// CLAUDE.md requires that every schemaVersion bump gets a test loading the
/// previous version's JSON and asserting nothing was dropped. Version 1 is
/// the first shipped schema, so these tests pin the current shape and the
/// "never wipe user settings silently" contract that future migrations must
/// keep honouring.
@MainActor
final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A scratch suite per test, so the developer's real settings are
        // never read or written by the test run.
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> SettingsStore {
        SettingsStore(defaults: defaults)
    }

    private func write(_ json: String) {
        defaults.set(Data(json.utf8), forKey: SettingsStore.storageKey)
    }

    // MARK: - Round trip

    func testDefaultsWhenNothingStored() {
        let settings = store().settings
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, [:])
        XCTAssertEqual(settings.hoverEnterDelay, 0.35)
    }

    func testChangesPersistAcrossStoreInstances() {
        let first = store()
        first.setEnabled(false, for: "weather")
        first.update { $0.hoverEnterDelay = 0.5 }

        let reloaded = store()
        XCTAssertEqual(reloaded.settings.moduleEnablement["weather"], false)
        XCTAssertEqual(reloaded.settings.hoverEnterDelay, 0.5)
    }

    func testUnchangedUpdateDoesNotRewrite() {
        let subject = store()
        subject.update { $0.hoverEnterDelay = 0.35 } // already the default
        XCTAssertNil(defaults.data(forKey: SettingsStore.storageKey))
    }

    // MARK: - Module enablement

    func testAbsentModuleFallsBackToItsOwnDefault() {
        let subject = store()
        XCTAssertTrue(subject.isEnabled("never-seen", default: true))
        XCTAssertFalse(subject.isEnabled("never-seen", default: false))
    }

    func testStoredPreferenceBeatsTheDefault() {
        let subject = store()
        subject.setEnabled(false, for: "stats")
        XCTAssertFalse(subject.isEnabled("stats", default: true))
    }

    // MARK: - Lenient decoding

    func testUnknownKeysAreIgnored() {
        write(#"{"schemaVersion":1,"hoverEnterDelay":0.5,"moduleEnablement":{},"futureFeature":true}"#)
        XCTAssertEqual(store().settings.hoverEnterDelay, 0.5)
    }

    func testMissingKeyFallsBackToDefaultWithoutLosingTheRest() {
        // hoverEnterDelay absent, as it would be in JSON written before the
        // key existed. The rest must survive.
        write(#"{"schemaVersion":1,"moduleEnablement":{"stats":false}}"#)
        let settings = store().settings
        XCTAssertEqual(settings.hoverEnterDelay, 0.35)
        XCTAssertEqual(settings.moduleEnablement["stats"], false)
    }

    func testMalformedValueForOneKeyDoesNotDiscardTheOthers() {
        write(#"{"schemaVersion":1,"hoverEnterDelay":"not a number","moduleEnablement":{"stats":false}}"#)
        let settings = store().settings
        XCTAssertEqual(settings.hoverEnterDelay, 0.35, "bad value falls back")
        XCTAssertEqual(settings.moduleEnablement["stats"], false, "good value survives")
    }

    // MARK: - Never wipe silently

    func testUnreadableJSONIsPreservedRatherThanOverwritten() {
        let corrupt = Data("this is not JSON at all".utf8)
        defaults.set(corrupt, forKey: SettingsStore.storageKey)

        let subject = store()
        XCTAssertEqual(subject.settings, AppSettings(), "falls back to defaults")
        XCTAssertEqual(
            defaults.data(forKey: SettingsStore.salvageKey),
            corrupt,
            "the unreadable payload must be kept for recovery"
        )
    }

    // MARK: - Migration

    func testV1JSONMigratesToV2WithNothingDropped() {
        // Exactly what a v1 install persisted. CLAUDE.md requires every
        // schema bump to load the previous version's JSON and prove nothing
        // was dropped.
        write(#"{"schemaVersion":1,"moduleEnablement":{"stats":false},"hoverEnterDelay":0.5}"#)
        let settings = store().settings
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement["stats"], false)
        XCTAssertEqual(settings.hoverEnterDelay, 0.5)
    }

    func testMigrationStampsCurrentVersion() {
        var old = AppSettings()
        old.schemaVersion = 0
        old.moduleEnablement = ["stats": false]

        let migrated = AppSettings.migrate(old, from: 0)
        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["stats"], false, "nothing dropped")
    }

    func testCurrentVersionSurvivesMigrationUnchanged() {
        var settings = AppSettings()
        settings.moduleEnablement = ["media": true]
        settings.hoverEnterDelay = 0.42

        XCTAssertEqual(AppSettings.migrate(settings, from: AppSettings.currentSchemaVersion), settings)
    }

    // MARK: - v2 -> v3

    func testV2JSONMigratesWithNothingDropped() throws {
        // Real v2 shape: no visualizerEnabled key.
        let v2 = Data("""
        {"schemaVersion": 2,
         "moduleEnablement": {"system-stats": false},
         "hoverEnterDelay": 0.1,
         "spotifyClientID": "abc123"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v2)
        let migrated = AppSettings.migrate(decoded, from: 2)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertFalse(migrated.visualizerEnabled,
                       "the new field arrives OFF: a capture permission is opt-in")
    }

    // MARK: - v3 -> v4

    /// v4 removed spotifyClientID. The key is still present in every existing
    /// install's JSON, so the decoder must ignore it rather than throw — if it
    /// threw, the store would fall back to defaults and the user would lose
    /// every other preference, which is precisely the silent wipe CLAUDE.md
    /// forbids.
    func testV3JSONMigratesWithEveryOtherPreferenceIntact() throws {
        // Real v3 shape, including the field that no longer exists.
        let v3 = Data("""
        {"schemaVersion": 3,
         "moduleEnablement": {"system-stats": false, "clipboard": true},
         "hoverEnterDelay": 0.1,
         "spotifyClientID": "290ab45ba19d43599f66bb341cb33c77",
         "visualizerEnabled": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v3)
        let migrated = AppSettings.migrate(decoded, from: 3)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    // MARK: - v5 -> v6

    /// v6 added preferMusicOverVideo. Real v5 JSON has no such key, and it
    /// must arrive ON: an upgrade that silently started letting YouTube
    /// videos replace the music in the notch would read as a regression, not
    /// as a preference nobody set.
    func testV5JSONMigratesWithMusicPreferenceOn() throws {
        let v5 = Data("""
        {"schemaVersion": 5,
         "moduleEnablement": {"clipboard": true, "file-shelf": true, "system-stats": false},
         "hoverEnterDelay": 0.1,
         "visualizerEnabled": true,
         "showMenuBarIcon": false}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v5)
        let migrated = AppSettings.migrate(decoded, from: 5)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(migrated.preferMusicOverVideo, "upgrading must not change what the notch shows")
        XCTAssertFalse(migrated.showMenuBarIcon, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["file-shelf"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    // MARK: - v4 -> v5

    /// v5 added showMenuBarIcon. Real v4 JSON has no such key, and the icon
    /// must come back ON — an agent with no Dock icon, no menu bar icon and
    /// no window is invisible to someone who has forgotten it is running, so
    /// an upgrade must never hide it silently.
    func testV4JSONMigratesWithTheIconStillShowing() throws {
        let v4 = Data("""
        {"schemaVersion": 4,
         "moduleEnablement": {"clipboard": true, "file-shelf": true, "system-stats": false},
         "hoverEnterDelay": 0.1,
         "visualizerEnabled": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: v4)
        let migrated = AppSettings.migrate(decoded, from: 4)

        XCTAssertEqual(migrated.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertTrue(migrated.showMenuBarIcon, "upgrading must not hide the icon")
        XCTAssertEqual(migrated.moduleEnablement["clipboard"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["file-shelf"], true, "nothing dropped")
        XCTAssertEqual(migrated.moduleEnablement["system-stats"], false, "nothing dropped")
        XCTAssertEqual(migrated.hoverEnterDelay, 0.1, accuracy: 0.0001, "nothing dropped")
        XCTAssertTrue(migrated.visualizerEnabled, "nothing dropped")
    }

    func testMenuBarIconDefaultsOnForAFreshInstall() {
        XCTAssertTrue(AppSettings().showMenuBarIcon)
    }

    // MARK: - v7: the Spotify connected flag

    /// CLAUDE.md's rule: every schemaVersion bump gets a test that loads the
    /// previous version's JSON and asserts nothing was dropped.
    func testV6JSONMigratesToV7WithNothingDropped() throws {
        write("""
        {"schemaVersion": 6,
         "moduleEnablement": {"media": true, "clipboard": false, "system-stats": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false}
        """)
        let settings = SettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 7, "v6 lands at v7 or beyond")
        // Every v6 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement["media"], true)
        XCTAssertEqual(settings.moduleEnablement["clipboard"], false)
        XCTAssertEqual(settings.moduleEnablement["system-stats"], true)
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        // v6 JSON cannot say whether a Spotify token exists, so the one-time
        // Keychain cleanup is queued rather than guessed away.
        XCTAssertTrue(settings.spotifyKeychainCleanupPending,
                      "v6 payload must not be read as 'no Spotify token'")
    }

    /// Every pre-v11 payload that never recorded the old connected flag
    /// arrives with the cleanup queued: nothing said there was no token.
    func testEveryOlderSchemaWithoutTheFlagQueuesTheCleanup() throws {
        for version in 1...10 {
            defaults.removePersistentDomain(forName: suiteName)
            write("{\"schemaVersion\": \(version), \"moduleEnablement\": {}}")
            XCTAssertTrue(store().settings.spotifyKeychainCleanupPending,
                          "v\(version) must not claim to know the Spotify state")
        }
    }

    // MARK: - v8: the capybara theme

    /// CLAUDE.md's rule again: real v7 JSON must load with nothing dropped,
    /// and the new flag must arrive OFF — a theme nobody chose must not
    /// switch itself on across an upgrade.
    func testV7JSONMigratesToV8WithNothingDropped() throws {
        write("""
        {"schemaVersion": 7,
         "moduleEnablement": {"media": true, "clipboard": false, "system-stats": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true}
        """)
        let settings = SettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 8, "v7 lands at v8 or beyond")
        // Every v7 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement["media"], true)
        XCTAssertEqual(settings.moduleEnablement["clipboard"], false)
        XCTAssertEqual(settings.moduleEnablement["system-stats"], true)
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending, "a stored token is queued for cleanup")
        XCTAssertFalse(settings.capybaraThemeEnabled, "the new field arrives OFF")
    }

    func testCapybaraThemeDefaultsOffAndRoundTrips() {
        XCTAssertFalse(AppSettings().capybaraThemeEnabled)
        store().update { $0.capybaraThemeEnabled = true }
        XCTAssertTrue(store().settings.capybaraThemeEnabled, "must survive a reload")
    }

    // MARK: - v9: app volume

    /// CLAUDE.md's rule: real v8 JSON loads with nothing dropped. Every v8
    /// field holds a non-default value, so one that silently fell back to its
    /// default would fail here instead of passing unnoticed.
    func testV8JSONMigratesToV9WithNothingDropped() {
        write("""
        {"schemaVersion": 8,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 9, "v8 lands at v9 or beyond")
        // Every v8 preference survives untouched.
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        // And the new struct arrives empty.
        XCTAssertNil(settings.appVolume.tapsEnabled, "taps arrive off: a capture permission is opt-in")
        XCTAssertNil(settings.appVolume.volumes, "no app arrives turned down")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testAppVolumeDefaultsEmptyAndRoundTrips() {
        XCTAssertEqual(AppSettings().appVolume, AppSettings.AppVolume())
        let saved = ["com.hnc.Discord": 35,
                     AudioOwnerResolver.webContentKey: 60,
                     "path:/opt/homebrew/bin/mpv": 0]
        store().update {
            $0.appVolume.tapsEnabled = true
            $0.appVolume.volumes = saved
        }
        let reloaded = store().settings.appVolume
        XCTAssertEqual(reloaded.tapsEnabled, true, "must survive a reload")
        XCTAssertEqual(reloaded.volumes, saved, "every key shape must survive a reload")
    }

    /// What the optional fields and `try?` exist to prevent: a bad
    /// `appVolume` costs only itself, and never reaches the store's catch,
    /// which would reset every other setting.
    func testMalformedAppVolumeDoesNotDiscardTheOtherSettings() {
        write(#"{"schemaVersion":9,"hoverEnterDelay":0.5,"moduleEnablement":{"stats":false},"appVolume":"loud"}"#)
        let settings = store().settings
        XCTAssertEqual(settings.appVolume, AppSettings.AppVolume(), "bad value falls back")
        XCTAssertEqual(settings.hoverEnterDelay, 0.5, "the rest survives")
        XCTAssertEqual(settings.moduleEnablement["stats"], false, "the rest survives")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "the catch never ran")
    }

    func testOneMalformedAppVolumeValueCostsOnlyItself() {
        write("""
        {"schemaVersion": 9,
         "appVolume": {"tapsEnabled": "yes",
                       "volumes": {"com.hnc.Discord": 35, "webkit": "quiet"}}}
        """)
        let appVolume = store().settings.appVolume
        XCTAssertNil(appVolume.tapsEnabled, "a malformed flag reads as never set: off")
        XCTAssertEqual(appVolume.volumes, ["com.hnc.Discord": 35],
                       "a malformed entry loses itself, not the other apps' volumes")
    }

    // MARK: - v10: output routing

    /// CLAUDE.md's rule: real v9 JSON loads with nothing dropped. Every v9
    /// field holds a non-default value, the app-volume ones included, so one
    /// that silently fell back to its default would fail here.
    func testV9JSONMigratesToV10WithNothingDropped() {
        write("""
        {"schemaVersion": 9,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60}}}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(settings.schemaVersion, 10, "v9 lands at v10 or beyond")
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.spotifyKeychainCleanupPending)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true, "taps stay on across the upgrade")
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60],
                       "every saved volume survives")
        XCTAssertNil(settings.appVolume.outputs, "every app arrives on System default")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    func testOutputsRoundTripByDeviceUID() {
        let saved = ["com.hnc.Discord": "AppleUSBAudioEngine:Apple, Inc.:EarPods:1",
                     SpotifyAdapter.bundleID: "44-A7-F4-2C-B3-DA:output"]
        store().update { $0.appVolume.outputs = saved }
        XCTAssertEqual(store().settings.appVolume.outputs, saved, "must survive a reload")
    }

    func testOneMalformedOutputCostsOnlyItself() {
        write("""
        {"schemaVersion": 10,
         "appVolume": {"volumes": {"com.hnc.Discord": 35},
                       "outputs": {"com.hnc.Discord": "usb", "webkit": 42, "org.chromium": ""}}}
        """)
        let appVolume = store().settings.appVolume
        XCTAssertEqual(appVolume.outputs, ["com.hnc.Discord": "usb"],
                       "a non-string or empty UID loses itself, not the other apps' outputs")
        XCTAssertEqual(appVolume.volumes, ["com.hnc.Discord": 35], "and never the volumes beside it")
    }

    // MARK: - v11: the Spotify account removed

    /// CLAUDE.md's rule: real v10 JSON loads with nothing dropped. Every v10
    /// field holds a non-default value, so one that silently fell back to its
    /// default would fail here. The one field v11 removes is converted, not
    /// dropped: a stored token becomes a queued cleanup.
    func testV10JSONMigratesToV11WithNothingDropped() {
        write("""
        {"schemaVersion": 10,
         "moduleEnablement": {"media": true, "clipboard": false, "app-volume": true},
         "hoverEnterDelay": 0.42,
         "visualizerEnabled": true,
         "showMenuBarIcon": false,
         "preferMusicOverVideo": false,
         "spotifyAccountConnected": true,
         "capybaraThemeEnabled": true,
         "appVolume": {"tapsEnabled": true,
                       "volumes": {"com.hnc.Discord": 35, "webkit": 60},
                       "outputs": {"com.hnc.Discord": "usb-uid"}}}
        """)
        let settings = store().settings

        XCTAssertEqual(settings.schemaVersion, 11)
        XCTAssertEqual(settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(settings.moduleEnablement, ["media": true, "clipboard": false, "app-volume": true])
        XCTAssertEqual(settings.hoverEnterDelay, 0.42, accuracy: 0.0001)
        XCTAssertTrue(settings.visualizerEnabled)
        XCTAssertFalse(settings.showMenuBarIcon)
        XCTAssertFalse(settings.preferMusicOverVideo)
        XCTAssertTrue(settings.capybaraThemeEnabled)
        XCTAssertEqual(settings.appVolume.tapsEnabled, true)
        XCTAssertEqual(settings.appVolume.volumes, ["com.hnc.Discord": 35, "webkit": 60])
        XCTAssertEqual(settings.appVolume.outputs, ["com.hnc.Discord": "usb-uid"])
        XCTAssertTrue(settings.spotifyKeychainCleanupPending, "a stored token is queued for cleanup")
        XCTAssertNil(defaults.data(forKey: SettingsStore.salvageKey), "nothing was unreadable")
    }

    /// A definite `false` was the Keychain itself saying there was no token,
    /// so the cleanup is not queued: that user's launch never touches the
    /// Keychain at all.
    func testV10DefiniteNoAccountDoesNotQueueTheCleanup() {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": false}"#)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending)
    }

    /// A fresh install cannot hold a token from a version it never ran, so
    /// it must never be sent to the Keychain.
    func testFreshInstallNeverQueuesTheCleanup() {
        XCTAssertFalse(AppSettings().spotifyKeychainCleanupPending)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending,
                       "nothing stored reads as a fresh install")
    }

    /// The removed key is not written back: the first save after upgrading
    /// persists v11's shape, and the cleared flag stays cleared.
    func testTheRemovedFlagIsNotWrittenBack() throws {
        write(#"{"schemaVersion": 10, "spotifyAccountConnected": true, "hoverEnterDelay": 0.5}"#)
        store().update { $0.spotifyKeychainCleanupPending = false }

        let data = try XCTUnwrap(defaults.data(forKey: SettingsStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["spotifyAccountConnected"], "the removed field must not be persisted")
        XCTAssertEqual(json["schemaVersion"] as? Int, 11)
        XCTAssertEqual(json["spotifyKeychainCleanupPending"] as? Bool, false)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending, "cleared survives a reload")
        XCTAssertEqual(store().settings.hoverEnterDelay, 0.5, "and nothing else moved")
    }

    /// Once a payload is v11, only the new key counts. A stray old key must
    /// not re-arm a cleanup that already ran, or the Keychain would be asked
    /// again on every launch.
    func testAV11PayloadIgnoresAStrayLegacyKey() {
        write(#"{"schemaVersion": 11, "spotifyKeychainCleanupPending": false, "spotifyAccountConnected": true}"#)
        XCTAssertFalse(store().settings.spotifyKeychainCleanupPending)
        write(#"{"schemaVersion": 11, "spotifyKeychainCleanupPending": true}"#)
        XCTAssertTrue(store().settings.spotifyKeychainCleanupPending, "a pending flag survives a reload")
    }
}
