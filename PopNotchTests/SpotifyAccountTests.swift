import XCTest
@testable import PopNotch

final class SpotifyAccountTests: XCTestCase {

    // MARK: - PKCE (RFC 7636)

    func testChallengeMatchesRFCTestVector() {
        // Appendix B of RFC 7636.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsBase64URLAndLongEnough() {
        let verifier = PKCE.verifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43, "RFC minimum")
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")),
                     "must be base64url, no padding")
        XCTAssertNotEqual(PKCE.verifier(), verifier, "must be random")
    }

    // MARK: - Loopback callback parsing

    func testExtractsCodeWithMatchingState() {
        let line = "GET /callback?code=AQD-abc123&state=xyz HTTP/1.1"
        XCTAssertEqual(PKCE.authCode(fromRequestLine: line, expectedState: "xyz"), "AQD-abc123")
    }

    func testRejectsWrongState() {
        let line = "GET /callback?code=AQD-abc123&state=forged HTTP/1.1"
        XCTAssertNil(PKCE.authCode(fromRequestLine: line, expectedState: "xyz"),
                     "state mismatch is a forgery; the code must be discarded")
    }

    func testIgnoresStrayRequests() {
        XCTAssertNil(PKCE.authCode(fromRequestLine: "GET /favicon.ico HTTP/1.1", expectedState: "xyz"))
        XCTAssertNil(PKCE.authCode(fromRequestLine: "", expectedState: "xyz"))
    }

    // MARK: - Track IDs

    func testTrackIDExtraction() {
        XCTAssertEqual(SpotifyWebAPI.trackID(fromURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC"),
                       "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertNil(SpotifyWebAPI.trackID(fromURI: "spotify:episode:abc"),
                     "episodes have no like endpoint")
        XCTAssertNil(SpotifyWebAPI.trackID(fromURI: "not a uri"))
    }

    // MARK: - Queue decoding

    func testUpNextFromQueueJSON() {
        let json = Data("""
        {"queue": [
            {"name": "3005", "artists": [{"name": "Childish Gambino"}]},
            {"name": "Later", "artists": [{"name": "Someone"}]}
        ]}
        """.utf8)
        let next = SpotifyWebAPI.upNext(fromQueueJSON: json)
        XCTAssertEqual(next?.title, "3005")
        XCTAssertEqual(next?.artist, "Childish Gambino")
    }

    func testUpNextJoinsMultipleArtists() {
        let json = Data(#"{"queue": [{"name": "X", "artists": [{"name": "A"}, {"name": "B"}]}]}"#.utf8)
        XCTAssertEqual(SpotifyWebAPI.upNext(fromQueueJSON: json)?.artist, "A, B")
    }

    func testEmptyQueueYieldsNil() {
        XCTAssertNil(SpotifyWebAPI.upNext(fromQueueJSON: Data(#"{"queue": []}"#.utf8)))
        XCTAssertNil(SpotifyWebAPI.upNext(fromQueueJSON: Data("garbage".utf8)))
    }
}
