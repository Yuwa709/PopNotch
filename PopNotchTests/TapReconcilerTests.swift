import XCTest
@testable import PopNotch

/// The pure planner: desires and legs in, ops and row states out. These pin
/// the qualification rules from the Phase 5 design report.
final class TapReconcilerTests: XCTestCase {

    private let stereo = TapHALDevice(uid: "spk", name: "Speakers", sampleRate: 48000,
                                      isStereoOut: true, isAirPlay: false, hasInputStreams: false)
    private let airplay = TapHALDevice(uid: "air", name: "Room", sampleRate: 48000,
                                       isStereoOut: true, isAirPlay: true, hasInputStreams: false)
    private let surround = TapHALDevice(uid: "hdmi", name: "Receiver", sampleRate: 48000,
                                        isStereoOut: false, isAirPlay: false, hasInputStreams: false)
    private let headset = TapHALDevice(uid: "pods", name: "AirPods", sampleRate: 48000,
                                       isStereoOut: true, isAirPlay: false, hasInputStreams: true)

    private func plan(desires: [TapDesire], legs: [TapLegFacts] = [],
                      tapsEnabled: Bool = true, permissionDenied: Bool = false,
                      legsOnDevice: Int = 0)
        -> (ops: [TapPlanOp], states: [String: TapRowState]) {
        TapReconciler.plan(desires: desires, legs: legs, tapsEnabled: tapsEnabled,
                           permissionDenied: permissionDenied,
                           legsOnDevice: { _ in legsOnDevice },
                           device: { uid in
                               [self.stereo, self.airplay, self.surround, self.headset]
                                   .first { $0.uid == uid }
                           })
    }

    private func desire(_ key: String = "a", position: Int = 40, playing: Bool = true,
                        devices: [String] = ["spk"]) -> TapDesire {
        TapDesire(key: key, position: position, isPlaying: playing,
                  pids: [1], deviceUIDs: devices)
    }

    private func leg(_ key: String = "a", device: String = "spk",
                     gain: Float = 0.4) -> TapLegFacts {
        TapLegFacts(key: key, deviceUID: device, pids: [1], gain: gain)
    }

    func testPlayingBelowHundredEngages() {
        let result = plan(desires: [desire()])
        XCTAssertEqual(result.ops, [.engage(key: "a", deviceUID: "spk", pids: [1], gain: 0.4)])
        XCTAssertEqual(result.states["a"], .engaged)
    }

    func testHundredIsNeverTapped() {
        let result = plan(desires: [desire(position: 100)])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testDraggingBackToHundredDisengages() {
        let result = plan(desires: [desire(position: 100)], legs: [leg()])
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)])
    }

    func testStoppedPlayingDisengagesAfterGrace() {
        let result = plan(desires: [desire(playing: false)], legs: [leg()])
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: true)])
    }

    func testGainChangeIsJustAGainChange() {
        let result = plan(desires: [desire(position: 70)], legs: [leg()])
        XCTAssertEqual(result.ops, [.setGain(key: "a", gain: 0.7)])
    }

    func testTapsOffDropsEverythingQuietly() {
        let result = plan(desires: [desire()], legs: [leg()], tapsEnabled: false)
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)])
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testPermissionDeniedIsInertWithTheReason() {
        let result = plan(desires: [desire()], permissionDenied: true)
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .inert(reason: "permission needed"))
    }

    func testAirPlayIsExcluded() {
        let result = plan(desires: [desire(devices: ["air"])])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .inert(reason: "AirPlay output"))
    }

    func testMicrophoneCarryingOutputsAreExcluded() {
        // A headset's input streams would ride into the aggregate and
        // corrupt the gain mapping; unmeasured, so excluded (review find).
        let result = plan(desires: [desire(devices: ["pods"])], legs: [leg(device: "pods")])
        XCTAssertEqual(result.states["a"], .inert(reason: "output has a microphone"))
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)])
    }

    func testNonStereoIsExcluded() {
        XCTAssertEqual(plan(desires: [desire(devices: ["hdmi"])]).states["a"],
                       .inert(reason: "not a stereo output"))
    }

    func testMultiDeviceIsLeftUntouched() {
        let result = plan(desires: [desire(devices: ["spk", "usb"])], legs: [leg()])
        XCTAssertEqual(result.states["a"], .inert(reason: "on several outputs"))
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)],
                       "a leg whose owner went multi-device comes down")
    }

    func testCapacityShowsItsReason() {
        let result = plan(desires: [desire()], legsOnDevice: TapRenderState.maxLegs)
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .inert(reason: "too many adjusted apps"))
    }

    func testDeviceMoveIsMakeBeforeBreak() {
        var moved = desire()
        moved.deviceUIDs = ["usb"]
        let usb = TapHALDevice(uid: "usb", name: "DAC", sampleRate: 48000,
                               isStereoOut: true, isAirPlay: false, hasInputStreams: false)
        let result = TapReconciler.plan(desires: [moved], legs: [leg()],
                                        tapsEnabled: true, permissionDenied: false,
                                        legsOnDevice: { _ in 0 },
                                        device: { $0 == "usb" ? usb : self.stereo })
        XCTAssertEqual(result.ops, [
            .engage(key: "a", deviceUID: "usb", pids: [1], gain: 0.4),
        ], "one engage: the engine retires the old leg itself, new side first")
    }

    func testChangedPidsRebuildTheLeg() {
        var restarted = desire()
        restarted.pids = [2]
        let result = plan(desires: [restarted], legs: [leg()])
        XCTAssertEqual(result.ops, [.rebuild(key: "a", deviceUID: "spk", pids: [2], gain: 0.4)])
    }

    func testAnOwnerThatVanishedComesDown() {
        let result = plan(desires: [], legs: [leg()])
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)])
    }

    func testRememberedPositionOnAStoppedUntappedRowBuildsNothing() {
        let result = plan(desires: [desire(playing: false)])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testGainTaperIsLinearForNow() {
        XCTAssertEqual(TapReconciler.gain(atPosition: 0), 0)
        XCTAssertEqual(TapReconciler.gain(atPosition: 50), 0.5)
        XCTAssertEqual(TapReconciler.gain(atPosition: 100), 1)
        XCTAssertEqual(TapReconciler.gain(atPosition: 130), 1, "clamped")
    }
}

/// The service-side filter: what may never reach the engine.
@MainActor
final class TapDesireFilterTests: XCTestCase {

    private func row(_ key: String, neverTap: String? = nil,
                     playing: Bool = true) -> MixerRow {
        MixerRow(owner: AudioOwner(key: key, name: key, kind: .app, resolution: .ownApp),
                 pids: [7], isPlaying: playing, neverTapReason: neverTap,
                 deviceUIDs: ["spk"], engineState: .notTapped)
    }

    func testScriptedPlayersNeverReachTheEngineEvenWithTheirModuleOff() {
        // Identity, not capability: turning the Media module off must not
        // reroute Spotify or Music to a tap (decision 3; review find).
        let desires = AppVolumeService.desires(
            from: [row(SpotifyAdapter.bundleID), row(MusicAdapter.bundleID), row("org.chromium")],
            position: { _ in 50 })
        XCTAssertEqual(desires.map(\.key), ["org.chromium"],
                       "Spotify and Music are AppleScript's, never a tap's (decision 3)")
    }

    func testNeverTapRowsNeverReachTheEngine() {
        let desires = AppVolumeService.desires(
            from: [row("com.finetuneapp.FineTune", neverTap: "audio mixer"), row("org.chromium")],
            position: { _ in 50 })
        XCTAssertEqual(desires.map(\.key), ["org.chromium"],
                       "the never-tap set is never tapped, saved volumes included (decision 9)")
    }

    func testPositionsAndStateRideAlong() {
        let desires = AppVolumeService.desires(
            from: [row("org.chromium", playing: false)],
            position: { _ in 35 })
        XCTAssertEqual(desires, [TapDesire(key: "org.chromium", position: 35,
                                           isPlaying: false, pids: [7],
                                           deviceUIDs: ["spk"])])
    }
}

/// The drag path: what makes the knob follow the cursor.
///
/// The first Phase 5 build stored the mid-drag position in an
/// `@ObservationIgnored` property, so nothing told SwiftUI to re-render
/// while the pointer moved: the knob sat still and jumped only on release,
/// when the settings write fired observation (reported 2026-09-19).
@MainActor
final class TapDragTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Strong: the service holds the store weakly.
    private var store: SettingsStore!
    private var service: AppVolumeService!

    override func setUp() {
        super.setUp()
        suiteName = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        service = AppVolumeService(source: StubAudioProcessSource(),
                                   resolve: { _ in nil },
                                   isAppRunning: { _ in false })
        service.settingsStore = store
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        service = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLivePositionIsObservableSoTheKnobFollowsTheCursor() {
        var observed = false
        withObservationTracking {
            _ = service.tapPosition(for: "org.chromium")
        } onChange: {
            observed = true
        }

        service.setTapPosition(40, for: "org.chromium")

        XCTAssertTrue(observed, "a mid-drag position must notify, or the knob freezes until release")
        XCTAssertEqual(service.tapPosition(for: "org.chromium"), 40, "and the new position is what the knob reads")
    }

    func testUntouchedRowsSitAtFullVolume() {
        XCTAssertEqual(service.tapPosition(for: "org.chromium"), 100)
    }

    func testReleasePersistsThePositionAndDropsTheLiveOverlay() {
        service.setTapPosition(35, for: "org.chromium")
        service.endTapVolumeEdit(for: "org.chromium")

        XCTAssertEqual(store.settings.appVolume.volumes?["org.chromium"], 35, "the release is what persists")
        XCTAssertEqual(service.tapPosition(for: "org.chromium"), 35,
                       "and the saved value takes over from the live one")
    }

    func testReleaseAtFullVolumeStoresAbsenceRatherThanAHundred() {
        service.setTapPosition(35, for: "org.chromium")
        service.endTapVolumeEdit(for: "org.chromium")
        service.setTapPosition(100, for: "org.chromium")
        service.endTapVolumeEdit(for: "org.chromium")

        XCTAssertNil(store.settings.appVolume.volumes?["org.chromium"],
                     "100% is stored as absence, so an untouched app carries no entry")
        XCTAssertEqual(service.tapPosition(for: "org.chromium"), 100)
    }
}
