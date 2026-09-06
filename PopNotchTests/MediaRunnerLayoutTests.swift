import XCTest
@testable import PopNotch

/// The capybara scrub-bar geometry. Pure functions, so the two invariants the
/// feature was specified with are tests rather than a screenshot: the row is
/// untouched when the theme is off, and the runner never leaves the track.
@MainActor
final class MediaRunnerLayoutTests: XCTestCase {

    // MARK: - Row height

    func testOffThemeRowIsTheOriginalFourteenPoints() {
        XCTAssertEqual(MediaRunnerLayout.rowHeight(themed: false), 14)
    }

    func testThemedRowFitsTheRunnerStandingOnTheTrack() {
        // 20pt runner + 6pt track + the 4pt that always sat under the track.
        XCTAssertEqual(MediaRunnerLayout.rowHeight(themed: true), 30)
        XCTAssertEqual(MediaRunnerLayout.rowHeight(themed: true) - MediaRunnerLayout.rowHeight(themed: false),
                       16, "exactly how much the expanded panel grows")
    }

    func testRunnerWidthFollowsTheAssetAspect() {
        // 25×16 at 1x, drawn 20pt tall.
        XCTAssertEqual(MediaRunnerLayout.runnerWidth, 31.25, accuracy: 0.001)
    }

    // MARK: - Runner position

    func testRunnerIsCentredOnThePlayheadMidTrack() {
        let x = MediaRunnerLayout.runnerOriginX(fraction: 0.5, trackWidth: 200, runnerWidth: 30)
        XCTAssertEqual(x, 85, accuracy: 0.001, "centre 100, less half the runner")
    }

    func testRunnerNeverOverhangsEitherEnd() {
        XCTAssertEqual(MediaRunnerLayout.runnerOriginX(fraction: 0, trackWidth: 200, runnerWidth: 30), 0)
        XCTAssertEqual(MediaRunnerLayout.runnerOriginX(fraction: 1, trackWidth: 200, runnerWidth: 30), 170)
        XCTAssertEqual(MediaRunnerLayout.runnerOriginX(fraction: 0.05, trackWidth: 200, runnerWidth: 30), 0,
                       "clamped at the start")
        XCTAssertEqual(MediaRunnerLayout.runnerOriginX(fraction: 0.98, trackWidth: 200, runnerWidth: 30), 170,
                       "clamped at the flag")
    }

    func testRunnerStaysPutOnATrackNarrowerThanItself() {
        XCTAssertEqual(MediaRunnerLayout.runnerOriginX(fraction: 1, trackWidth: 10, runnerWidth: 30), 0)
    }

    // MARK: - Reflow

    /// The row changes height with the theme, so the open panel must be
    /// re-measured on a flip — and only on a flip, never on a no-op set.
    func testFlippingTheThemeReflowsTheOpenPanelOnce() {
        let module = MediaModule(sources: [])
        var reflows = 0
        module.onContentReflow = { reflows += 1 }

        module.capybaraThemeEnabled = true
        module.capybaraThemeEnabled = true   // unchanged: no reflow
        module.capybaraThemeEnabled = false

        XCTAssertEqual(reflows, 2)
        XCTAssertFalse(module.capybaraThemeEnabled)
    }
}
