import XCTest
@testable import PopNotch

/// The player-screen volume control: Spotify's and Music's own
/// `sound volume`, through AppleScript. No test here sends an Apple Event —
/// the real adapters are only asked what they support, and everything that
/// moves goes through `StubMediaSource`.
@MainActor
final class PlayerVolumeTests: XCTestCase {

    // MARK: - Parsing

    func testParsesTheIntegerTheDictionaryReturns() {
        XCTAssertEqual(PlayerVolume.parse("73"), 73)
        XCTAssertEqual(PlayerVolume.parse("0"), 0)
        XCTAssertEqual(PlayerVolume.parse("100"), 100)
        XCTAssertEqual(PlayerVolume.parse(" 42\n"), 42)
    }

    /// Anything unrecognisable is nil, never a guessed level: the caller
    /// keeps the last value it actually read.
    func testGarbageIsNilNotZero() {
        for bad in ["", "abc", "missing value", "4 2", "42%"] {
            XCTAssertNil(PlayerVolume.parse(bad), "\(bad) must not parse")
        }
    }

    func testOutOfRangeIsClampedOntoTheTrack() {
        XCTAssertEqual(PlayerVolume.parse("150"), 100)
        XCTAssertEqual(PlayerVolume.parse("-4"), 0)
    }

    func testSliderPositionMapsLinearlyAndStaysInRange() {
        XCTAssertEqual(PlayerVolume.value(atFraction: 0), 0)
        XCTAssertEqual(PlayerVolume.value(atFraction: 0.5), 50)
        XCTAssertEqual(PlayerVolume.value(atFraction: 1), 100)
        XCTAssertEqual(PlayerVolume.value(atFraction: 1.3), 100)
        XCTAssertEqual(PlayerVolume.value(atFraction: -0.2), 0)
    }

    // MARK: - Spotify's read-back

    /// Measured 2026-09-17: set 52, 65 and 70 read back 51, 64 and 69.
    func testAReadOneBelowTheWriteShowsTheWrite() {
        var readBack = VolumeReadBack()
        readBack.recordWrite(52)
        XCTAssertEqual(readBack.adjust(51), 52)
    }

    /// Not just the first read: every live-sync read after the write returned
    /// N−1, so a one-shot correction would only delay the slip by 2 s.
    func testTheCorrectionHoldsAcrossLaterReads() {
        var readBack = VolumeReadBack()
        readBack.recordWrite(52)
        XCTAssertEqual(readBack.adjust(51), 52)
        XCTAssertEqual(readBack.adjust(51), 52)
        XCTAssertEqual(readBack.adjust(52), 52, "an exact read is fine too")
        XCTAssertEqual(readBack.adjust(51), 52)
    }

    /// Any other value is a real change, from Spotify's slider or a phone,
    /// and ends the correction.
    func testAnyOtherValueEndsTheCorrection() {
        var readBack = VolumeReadBack()
        readBack.recordWrite(52)
        XCTAssertEqual(readBack.adjust(40), 40)
        XCTAssertNil(readBack.lastWrite)
        XCTAssertEqual(readBack.adjust(51), 51, "no longer corrected")
    }

    /// The Connect case: a write that did not take must show as not taking.
    func testAWriteThatDidNotStickIsNotMasked() {
        var readBack = VolumeReadBack()
        readBack.recordWrite(7)
        XCTAssertEqual(readBack.adjust(100), 100)
    }

    func testNoWriteMeansNoCorrection() {
        var readBack = VolumeReadBack()
        XCTAssertEqual(readBack.adjust(51), 51)
    }

    /// A later write replaces the earlier one.
    func testTheLatestWriteIsTheOneCorrectedTo() {
        var readBack = VolumeReadBack()
        readBack.recordWrite(52)
        readBack.recordWrite(70)
        XCTAssertEqual(readBack.adjust(69), 70)
        XCTAssertEqual(readBack.adjust(51), 51, "52's correction is gone")
    }

    // MARK: - Throttle

    func testFirstWriteGoesImmediately() {
        let throttle = VolumeSendThrottle(interval: 0.2)
        XCTAssertEqual(throttle.wait(at: 100), 0)
    }

    func testWritesWithinTheIntervalWaitForTheRemainder() {
        var throttle = VolumeSendThrottle(interval: 0.2)
        throttle.recordSend(at: 100)
        XCTAssertEqual(throttle.wait(at: 100.05), 0.15, accuracy: 1e-9)
        XCTAssertEqual(throttle.wait(at: 100.2), 0)
        XCTAssertEqual(throttle.wait(at: 101), 0)
    }

    // MARK: - Which sources have a volume

    /// Hidden for a system-source player: its payload has no volume.
    func testOnlySpotifyAndMusicSupportVolume() {
        XCTAssertTrue(SpotifyAdapter().supportsVolume)
        XCTAssertTrue(MusicAdapter().supportsVolume)
        XCTAssertFalse(SystemMediaAdapter().supportsVolume)
    }

    /// Nothing is claimed before a read lands.
    func testAdaptersStartWithNoVolume() {
        XCTAssertNil(SpotifyAdapter().volume)
        XCTAssertNil(MusicAdapter().volume)
        XCTAssertNil(SystemMediaAdapter().volume)
    }

    // MARK: - Module

    private func module(supportsVolume: Bool, volume: Int? = nil)
        -> (MediaModule, StubMediaSource) {
        let source = StubMediaSource(id: "spotify", running: true)
        source.supportsVolume = supportsVolume
        source.volume = volume
        let module = MediaModule(sources: [source])
        var track = NowPlaying()
        track.title = "Track"
        track.isPlaying = true
        source.publish(track)
        return (module, source)
    }

    func testControlShowsForAPlayerWithAVolume() {
        let (module, _) = module(supportsVolume: true, volume: 40)
        XCTAssertTrue(module.showsVolumeControl)
        XCTAssertEqual(module.volume, 40, "mirrored on publish")
    }

    func testControlHiddenForASourceWithoutOne() {
        let (module, _) = module(supportsVolume: false)
        XCTAssertFalse(module.showsVolumeControl)
        XCTAssertNil(module.volume)
    }

    /// The button stays put before the first read; opening the slider reads.
    func testOpeningTheSliderReadsWhenNothingHasBeenRead() {
        let (module, source) = module(supportsVolume: true)
        XCTAssertTrue(module.showsVolumeControl, "shown before any read")
        source.nextRead = 55
        XCTAssertTrue(module.prepareVolumeSlider())
        XCTAssertEqual(module.volume, 55)
        XCTAssertEqual(source.volumeReads, 1)
    }

    func testAFailedReadKeepsTheSliderClosed() {
        let (module, source) = module(supportsVolume: true)
        source.nextRead = nil
        XCTAssertFalse(module.prepareVolumeSlider())
    }

    func testAKnownValueOpensWithoutAnotherRead() {
        let (module, source) = module(supportsVolume: true, volume: 30)
        XCTAssertTrue(module.prepareVolumeSlider())
        XCTAssertEqual(source.volumeReads, 0)
    }

    /// A drag writes the first step at once, coalesces the steps that follow
    /// within the interval, and always writes where it was released.
    func testADragIsThinnedAndEndsOnTheReleasedValue() {
        let (module, source) = module(supportsVolume: true, volume: 50)
        module.beginVolumeEdit()
        module.setVolume(10)
        module.setVolume(20)
        module.setVolume(30)
        XCTAssertEqual(source.volumeWrites, [10], "steps within the interval wait")
        XCTAssertEqual(module.volume, 30, "the slider follows the pointer regardless")
        module.endVolumeEdit()
        XCTAssertEqual(source.volumeWrites, [10, 30], "the release writes the final value, not 20")
        XCTAssertFalse(module.isEditingVolume)
    }

    func testWritesAreClamped() {
        let (module, source) = module(supportsVolume: true, volume: 50)
        module.beginVolumeEdit()
        module.setVolume(150)
        module.endVolumeEdit()
        XCTAssertEqual(source.volumeWrites.last, 100)
        XCTAssertEqual(module.volume, 100)
    }

    /// A publish landing mid-drag must not snap the slider back to the
    /// player's value from before the latest write.
    func testAPublishMidDragLeavesTheSliderAlone() {
        let (module, source) = module(supportsVolume: true, volume: 50)
        module.beginVolumeEdit()
        module.setVolume(80)
        source.volume = 5
        var track = NowPlaying()
        track.title = "Track"
        track.isPlaying = true
        source.publish(track)
        XCTAssertEqual(module.volume, 80)
        module.endVolumeEdit()
    }

    /// A write still waiting on the throttle is sent, not dropped, when the
    /// panel closes.
    func testClosingThePanelSendsAPendingWrite() {
        let (module, source) = module(supportsVolume: true, volume: 50)
        module.didBecomeVisible()
        module.beginVolumeEdit()
        module.setVolume(10)
        module.setVolume(20)
        module.didResignVisible()
        XCTAssertEqual(source.volumeWrites, [10, 20])
        XCTAssertFalse(module.isEditingVolume)
    }

    /// No writes when the current player cannot take them.
    func testNoWritesToASourceWithoutAVolume() {
        let (module, source) = module(supportsVolume: false)
        module.beginVolumeEdit()
        module.setVolume(10)
        module.endVolumeEdit()
        XCTAssertTrue(source.volumeWrites.isEmpty)
    }
}
