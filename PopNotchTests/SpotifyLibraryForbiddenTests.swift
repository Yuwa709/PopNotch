import XCTest
@testable import PopNotch

/// The 403 state: a Spotify app in development mode returns **403 Forbidden**
/// from `/v1/me/tracks*` for any user not on its allowlist. The token is
/// valid and everything else works, so this is a capability fact about the
/// account, not an auth failure — and the like control must disappear rather
/// than sit there doing nothing.
///
/// No network here: the flag is driven through the same entry point
/// `SpotifyWebAPI` calls on a 403.
@MainActor
final class SpotifyLibraryForbiddenTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Connected, with the Keychain never consulted.
    private func connectedAccount() -> SpotifyAccount {
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.spotifyAccountConnected = true }
        return SpotifyAccount(settings: settings, storage: .inMemory("token"))
    }

    /// A Spotify-owned playing track, so `activeSource` is set the way a
    /// real adapter sets it.
    private func playingTrack() -> NowPlaying {
        var track = NowPlaying()
        track.title = "Track"
        track.artist = "Artist"
        track.isPlaying = true
        track.sourceBundleID = "com.spotify.client"
        return track
    }

    // MARK: - Storage

    func testStartsPermitted() {
        XCTAssertFalse(connectedAccount().libraryAccessForbidden)
    }

    func testA403RecordsTheRefusal() {
        let account = connectedAccount()
        account.noteLibraryAccessForbidden()
        XCTAssertTrue(account.libraryAccessForbidden)
    }

    /// Idempotent: repeated refusals are one fact, not a counter, and must
    /// not drive any retry of their own.
    func testRepeatedRefusalsAreIdempotent() {
        let account = connectedAccount()
        account.noteLibraryAccessForbidden()
        account.noteLibraryAccessForbidden()
        account.noteLibraryAccessForbidden()
        XCTAssertTrue(account.libraryAccessForbidden)
    }

    /// Session-only. A relaunch retries once — allowlisting happens in
    /// Spotify's dashboard with no signal back to the app, so persisting
    /// this would hide the control from a user who had since been granted
    /// access, with no way back short of resetting settings.
    func testTheRefusalIsNotPersisted() {
        let settings = SettingsStore(defaults: defaults)
        settings.update { $0.spotifyAccountConnected = true }
        let first = SpotifyAccount(settings: settings, storage: .inMemory("t"))
        first.noteLibraryAccessForbidden()
        XCTAssertTrue(first.libraryAccessForbidden)

        // A fresh launch against the same stored settings.
        let second = SpotifyAccount(settings: SettingsStore(defaults: defaults),
                                    storage: .inMemory("t"))
        XCTAssertFalse(second.libraryAccessForbidden,
                       "a relaunch must retry once, not stay hidden forever")
    }

    // MARK: - Reset

    /// Disconnecting is a change of account; the refusal belonged to the old
    /// one. This is the in-session recovery path for a user who gets
    /// allowlisted and reconnects.
    func testDisconnectClearsTheRefusal() {
        let account = connectedAccount()
        account.noteLibraryAccessForbidden()

        account.disconnect()

        XCTAssertFalse(account.libraryAccessForbidden)
    }

    // MARK: - What the UI does with it

    /// The control is hidden, not disabled: `canToggleFavorite` goes false
    /// while the account is otherwise perfectly connected.
    func testForbiddenAccountCannotToggleFavorite() {
        let account = connectedAccount()
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify], account: account)
        spotify.publish(playingTrack())

        XCTAssertTrue(module.accountConnected, "still connected — this is not an auth failure")
        XCTAssertTrue(module.canToggleFavorite, "precondition")

        account.noteLibraryAccessForbidden()

        XCTAssertTrue(module.accountConnected, "must not log the user out")
        XCTAssertTrue(module.libraryForbidden)
        XCTAssertFalse(module.canToggleFavorite, "the control must disappear")
    }

    /// And `toggleLike` becomes inert, so a stale view cannot fire a write
    /// at an endpoint that has already refused.
    func testToggleLikeIsInertWhenForbidden() {
        let account = connectedAccount()
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify], account: account)
        spotify.publish(playingTrack())
        account.noteLibraryAccessForbidden()

        module.toggleLike()

        XCTAssertNil(module.likedCurrent, "no optimistic value for a control that is gone")
    }
}
