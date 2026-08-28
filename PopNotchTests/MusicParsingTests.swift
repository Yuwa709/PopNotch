import XCTest
@testable import PopNotch

/// Music.app's query output. The two things most likely to break quietly are
/// the duration unit (seconds here, milliseconds in Spotify) and the Up Next
/// refusal cases, so both are asserted directly.
final class MusicParsingTests: XCTestCase {

    /// Field order matches MusicAdapter.queryScript.
    private func output(
        state: String = "playing",
        duration: String = "212.45",
        position: String = "12.607",
        favorited: String = "false",
        nextTitle: String = "Sweatpants",
        nextArtist: String = "Childish Gambino",
        reason: String = ""
    ) -> String {
        [state, "3005", "Childish Gambino", "because the internet",
         duration, position, "A1B2C3D4E5F6", favorited,
         nextTitle, nextArtist, reason].joined(separator: "\n")
    }

    // MARK: - Core fields

    func testParsesTrackFields() {
        let parsed = MusicParsing.parse(scriptOutput: output())
        XCTAssertEqual(parsed?.snapshot.title, "3005")
        XCTAssertEqual(parsed?.snapshot.artist, "Childish Gambino")
        XCTAssertEqual(parsed?.snapshot.album, "because the internet")
        XCTAssertEqual(parsed?.snapshot.isPlaying, true)
        XCTAssertEqual(parsed?.snapshot.artworkIdentifier, "A1B2C3D4E5F6")
        XCTAssertEqual(parsed?.snapshot.sourceBundleID, MusicAdapter.bundleID)
    }

    func testDurationIsSecondsNotMilliseconds() {
        // Music's dictionary: "the length of the track in seconds". Spotify
        // reports milliseconds. Dividing here would give a 1000x progress bar.
        let parsed = MusicParsing.parse(scriptOutput: output())
        XCTAssertEqual(parsed?.snapshot.duration ?? -1, 212.45, accuracy: 0.001)
        XCTAssertEqual(parsed?.snapshot.elapsed ?? -1, 12.607, accuracy: 0.001)
    }

    func testCommaDecimalLocale() {
        let parsed = MusicParsing.parse(scriptOutput: output(duration: "212,45", position: "12,607"))
        XCTAssertEqual(parsed?.snapshot.duration ?? -1, 212.45, accuracy: 0.001)
        XCTAssertEqual(parsed?.snapshot.elapsed ?? -1, 12.607, accuracy: 0.001)
    }

    func testStoppedParsesToNil() {
        XCTAssertNil(MusicParsing.parse(scriptOutput: "stopped"))
    }

    func testTruncatedOutputParsesToNil() {
        XCTAssertNil(MusicParsing.parse(scriptOutput: "playing\n3005\nChildish Gambino"))
    }

    func testPausedIsContentButNotPlaying() {
        let parsed = MusicParsing.parse(scriptOutput: output(state: "paused"))
        XCTAssertEqual(parsed?.snapshot.isPlaying, false)
        XCTAssertEqual(parsed?.snapshot.hasContent, true, "paused music still displays")
    }

    // MARK: - Favourite

    func testFavoritedParses() {
        XCTAssertEqual(MusicParsing.parse(scriptOutput: output(favorited: "true"))?.favorited, true)
        XCTAssertEqual(MusicParsing.parse(scriptOutput: output(favorited: "false"))?.favorited, false)
    }

    // MARK: - Up Next

    func testUpNextWhenPlaylistOrderIsTrustworthy() {
        let parsed = MusicParsing.parse(scriptOutput: output())
        XCTAssertEqual(parsed?.upNext, UpNextTrack(title: "Sweatpants", artist: "Childish Gambino"))
        XCTAssertNil(parsed?.upNextSkipReason)
    }

    func testShuffleSuppressesUpNext() {
        // index + 1 is not the next track to play when order is randomised.
        let parsed = MusicParsing.parse(
            scriptOutput: output(nextTitle: "", nextArtist: "", reason: "shuffle"))
        XCTAssertNil(parsed?.upNext)
        XCTAssertEqual(parsed?.upNextSkipReason, "shuffle")
    }

    func testFixedIndexingSuppressesUpNext() {
        // The dictionary defines fixed indexing as making indices independent
        // of play order, which is the exact guarantee this lookup needs.
        let parsed = MusicParsing.parse(
            scriptOutput: output(nextTitle: "", nextArtist: "", reason: "fixed-indexing"))
        XCTAssertNil(parsed?.upNext)
        XCTAssertEqual(parsed?.upNextSkipReason, "fixed-indexing")
    }

    func testLastTrackInPlaylistHasNoUpNext() {
        let parsed = MusicParsing.parse(
            scriptOutput: output(nextTitle: "", nextArtist: "", reason: "last-in-playlist"))
        XCTAssertNil(parsed?.upNext)
        XCTAssertEqual(parsed?.upNextSkipReason, "last-in-playlist")
    }

    func testNoPlaylistContextHasNoUpNext() {
        let parsed = MusicParsing.parse(
            scriptOutput: output(nextTitle: "", nextArtist: "", reason: "no-playlist"))
        XCTAssertNil(parsed?.upNext)
        XCTAssertEqual(parsed?.upNextSkipReason, "no-playlist")
    }

    func testUpNextKeepsTitleWhenArtistIsBlank() {
        let parsed = MusicParsing.parse(scriptOutput: output(nextArtist: ""))
        XCTAssertEqual(parsed?.upNext?.title, "Sweatpants")
        XCTAssertEqual(parsed?.upNext?.artist, "")
    }
}

/// Spotify's dictionary has no queue and a read-only `starred`; these lock in
/// that the adapter reports those limits rather than faking past them.
final class SpotifyCapabilityTests: XCTestCase {

    /// Eight fields exactly. A ninth (`starred`) was added and reverted:
    /// Spotify does not implement that handler, and one failing property
    /// aborts the whole AppleScript `return`, so all eight working fields —
    /// artwork among them — were lost with it.
    func testParsesTheEightFieldOutput() {
        let output = ["playing", "3005", "Childish Gambino", "because the internet",
                      "212450", "12.607", "https://i.scdn.co/x", "spotify:track:abc"]
            .joined(separator: "\n")
        let parsed = SpotifyParsing.parse(scriptOutput: output)
        XCTAssertEqual(parsed?.snapshot.title, "3005")
        XCTAssertEqual(parsed?.artworkURL, "https://i.scdn.co/x")
    }

    @MainActor
    func testQueryScriptDoesNotAskForStarred() {
        // The regression guard. Reading `starred` throws -10000 against the
        // live app, which takes artwork down with it.
        XCTAssertFalse(SpotifyAdapter.queryScriptSource.contains("starred"),
                       "starred is unimplemented by Spotify; it must never return to the query")
    }

    @MainActor
    func testSpotifyAdapterHasNoFavoriteState() {
        // Not .readOnly — unavailable. With an account connected the Web API
        // owns the like, and MediaModule never consults this.
        XCTAssertEqual(SpotifyAdapter().favorite, .unsupported)
        XCTAssertNil(SpotifyAdapter().favorite.value)
    }

    @MainActor
    func testSpotifyAdapterNeverReportsUpNext() {
        // Its dictionary has no playlist, context, or queue class at all.
        XCTAssertNil(SpotifyAdapter().upNext)
    }

    func testReadOnlyFavoriteIsNotEditable() {
        XCTAssertFalse(FavoriteState.readOnly(true).isEditable)
        XCTAssertTrue(FavoriteState.editable(true).isEditable)
        XCTAssertEqual(FavoriteState.readOnly(true).value, true)
        XCTAssertNil(FavoriteState.unsupported.value)
    }
}
