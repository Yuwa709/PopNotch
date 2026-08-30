import XCTest
@testable import PopNotch

/// The capture path needs a real audio stream and Screen Recording, so what
/// is tested here is the pure part: folding FFT bins into the bands a view
/// would draw.
final class AudioVisualizerBandTests: XCTestCase {

    private let bandCount = AudioVisualizerService.bandCount

    func testProducesExactlyTheRequestedBandCount() {
        let bins = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: bins, into: bandCount).count, bandCount)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: bins, into: 4).count, 4)
    }

    func testEmptyInputIsSafeAndSilent() {
        // A dropped or malformed buffer must yield silence, not a crash and
        // not stale bars.
        let bands = AudioVisualizerService.fold(magnitudes: [], into: bandCount)
        XCTAssertEqual(bands.count, bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    func testZeroBandsRequestedIsSafe() {
        XCTAssertTrue(AudioVisualizerService.fold(magnitudes: [1, 2, 3], into: 0).isEmpty)
    }

    func testSilenceFloorsAllBands() {
        // log10 of ~0 must clamp, not produce -inf or NaN in a view.
        let bands = AudioVisualizerService.fold(magnitudes: [Float](repeating: 0, count: 512),
                                                into: bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 }, "digital silence must read as zero")
        XCTAssertTrue(bands.allSatisfy { $0.isFinite }, "no -inf or NaN may reach the view")
    }

    func testEveryBandStaysInUnitRange() {
        // Deliberately absurd magnitudes: the view draws bar heights from
        // these, so anything outside 0...1 would overdraw the panel.
        let loud = [Float](repeating: 10_000, count: 512)
        let bands = AudioVisualizerService.fold(magnitudes: loud, into: bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "bands must be normalised")
    }

    func testBandsAreLogSpacedNotLinear() {
        // Energy only in the lowest bins must light the low bands and leave
        // the high ones dark. With linear spacing it would all land in band 0.
        var bins = [Float](repeating: 0, count: 512)
        for i in 0..<8 { bins[i] = 1 }
        let bands = AudioVisualizerService.fold(magnitudes: bins, into: bandCount)
        XCTAssertGreaterThan(bands[0], 0, "low-frequency energy must reach the first band")
        XCTAssertEqual(bands[bandCount - 1], 0, "and must not leak into the top band")
    }

    func testHighFrequencyEnergyLandsHigh() {
        var bins = [Float](repeating: 0, count: 512)
        for i in 480..<512 { bins[i] = 1 }
        let bands = AudioVisualizerService.fold(magnitudes: bins, into: bandCount)
        XCTAssertGreaterThan(bands[bandCount - 1], 0, "top bins must reach the top band")
        XCTAssertEqual(bands[0], 0, "and must not leak into the first band")
    }

    func testLouderInputGivesHigherBands() {
        let quiet = AudioVisualizerService.fold(magnitudes: [Float](repeating: 0.01, count: 512),
                                                into: bandCount)
        let loud = AudioVisualizerService.fold(magnitudes: [Float](repeating: 1.0, count: 512),
                                               into: bandCount)
        XCTAssertGreaterThan(loud[8], quiet[8], "the bands must actually track level")
    }
}

/// Off by default, and never running when nobody is looking.
@MainActor
final class AudioVisualizerLifecycleTests: XCTestCase {

    func testOffByDefaultAndNotRunning() {
        let service = AudioVisualizerService()
        XCTAssertFalse(service.isEnabled, "capture must never start unasked")
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.lastError)
    }

    func testBandsStartSilent() {
        let service = AudioVisualizerService()
        XCTAssertEqual(service.bands.count, AudioVisualizerService.bandCount)
        XCTAssertTrue(service.bands.allSatisfy { $0 == 0 })
    }

    func testEnablingWithoutAVisiblePanelDoesNotRun() {
        // Both conditions are required: enabled AND on screen.
        let service = AudioVisualizerService()
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.isRunning, "an invisible panel must not capture audio")
    }

    func testDisablingClearsRunningState() {
        let service = AudioVisualizerService()
        service.setEnabled(true)
        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isRunning)
    }

    func testPanelHiddenWhileEnabledStopsCapture() {
        let service = AudioVisualizerService()
        service.setEnabled(true)
        service.setPanelVisible(true)
        service.setPanelVisible(false)
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Playback gate
    //
    // The tap is whole-system, so it is gated on the tracked player. Without
    // this the bars would dance to a YouTube tab or a notification chime
    // while the notch showed a paused track.
    //
    // These deliberately never set all three conditions true at once: doing
    // so would open a real system-audio tap inside the test process.

    func testEnabledAndVisibleButNotPlayingDoesNotCapture() {
        let service = AudioVisualizerService()
        service.setEnabled(true)
        service.setPanelVisible(true)
        XCTAssertFalse(service.isRunning,
                       "nothing playing means no tap, however visible the panel is")
    }

    func testPlayingAloneDoesNotCapture() {
        // Playback is necessary, not sufficient: the panel must be open and
        // the feature enabled.
        let service = AudioVisualizerService()
        service.setPlaying(true)
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(service.isEnabled)
    }

    func testPlayingWithoutBeingEnabledDoesNotCapture() {
        let service = AudioVisualizerService()
        service.setPanelVisible(true)
        service.setPlaying(true)
        XCTAssertFalse(service.isRunning, "an off feature must never open a tap")
    }

    func testPauseAfterPlayingLeavesNothingRunning() {
        let service = AudioVisualizerService()
        service.setEnabled(true)
        service.setPanelVisible(true)
        service.setPlaying(true)
        service.setPlaying(false)
        XCTAssertFalse(service.isRunning)
    }

    func testBandsRestAtSilentBaselineWhenNotPlaying() {
        // The view keeps drawing while enabled and healthy, so the zeroed
        // bands are what makes the bars rest rather than react.
        let service = AudioVisualizerService()
        service.setEnabled(true)
        service.setPanelVisible(true)
        service.setPlaying(false)
        XCTAssertTrue(service.bands.allSatisfy { $0 == 0 },
                      "silent baseline, not stale magnitudes")
    }
}
