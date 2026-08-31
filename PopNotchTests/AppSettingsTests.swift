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

    /// The whole point of the change: the Client ID is the app's own, so it is
    /// present without anyone configuring anything. A fresh install used to
    /// have no ID at all, which left Connect permanently disabled.
    func testBuiltInClientIDIsPresentOnAFreshInstall() {
        XCTAssertEqual(store().settings, AppSettings(), "fresh install, nothing persisted")
        XCTAssertFalse(SpotifyAccount.clientID.isEmpty,
                       "Connect must work with no user configuration")
    }
}
