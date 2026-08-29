import XCTest
@testable import PopNotch

final class SpotifyMetadataTests: XCTestCase {

    // MARK: - Count formatting

    func testShortCounts() {
        XCTAssertEqual(CountFormatter.short(950), "950")
        XCTAssertEqual(CountFormatter.short(1_500), "1.5K")
        XCTAssertEqual(CountFormatter.short(31_700_000), "31.7M")
        XCTAssertEqual(CountFormatter.short(2_200_000_000), "2.2B")
    }

    func testZeroCount() {
        XCTAssertEqual(CountFormatter.short(0), "0")
    }

    // MARK: - Track detail

    func testTrackDetailExtractsPopularityAndArtist() {
        let json = Data(#"{"popularity": 87, "artists": [{"id": "abc123"}, {"id": "def"}]}"#.utf8)
        let detail = SpotifyWebAPI.trackDetail(fromJSON: json)
        XCTAssertEqual(detail?.popularity, 87)
        XCTAssertEqual(detail?.artistID, "abc123", "primary artist wins")
    }

    func testTrackDetailWithoutArtistsIsNil() {
        XCTAssertNil(SpotifyWebAPI.trackDetail(fromJSON: Data(#"{"popularity": 5, "artists": []}"#.utf8)))
        XCTAssertNil(SpotifyWebAPI.trackDetail(fromJSON: Data("garbage".utf8)))
    }

    // MARK: - Artist info

    private let artistJSON = Data("""
    {"name": "Childish Gambino",
     "followers": {"total": 31700000},
     "genres": ["hip hop", "funk"],
     "images": [{"url": "https://i.scdn.co/big", "width": 640},
                {"url": "https://i.scdn.co/mid", "width": 320},
                {"url": "https://i.scdn.co/small", "width": 64}]}
    """.utf8)

    func testArtistInfoDecodes() {
        let info = SpotifyWebAPI.artistInfo(fromJSON: artistJSON)
        XCTAssertEqual(info?.name, "Childish Gambino")
        XCTAssertEqual(info?.followers, 31_700_000)
        XCTAssertEqual(info?.genres, ["hip hop", "funk"])
    }

    func testArtistImagePicksSmallestStillCrisp() {
        // Avatar renders ~15pt; the 320 is the smallest at or above 120.
        XCTAssertEqual(SpotifyWebAPI.artistInfo(fromJSON: artistJSON)?.imageURL,
                       "https://i.scdn.co/mid")
    }

    func testArtistWithoutImagesOrFollowers() {
        let json = Data(#"{"name": "Someone"}"#.utf8)
        let info = SpotifyWebAPI.artistInfo(fromJSON: json)
        XCTAssertEqual(info?.name, "Someone")
        XCTAssertEqual(info?.followers, 0, "absent follower count reads as zero, and the UI hides it")
        XCTAssertNil(info?.imageURL)
    }

    func testGarbageArtistJSONIsNil() {
        XCTAssertNil(SpotifyWebAPI.artistInfo(fromJSON: Data("not json".utf8)))
    }

    // MARK: - Error body logging
    //
    // A bare 403 with no reason cost a full diagnostic round. Spotify puts
    // the reason in the body, so the body has to reach the log intact.

    func testRealSpotifyErrorBodySurvivesIntact() {
        let body = Data(##"{"error":{"status":403,"message":"Insufficient client scope"}}"##.utf8)
        let rendered = SpotifyWebAPI.describeErrorBody(body)
        XCTAssertTrue(rendered.contains("Insufficient client scope"),
                      "the reason is the entire point of logging the body")
        XCTAssertTrue(rendered.contains("403"))
    }

    func testEmptyAndNilBodiesAreLabelled() {
        // A 204 never reaches here, but an empty body on a real error must
        // read as "empty", not as a missing log line.
        XCTAssertEqual(SpotifyWebAPI.describeErrorBody(nil), "<empty body>")
        XCTAssertEqual(SpotifyWebAPI.describeErrorBody(Data()), "<empty body>")
    }

    func testNonUTF8BodyIsDescribedNotMangled() {
        let bytes = Data([0xFF, 0xFE, 0xFD, 0x00])
        XCTAssertEqual(SpotifyWebAPI.describeErrorBody(bytes), "<4 bytes, not UTF-8>")
    }

    func testNewlinesCollapseToOneLogLine() {
        let body = Data("{\n  \"error\": 1\n}".utf8)
        let rendered = SpotifyWebAPI.describeErrorBody(body)
        XCTAssertFalse(rendered.contains("\n"), "a multi-line body must not fragment the log")
    }

    func testOversizedBodyIsTruncatedAndSaysSo() {
        let body = Data(String(repeating: "x", count: 2000).utf8)
        let rendered = SpotifyWebAPI.describeErrorBody(body)
        XCTAssertTrue(rendered.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertTrue(rendered.contains("truncated from 2000 chars"))
        XCTAssertLessThan(rendered.count, 600, "an HTML error page must not swamp the log")
    }

    func testBodyAtTheLimitIsNotTruncated() {
        let body = Data(String(repeating: "y", count: SpotifyWebAPI.bodyLogLimit).utf8)
        let rendered = SpotifyWebAPI.describeErrorBody(body)
        XCTAssertFalse(rendered.contains("truncated"))
        XCTAssertEqual(rendered.count, SpotifyWebAPI.bodyLogLimit)
    }

    // MARK: - Playback context
    //
    // Drives the artwork tap: the context is where the user actually started
    // playing, so it beats the track URI's canonical album page.

    func testContextURIReadsPlaylist() {
        let json = Data(##"{"context": {"type": "playlist", "uri": "spotify:playlist:37i9dQZF1"}, "item": {"name": "3005"}}"##.utf8)
        XCTAssertEqual(SpotifyWebAPI.contextURI(fromPlayerJSON: json),
                       "spotify:playlist:37i9dQZF1")
    }

    func testContextURIReadsLikedSongsCollection() {
        let json = Data(##"{"context": {"uri": "spotify:collection:tracks"}}"##.utf8)
        XCTAssertEqual(SpotifyWebAPI.contextURI(fromPlayerJSON: json),
                       "spotify:collection:tracks")
    }

    func testNullContextIsNil() {
        // Autoplay and radio report no context. The caller falls back to the track.
        let json = Data(##"{"context": null, "item": {"name": "3005"}}"##.utf8)
        XCTAssertNil(SpotifyWebAPI.contextURI(fromPlayerJSON: json))
    }

    func testEmptyContextURIIsNil() {
        let json = Data(##"{"context": {"uri": ""}}"##.utf8)
        XCTAssertNil(SpotifyWebAPI.contextURI(fromPlayerJSON: json),
                     "an empty string would open nothing; treat it as absent")
    }

    func testGarbagePlayerJSONIsNil() {
        XCTAssertNil(SpotifyWebAPI.contextURI(fromPlayerJSON: Data("not json".utf8)))
    }
}
