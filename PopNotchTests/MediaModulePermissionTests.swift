import XCTest
@testable import PopNotch

/// A controllable MediaSource for exercising MediaModule logic without
/// AppleScript, players, or the network.
@MainActor
final class StubMediaSource: MediaSource {
    let sourceID: String
    var isPlayerRunning: Bool
    var permissionDenied: Bool
    var onUpdate: ((NowPlaying?) -> Void)?

    init(id: String, running: Bool = false, denied: Bool = false) {
        sourceID = id
        isPlayerRunning = running
        permissionDenied = denied
    }

    /// Commands the module routed here, for asserting command routing.
    private(set) var sent: [MediaCommand] = []

    func startObserving() {}
    func stopObserving() {}
    func refresh() {}
    func send(_ command: MediaCommand) { sent.append(command) }
    func seek(to seconds: TimeInterval) {}

    /// Drives the module's real update path, exactly as an adapter would.
    func publish(_ snapshot: NowPlaying?) { onUpdate?(snapshot) }
}

/// The in-notch permission banner shows only when a RUNNING player is
/// denied — that is the only case where denial explains an empty widget.
@MainActor
final class MediaModulePermissionTests: XCTestCase {

    func testDeniedRunningPlayerSurfacesBanner() {
        // The regression: Spotify denied while Music's flag is still false.
        // allSatisfy hid the banner; the rule is "any running player denied".
        let spotify = StubMediaSource(id: "spotify", running: true, denied: true)
        let music = StubMediaSource(id: "music", running: false, denied: false)
        let module = MediaModule(sources: [spotify, music])
        XCTAssertTrue(module.permissionDenied)
    }

    func testDeniedButClosedPlayerDoesNotSurfaceBanner() {
        // Granting a closed player would display nothing; the widget is
        // empty because nothing is playing. The Permissions tab owns this.
        let spotify = StubMediaSource(id: "spotify", running: false, denied: true)
        let module = MediaModule(sources: [spotify])
        XCTAssertFalse(module.permissionDenied)
    }

    func testRunningGrantedPlayerDoesNotSurfaceBanner() {
        let spotify = StubMediaSource(id: "spotify", running: true, denied: false)
        let module = MediaModule(sources: [spotify])
        XCTAssertFalse(module.permissionDenied)
    }

    func testNeverProbedSecondPlayerDoesNotMaskADenial() {
        // Music running but never probed (flag false) must not hide
        // Spotify's real denial.
        let spotify = StubMediaSource(id: "spotify", running: true, denied: true)
        let music = StubMediaSource(id: "music", running: true, denied: false)
        let module = MediaModule(sources: [spotify, music])
        XCTAssertTrue(module.permissionDenied)
    }

    func testNoSourcesMeansNoBanner() {
        XCTAssertFalse(MediaModule(sources: []).permissionDenied)
    }
}
