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
