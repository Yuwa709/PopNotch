import XCTest
@testable import PopNotch

/// The cached connected flag: the thing that keeps launch away from the
/// Keychain, and the migration that must not log existing users out.
///
/// These tests never touch the real Keychain. They assert on which branch
/// `SpotifyAccount.init` takes, which is observable from the flag it leaves
/// behind in a scratch settings store.
@MainActor
final class SpotifyConnectionFlagTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.techie.PopNotch.spotifyflagtests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store() -> SettingsStore { SettingsStore(defaults: defaults) }

    /// A counting wrapper that never reaches the real Keychain.
    private final class Probe {
        private(set) var lookups = 0
        private(set) var deletes = 0
        let storage: SpotifyTokenStorage

        init(_ base: SpotifyTokenStorage) {
            var wrapped = base
            var lookupCount = 0
            var deleteCount = 0
            wrapped.lookup = { lookupCount += 1; return base.lookup() }
            wrapped.delete = { deleteCount += 1; base.delete() }
            self.storage = wrapped
            self.readLookups = { lookupCount }
            self.readDeletes = { deleteCount }
        }
        private let readLookups: () -> Int
        private let readDeletes: () -> Int
        func refresh() { lookups = readLookups(); deletes = readDeletes() }
    }

    private func probe(_ token: String?) -> Probe { Probe(.inMemory(token)) }

    /// A store that reports the Keychain as unreachable.
    private var unavailable: SpotifyTokenStorage {
        SpotifyTokenStorage(lookup: { .unavailable(errSecInteractionNotAllowed) },
                            save: { _ in }, delete: {})
    }

    // MARK: - The cached flag is authoritative

    /// The case the whole change exists for: a recorded `false` answers the
    /// question outright, so launch performs no Keychain access at all.
    func testCachedFalseIsUsedWithoutConsultingTheKeychain() {
        let settings = store()
        settings.update { $0.spotifyAccountConnected = false }

        let p = probe("t")
        let account = SpotifyAccount(settings: settings, storage: p.storage)

        XCTAssertFalse(account.isConnected)
        p.refresh()
        XCTAssertEqual(p.lookups, 0, "a cached answer must not reach the Keychain at all")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, false,
                       "the cached answer is kept, not re-derived")
    }

    /// A recorded `true` is equally authoritative: a connected user must not
    /// be sent to the Keychain merely to be told what is already known.
    func testCachedTrueIsUsedWithoutConsultingTheKeychain() {
        let settings = store()
        settings.update { $0.spotifyAccountConnected = true }

        let p = probe(nil)
        let account = SpotifyAccount(settings: settings, storage: p.storage)

        XCTAssertTrue(account.isConnected)
        p.refresh()
        XCTAssertEqual(p.lookups, 0, "a cached answer must not reach the Keychain at all")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, true)
    }

    // MARK: - Migration: the flag is absent

    /// **The migration case.** An install upgraded from v6, or a fresh
    /// install whose settings were never written, has no flag. A user whose
    /// token outlived the app bundle must come back connected, and the
    /// answer must be recorded so the fallback happens at most once.
    func testAbsentFlagWithATokenKeepsTheUserConnected() {
        let settings = store()
        XCTAssertNil(settings.settings.spotifyAccountConnected, "precondition: never recorded")
        let p = probe("a-refresh-token")

        let account = SpotifyAccount(settings: settings, storage: p.storage)

        XCTAssertTrue(account.isConnected, "an upgrading user must not appear logged out")
        p.refresh()
        XCTAssertEqual(p.lookups, 1, "exactly one Keychain read")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, true, "and it is recorded")
    }

    func testAbsentFlagWithNoTokenRecordsNotConnected() {
        let settings = store()
        let p = probe(nil)

        let account = SpotifyAccount(settings: settings, storage: p.storage)

        XCTAssertFalse(account.isConnected)
        p.refresh()
        XCTAssertEqual(p.lookups, 1)
        XCTAssertEqual(settings.settings.spotifyAccountConnected, false)
    }

    /// The fallback runs once: the next launch takes the cached branch and
    /// never touches the Keychain again.
    func testFallbackHappensOnceAndTheNextLaunchDoesNotLookUpAgain() {
        let settings = store()
        let p = probe("t")

        _ = SpotifyAccount(settings: settings, storage: p.storage)
        p.refresh()
        XCTAssertEqual(p.lookups, 1)

        let second = SpotifyAccount(settings: settings, storage: p.storage)

        p.refresh()
        XCTAssertEqual(p.lookups, 1, "a cached flag must not consult the Keychain")
        XCTAssertTrue(second.isConnected)
    }

    /// A Keychain that refuses to answer — denied prompt, locked keychain,
    /// no interaction allowed — says nothing about whether a token exists.
    /// Caching `false` there would log a connected user out permanently,
    /// because a cached flag is never re-checked. It must stay unrecorded.
    func testUnavailableKeychainIsNotCachedSoTheNextLaunchRetries() {
        let settings = store()
        let p = Probe(unavailable)

        let account = SpotifyAccount(settings: settings, storage: p.storage)

        XCTAssertFalse(account.isConnected, "no token is reachable this session")
        XCTAssertNil(settings.settings.spotifyAccountConnected,
                     "a failed read must never be recorded as 'no account'")
        p.refresh()
        XCTAssertEqual(p.lookups, 1)

        // Next launch: the Keychain is available again and the user is back.
        let recovered = SpotifyAccount(settings: settings, storage: .inMemory("t"))
        XCTAssertTrue(recovered.isConnected, "the user must be recoverable")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, true)
    }

    /// The status split itself: only a definitive answer is cacheable.
    func testLookupClassifiesStatusesCorrectly() {
        XCTAssertEqual(SpotifyTokenStore.Lookup.absent, .absent)
        XCTAssertNotEqual(SpotifyTokenStore.Lookup.absent,
                          .unavailable(errSecInteractionNotAllowed))
        XCTAssertNotEqual(SpotifyTokenStore.Lookup.found("a"),
                          SpotifyTokenStore.Lookup.found("b"))
    }

    /// Nil is a third state, not a synonym for false. This is the assertion
    /// that fails if anyone ever changes the property to a plain `Bool`.
    func testAbsentFlagIsDistinctFromFalse() {
        let fresh = AppSettings()
        XCTAssertNil(fresh.spotifyAccountConnected,
                     "a fresh struct must not claim to know the answer")
    }

    // MARK: - Writing the flag

    /// Disconnecting records the answer, so the next launch skips the
    /// Keychain rather than falling back again.
    func testDisconnectRecordsNotConnected() {
        let settings = store()
        settings.update { $0.spotifyAccountConnected = true }
        let account = SpotifyAccount(settings: settings, storage: .inMemory(nil))

        account.disconnect()

        XCTAssertFalse(account.isConnected)
        XCTAssertEqual(settings.settings.spotifyAccountConnected, false)
    }

    /// No settings store at all (tests, previews) must still work — it falls
    /// back to the old behaviour rather than crashing or claiming connected.
    func testWithoutASettingsStoreItStillResolves() {
        let connected = SpotifyAccount(settings: nil, storage: .inMemory("t"))
        XCTAssertTrue(connected.isConnected)
        let absent = SpotifyAccount(settings: nil, storage: .inMemory(nil))
        XCTAssertFalse(absent.isConnected)
    }

    /// **Regression, 2026-09-01.** `disconnect()` used to call
    /// `SpotifyTokenStore.delete()` directly, so running this very test
    /// deleted the developer's real Spotify refresh token from the login
    /// keychain. Every Keychain operation now goes through the injected
    /// storage; this asserts the delete lands there and nowhere else.
    func testDisconnectDeletesOnlyThroughTheInjectedStorage() {
        let settings = store()
        var deletes = 0
        var realKeychainTouched = false
        let storage = SpotifyTokenStorage(
            lookup: { .found("t") },
            save: { _ in realKeychainTouched = true },
            delete: { deletes += 1 })

        let account = SpotifyAccount(settings: settings, storage: storage)
        account.disconnect()

        XCTAssertEqual(deletes, 1, "the delete must go to the injected store")
        XCTAssertFalse(realKeychainTouched)
        XCTAssertFalse(account.isConnected)
        XCTAssertEqual(settings.settings.spotifyAccountConnected, false)
    }

    // MARK: - Drift between the flag and the Keychain

    /// A token deleted behind the app's back leaves the cached flag stale.
    /// The next token request must notice and correct it, or Settings offers
    /// a connected account that cannot fetch anything.
    func testDefinitivelyMissingTokenCorrectsTheCachedFlag() async {
        let settings = store()
        settings.update { $0.spotifyAccountConnected = true }
        let account = SpotifyAccount(settings: settings, storage: .inMemory(nil))
        XCTAssertTrue(account.isConnected, "starts from the cached flag")

        let token = await account.validAccessToken()

        XCTAssertNil(token)
        XCTAssertFalse(account.isConnected, "corrected once the Keychain answered")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, false)
    }

    /// But an unreachable Keychain must NOT correct anything — that is the
    /// locked-keychain case, and forgetting the account there is the bug the
    /// tri-state flag exists to prevent.
    func testUnavailableKeychainDoesNotClearACachedConnection() async {
        let settings = store()
        settings.update { $0.spotifyAccountConnected = true }
        let account = SpotifyAccount(settings: settings, storage: unavailable)

        let token = await account.validAccessToken()

        XCTAssertNil(token, "no token is reachable")
        XCTAssertEqual(settings.settings.spotifyAccountConnected, true,
                       "a locked Keychain must not log the user out")
    }
}
