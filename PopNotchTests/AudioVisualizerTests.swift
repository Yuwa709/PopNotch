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
        //
        // Asserted on band dB rather than on bar heights: the folding is what
        // this test is about, and heights depend on dynamicWindow, so an
        // arbitrary synthetic magnitude would silently couple this to a
        // tuning constant. It did — the original used magnitude 1.0, which
        // sat inside a 45 dB window and outside a 35 dB one.
        var bins = [Float](repeating: 0, count: 512)
        for i in 0..<8 { bins[i] = 1 }
        let decibels = AudioVisualizerService.bandDecibels(magnitudes: bins, into: bandCount)
        XCTAssertTrue(decibels[0].isFinite, "low-frequency energy must reach the first band")
        XCTAssertGreaterThan(decibels[0], decibels[bandCount - 1] + 60,
                             "and must dwarf the top band, which sees nothing")

        // The bar heights still honour it once the signal is in range.
        let loud = bins.map { $0 * 1000 }
        let bands = AudioVisualizerService.fold(magnitudes: loud, into: bandCount)
        XCTAssertGreaterThan(bands[0], 0, "low-frequency energy must reach the first bar")
        XCTAssertEqual(bands[bandCount - 1], 0, "and must not leak into the top bar")
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

/// The adaptive ceiling. Loudly-mastered tracks measured ~20 dB above the
/// static references, which the old fixed mapping clipped flat — every band
/// at 1.0, a motionless brick.
final class AudioVisualizerGainTests: XCTestCase {

    private let bands = AudioVisualizerService.bandCount

    /// Band dB sitting a uniform `offset` above each band's own reference.
    private func decibels(offsetFromReference offset: Float) -> [Float] {
        (0..<bands).map { AudioVisualizerService.referenceDB[$0] + offset }
    }

    // MARK: - The bug

    func testLoudInputNoLongerPinsEveryBand() {
        // +20 dB over reference: the measured real-world case.
        let loud = decibels(offsetFromReference: 20)

        let fixed = AudioVisualizerService.normalize(bandDecibels: loud, gain: 0)
        XCTAssertTrue(fixed.allSatisfy { $0 == 1 },
                      "precondition: the static mapping clips this flat, which is the bug")

        let gain = AudioVisualizerService.updatedGain(current: 0, excess: 20)
        let adapted = AudioVisualizerService.normalize(bandDecibels: loud, gain: gain)
        XCTAssertTrue(adapted.allSatisfy { $0 < 1 }, "nothing may sit pinned at the ceiling")
        XCTAssertTrue(adapted.allSatisfy { $0 > 0.85 }, "but loud must still read as loud")
    }

    func testLoudInputStillShowsDynamics() {
        // The symptom was motionlessness: two different loud frames must
        // produce visibly different heights, not both 1.0.
        let gain = AudioVisualizerService.updatedGain(current: 0, excess: 20)
        let peak = AudioVisualizerService.normalize(bandDecibels: decibels(offsetFromReference: 20), gain: gain)
        let dip = AudioVisualizerService.normalize(bandDecibels: decibels(offsetFromReference: 8), gain: gain)
        XCTAssertGreaterThan(peak[0] - dip[0], 0.2, "a 12 dB dip must be visible as motion")
    }

    // MARK: - Quiet material stays visible

    /// Runs the release to convergence. Downward adaptation is deliberately
    /// slow, so anything asserting the settled state has to get there first.
    private func settled(from start: Float, excess: Float, seconds: Int = 20) -> Float {
        var gain = start
        for _ in 0..<(46 * seconds) {
            gain = AudioVisualizerService.updatedGain(current: gain, excess: excess)
        }
        return gain
    }

    func testQuietTrackIsLiftedNotHidden() {
        // A quiet master peaking 10 dB below reference must still fill the
        // bars, which is what stops this from being a global desensitising.
        let quiet = decibels(offsetFromReference: -10)
        let adapted = AudioVisualizerService.normalize(
            bandDecibels: quiet, gain: settled(from: 0, excess: -10))
        XCTAssertTrue(adapted.allSatisfy { $0 > 0.85 }, "quiet music must still reach near the top")
    }

    func testNearSilenceIsNotAmplifiedIntoNoise() {
        // The floor's whole job: gain must not keep climbing until room tone
        // lights the bars.
        // Exponential release asymptotes rather than arriving, so the
        // invariant is "approaches the floor and never passes it".
        let gain = settled(from: 0, excess: -80)
        XCTAssertEqual(gain, AudioVisualizerService.minimumGain, accuracy: 0.25)
        XCTAssertGreaterThanOrEqual(gain, AudioVisualizerService.minimumGain,
                                    "the floor is a floor: the ceiling never falls below it")
        let silence = [Float](repeating: -180, count: bands)
        XCTAssertTrue(AudioVisualizerService.normalize(bandDecibels: silence, gain: gain)
            .allSatisfy { $0 == 0 })
    }

    // MARK: - Attack and release

    func testCeilingRisesInstantly() {
        // A transient must never clip while the ceiling catches up.
        XCTAssertEqual(AudioVisualizerService.updatedGain(current: 0, excess: 20),
                       20 + AudioVisualizerService.peakHeadroom, accuracy: 0.001)
    }

    func testCeilingFallsSlowly() {
        // One frame of quiet must barely move it, or the bars pump.
        let after = AudioVisualizerService.updatedGain(current: 23, excess: -10)
        XCTAssertLessThan(after, 23)
        XCTAssertGreaterThan(after, 22.8, "a single frame must not collapse the ceiling")
    }

    func testCeilingConvergesAfterSustainedQuiet() {
        // ~4s time constant, so a few seconds is partial and a long stretch
        // arrives. Both halves matter: the first is what stops pumping, the
        // second is what stops a loud track permanently deafening the bars.
        let partway = settled(from: 23, excess: -10, seconds: 3)
        XCTAssertGreaterThan(partway, -7, "still descending after three seconds")
        XCTAssertLessThan(partway, 23, "but genuinely descending")

        let arrived = settled(from: 23, excess: -10, seconds: 20)
        XCTAssertEqual(arrived, -10 + AudioVisualizerService.peakHeadroom, accuracy: 0.5)
    }

    // MARK: - The static path is unchanged

    func testFoldStillMatchesTheStaticMapping() {
        // fold() is the zero-gain case, and eight existing tests depend on it.
        let magnitudes = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: magnitudes, into: bands),
                       AudioVisualizerService.normalize(
                           bandDecibels: AudioVisualizerService.bandDecibels(
                               magnitudes: magnitudes, into: bands), gain: 0))
    }

    func testBandDecibelsHandlesEmptyInput() {
        XCTAssertEqual(AudioVisualizerService.bandDecibels(magnitudes: [], into: bands).count, bands)
        XCTAssertTrue(AudioVisualizerService.fold(magnitudes: [], into: bands).allSatisfy { $0 == 0 })
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
