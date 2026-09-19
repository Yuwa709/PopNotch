import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Accelerate
import Observation
import os

/// System-audio capture reduced to a small band spectrum, for a future
/// notch visualiser.
///
/// Distinct from `ArtworkVisualizerView`, which derives a glow from album
/// artwork and never touches audio. This reads the actual output signal.
///
/// **Why Core Audio taps and not ScreenCaptureKit.** SCK was the first
/// attempt and was wrong: its audio rides on a screen-content stream —
/// `SCContentFilter` has no audio-only initialiser, every one of them takes
/// a display, window or application — so it requires the *full* Screen
/// Recording grant. Core Audio process taps use the lighter **System Audio
/// Recording Only** permission instead, which is the correct grant for an
/// app that only wants the output signal. Verified end to end on this
/// machine 2026-08-29: tap created, private aggregate device created, IO
/// proc started, 562 buffers of 1024 frames delivered with RMS tracking the
/// music.
///
/// **Deployment target.** Process taps need macOS 14.2, and the app's floor
/// was raised to match rather than gating the feature. The gate cost a
/// type-erased `AnyObject` and three `as?` casts, purely so a 14.0-available
/// type could avoid naming a 14.2-available one — for a version that shipped
/// in December 2023 and that every Mac with a notch runs.
///
/// **Permission.** There is no preflight API for the audio-only grant — a
/// search of the SDK finds only `CGPreflightScreenCaptureAccess`,
/// `CGPreflightListenEventAccess` and `CGPreflightPostEventAccess`, none of
/// which describe this. Authorization therefore shows up as
/// `AudioDeviceStart` failing, which is handled as a logged, quiet decline.
///
/// **Lifetime.** Off by default. Capture runs only while all three of
/// enabled, spectrum-on-screen and *actively playing* hold, and is torn down
/// the moment any of them stops — hard rule 9's "nothing runs when nobody is
/// looking", expressed without a timer. The one exception is the pause
/// settle, a short bounded run of band updates after capture has already
/// stopped; see `pauseSettleDuration`.
///
/// The playback condition matters beyond tidiness. The tap is whole-system:
/// with only enabled-and-visible gating, the bars would dance to a YouTube
/// tab, a notification chime, or a video call while the notch showed a
/// paused track. Gating on the tracked player's state keeps the spectrum
/// honestly about the music the notch is displaying. Per-app isolation is a
/// different thing entirely and stays deferred — see
/// `docs/FUTURE-audio-mixer.md`.
@MainActor
@Observable
final class AudioVisualizerService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AudioViz")

    /// Bands published to any future view. Log-spaced, so low frequencies —
    /// where music actually lives — are not crushed into one bar.
    ///
    /// `nonisolated`: an immutable Int the analysis queue reads. Without it
    /// the target's MainActor-by-default isolation makes this unreachable
    /// from the very code that sizes its output.
    nonisolated static let bandCount = 16

    private(set) var bands: [Float] = Array(repeating: 0, count: bandCount)
    private(set) var isRunning = false
    /// Why capture is not running, when that is worth showing or logging.
    private(set) var lastError: String?

    @ObservationIgnored private(set) var isEnabled = false
    /// Whether the view that draws the spectrum is on screen. Readable so tests
    /// can check what the media module reported without opening a real tap.
    @ObservationIgnored private(set) var spectrumVisible = false
    /// Driven by the media module from the active source's player state.
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var capture: (any AudioCaptureEngine)?
    @ObservationIgnored private let makeCapture: CaptureFactory
    /// The pause settle in progress, if any. See `settle()`.
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Throttles the verification logging; no timer, just a clock check on
    /// buffers that are arriving anyway.
    @ObservationIgnored private var lastLogged = Date.distantPast

    /// Per-band reference levels in dB: the ceiling each band is normalised
    /// against, with `dynamicWindow` of range below it.
    ///
    /// **Measured, not assumed** (2026-08-29, live playback through the tap):
    /// musical energy tilts ~67 dB across the spectrum — band 0 peaked at
    /// +35 dB while band 14 peaked at -32 dB. The old single mapping,
    /// `(db + 60) / 60`, assumed a flat -60 floor: it pinned bands 0-7 at
    /// 1.0 permanently and let the treble barely move. These references are
    /// the measured peak envelope, lightly smoothed, so every band's musical
    /// peak lands near the top of its own bar.
    nonisolated static let referenceDB: [Float] = [
        36, 36, 33, 28, 22, 17, 14, 12,
        11, 9, 4, -2, -9, -17, -24, -18,
    ]

    /// How far below its ceiling a band stays visible. Narrower means more
    /// height per dB, so bands separate and travel further.
    ///
    /// **35 is the measured optimum**, simulated against live audio
    /// 2026-08-29 across 45/35/30/26/22/18 dB. Mean cross-band spread peaks
    /// there at 0.71 (45 gave 0.61) and then *falls* as the window keeps
    /// narrowing, because bands start hitting the floor rather than
    /// separating: 30 floors 4 bands a frame, 26 floors 8 of 16, and spread
    /// collapses to 0.51 by 18. Pinning stayed at 0.00 bands/frame at every
    /// candidate, so none of this risks the max-volume brick returning —
    /// that is the adaptive gain's job and it still does it.
    nonisolated static let dynamicWindow: Float = 35

    /// dB of headroom kept above the recent peak, so the loudest band lands
    /// just below the top instead of pinned against it. 3 dB puts a peak at
    /// 42/45 = 0.93 of full height, which still reads as "maxed" while
    /// leaving room to show a louder transient.
    nonisolated static let peakHeadroom: Float = 3

    /// How far the adaptive ceiling may fall below the measured references.
    /// Without a floor the gain would keep climbing through a quiet passage
    /// until room tone lit the bars.
    nonisolated static let minimumGain: Float = -12

    /// How much of a *rising* band's previous value survives each buffer:
    /// every buffer closes `1 - barAttack` of the gap to the new level. 0 is
    /// an instant jump; nearer 1 is a slower swell.
    ///
    /// **0.675: a rise covers half its travel in ~2 buffers (~40ms) and 90% in
    /// ~6 (~125ms)**, at 1024-frame buffers and 48kHz, about 47 a second.
    /// Attack was instant until 2026-09-16, when the spectrum had become the
    /// scrub bar and every transient snapped it to full height: it read as
    /// flicker rather than level. 0.8 (90% in ~220ms) then overcorrected into
    /// a rectangle with a ripple, and 0.55 (~80ms) came back slightly too
    /// jumpy; 0.675 splits the difference.
    nonisolated static let barAttack: Float = 0.675

    /// How much of a *falling* band's previous value survives each buffer:
    /// every buffer closes `1 - barRelease` of the gap.
    ///
    /// **0.9: a fall covers half its travel in ~7 buffers (~140ms) and 90% in
    /// ~22 (~470ms)**, so peaks subside smoothly while troughs still open up
    /// between them (0.92 held the wave up and helped flatten it). Deliberately
    /// slower than the attack: a band that falls as fast as it rises reads as
    /// flicker rather than as level.
    ///
    /// It was 0.35, measured on 2026-08-30 to pass about 80% of the raw
    /// frame-to-frame travel (0.073 of full height per buffer) to the old
    /// header bars, where motion was the point. The scrub bar wants calm, and
    /// gives most of that travel up on purpose. Neither constant can bring
    /// back the max-volume brick, which the adaptive gain owns.
    nonisolated static let barRelease: Float = 0.9

    /// The shortest gap between two publishes: at most one every 40ms (25Hz).
    ///
    /// Analysis still runs on every buffer, so the smoothing above keeps its
    /// time base; only what reaches the main actor is thinned. At 1024-frame
    /// buffers that lets every second buffer through at 48kHz (~23Hz) and
    /// 44.1kHz (~22Hz), and every fourth at 96kHz (~23Hz), against ~47 a
    /// second before. Each publish dropped is a main-actor hop and a SwiftUI
    /// update not made, and fewer updates are calmer too. See
    /// `PublishThrottle`.
    nonisolated static let publishInterval: TimeInterval = 1.0 / 25

    /// How long the wave takes to sink to its silent baseline when playback
    /// pauses, in seconds. Capture stops at once; this only eases the last
    /// published bands down, stepping at `publishInterval` (0.4s is ten
    /// steps). 0 drops the wave in a single frame, as it did before.
    nonisolated static let pauseSettleDuration: TimeInterval = 0.4

    /// The fraction of the paused level still showing `elapsed` seconds into
    /// the settle. An ease-out: quickest at first and gentlest on landing, so
    /// the wave sinks into the baseline rather than stopping against it.
    /// Exactly 0 once `pauseSettleDuration` has passed.
    nonisolated static func settleLevel(after elapsed: TimeInterval) -> Float {
        guard pauseSettleDuration > 0 else { return 0 }
        let remaining = 1 - min(1, max(0, elapsed / pauseSettleDuration))
        return Float(remaining * remaining)
    }

    /// One buffer of bar smoothing: an eased rise at `barAttack`, a slower
    /// fall at `barRelease`. It only ever interpolates between the previous
    /// value and the new one, so it cannot push a band out of range.
    nonisolated static func smoothed(previous: Float, raw: Float) -> Float {
        let keep = raw > previous ? barAttack : barRelease
        return previous * keep + raw * (1 - keep)
    }

    /// Per-frame decay of the ceiling, at roughly 46 buffers a second: about
    /// a four-second fall. The ceiling rises instantly so a transient cannot
    /// clip, and falls slowly so a quiet bar inside a loud track still reads
    /// as quiet rather than being re-normalised to full height a frame later.
    nonisolated static let gainRelease: Float = 0.995

    /// Band energies in dB, before normalisation.
    ///
    /// Split out from `fold` so the adaptive ceiling can read exactly the
    /// numbers the mapping will use, without folding the bins twice.
    nonisolated static func bandDecibels(magnitudes: [Float], into bandCount: Int) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else {
            return [Float](repeating: -.infinity, count: max(0, bandCount))
        }
        var result = [Float](repeating: -.infinity, count: bandCount)
        let maxBin = Float(magnitudes.count)
        for band in 0..<bandCount {
            let lo = Int(powf(maxBin, Float(band) / Float(bandCount)))
            let hi = max(lo + 1, Int(powf(maxBin, Float(band + 1) / Float(bandCount))))
            let upper = min(hi, magnitudes.count)
            guard lo < upper else { continue }
            var sum: Float = 0
            for bin in lo..<upper { sum += magnitudes[bin] }
            result[band] = 20 * log10f(max(sum / Float(upper - lo), 1e-9))
        }
        return result
    }

    /// Maps band dB to 0...1 against the per-band references, with the whole
    /// set of ceilings shifted by `gain`.
    ///
    /// The references carry the *shape* — the spectral tilt of real music,
    /// which is a property of music and not of level. `gain` carries the
    /// *level*, which is a property of the track's mastering. Separating them
    /// is what lets one mapping serve a quiet recording and a loud one.
    nonisolated static func normalize(bandDecibels: [Float], gain: Float) -> [Float] {
        bandDecibels.enumerated().map { index, db in
            let reference = index < referenceDB.count ? referenceDB[index] : 0
            let ceiling = reference + gain
            return min(1, max(0, (db - (ceiling - dynamicWindow)) / dynamicWindow))
        }
    }

    /// How far the loudest band sits above its own reference this frame.
    /// Negative for quiet material, which is how the ceiling comes back down.
    nonisolated static func excess(bandDecibels: [Float]) -> Float {
        var highest = -Float.infinity
        for (index, db) in bandDecibels.enumerated() where db.isFinite {
            let reference = index < referenceDB.count ? referenceDB[index] : 0
            highest = max(highest, db - reference)
        }
        return highest.isFinite ? highest : minimumGain
    }

    /// Attack instantly, release slowly — the standard shape for anything
    /// that must not clip but also must not pump.
    nonisolated static func updatedGain(current: Float, excess: Float) -> Float {
        let target = max(minimumGain, excess + peakHeadroom)
        guard target <= current else { return target }
        return current * gainRelease + target * (1 - gainRelease)
    }

    /// Folds FFT bins into log-spaced bands, normalised to roughly 0...1
    /// against the static references — i.e. with no adaptive gain.
    ///
    /// Log spacing because linear bins put almost everything musical in the
    /// first band or two. Pure, and on the service rather than the private tap so it is testable.
    nonisolated static func fold(magnitudes: [Float], into bandCount: Int) -> [Float] {
        normalize(bandDecibels: bandDecibels(magnitudes: magnitudes, into: bandCount), gain: 0)
    }

    /// Makes the engine that captures. Injected so tests can run the whole
    /// lifecycle on a fake: no test may open a real system-audio tap.
    typealias CaptureFactory = @MainActor (_ onBands: @escaping ([Float]) -> Void) -> any AudioCaptureEngine

    /// `makeCapture` is nil in the app, which captures through the real
    /// system-audio tap.
    init(makeCapture: CaptureFactory? = nil) {
        self.makeCapture = makeCapture ?? { SystemAudioTap(onBands: $0) }
    }

    // MARK: - Control

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        Self.logger.notice("Visualiser \(on ? "enabled" : "disabled", privacy: .public)")
        reconcile()
    }

    /// Whether the spectrum is on screen right now. Called by `MediaModule`, the
    /// only thing that knows: an open panel is not enough. The stats page,
    /// clipboard, shelf and full-lyrics takeover all fill an open panel
    /// without drawing the spectrum, and while this was keyed on the panel,
    /// capture ran behind each of them whenever music played (fixed
    /// 2026-09-16).
    func setSpectrumVisible(_ visible: Bool) {
        guard visible != spectrumVisible else { return }
        spectrumVisible = visible
        reconcile()
    }

    /// Called by the media module whenever the active source's play state
    /// changes. Not a poll: this rides the adapter's existing push updates.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        reconcile()
    }

    private var shouldRun: Bool { isEnabled && spectrumVisible && isPlaying }

    private func reconcile() {
        if shouldRun {
            if capture == nil { start() }
            return
        }
        if capture != nil { stop(reason: stopReason) }
        // Only a pause sinks: still enabled and on screen, with playback the
        // one condition that stopped. Disabled or off screen, the bands drop
        // at once, cancelling any settle already running.
        if isEnabled && spectrumVisible {
            settle()
        } else {
            rest()
        }
    }

    private var stopReason: String {
        if !isEnabled { return "disabled" }
        if !spectrumVisible { return "spectrum not on screen" }
        return "playback stopped"
    }

    // MARK: - Capture

    private func start() {
        // Resumed mid-settle: the next live publish takes over from wherever
        // the wave had sunk to.
        settleTask?.cancel()
        settleTask = nil
        let engine = makeCapture { [weak self] bands in
            Task { @MainActor in self?.publish(bands) }
        }
        switch engine.start() {
        case .success:
            capture = engine
            isRunning = true
            lastError = nil
        case .failure(let reason):
            capture = nil
            isRunning = false
            lastError = reason
            // Nothing live will replace whatever a cancelled settle left.
            rest()
            // Authorization shows up here, since the audio-only grant has no
            // preflight. Quiet decline, no retry loop.
            Self.logger.error("Capture failed: \(reason, privacy: .public)")
        }
    }

    /// Tears capture down. Leaves `bands` alone: `reconcile` decides whether
    /// they settle or drop.
    private func stop(reason: String) {
        guard let engine = capture else { return }
        capture = nil
        isRunning = false
        engine.stop()
        Self.logger.notice("Capture stopped (\(reason, privacy: .public))")
    }

    /// Eases the last published bands down to the silent baseline over
    /// `pauseSettleDuration`, one plain band update per `publishInterval`.
    ///
    /// Only this transition moves the wave without audio behind it; there is
    /// still no view animation, so nothing is added to live playback, where
    /// the implicit animation cost 7.6 points of a core (see
    /// `AudioVisualizerSpectrumView`). Bounded, not a poll (hard rule 9): it
    /// ends itself at the baseline, and resuming, disabling, or hiding the
    /// spectrum cancels it. Instant under Reduce Motion (hard rule 8).
    private func settle() {
        guard settleTask == nil else { return }
        let from = bands
        guard from.contains(where: { $0 > 0 }) else { return }
        guard Self.pauseSettleDuration > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            rest()
            return
        }
        Self.logger.notice("Settling to baseline over \(Self.pauseSettleDuration, privacy: .public)s")
        let clock = ContinuousClock()
        let began = clock.now
        settleTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.publishInterval))
                guard !Task.isCancelled, let self else { return }
                let level = Self.settleLevel(after: (clock.now - began) / .seconds(1))
                self.bands = from.map { $0 * level }
                if level == 0 {
                    self.settleTask = nil
                    return
                }
            }
        }
    }

    /// Drops the bands to the silent baseline at once, cancelling any settle.
    private func rest() {
        settleTask?.cancel()
        settleTask = nil
        guard bands.contains(where: { $0 != 0 }) else { return }
        bands = Array(repeating: 0, count: Self.bandCount)
    }

    private func publish(_ newBands: [Float]) {
        guard isRunning else { return }
        bands = newBands
        // Verification logging until a view exists: one line a second, so
        // real audio can be confirmed flowing without a UI.
        let now = Date()
        guard now.timeIntervalSince(lastLogged) >= 1 else { return }
        lastLogged = now
        let rendered = newBands.map { String(format: "%.2f", $0) }.joined(separator: " ")
        Self.logger.notice("bands: \(rendered, privacy: .public)")
    }

    deinit {
        // Nonisolated: hand the engine its own teardown and touch nothing
        // main-actor. Releasing the tap and aggregate device here is what
        // stops a quit from leaving a private aggregate device behind.
        capture?.stop()
    }
}

/// What `AudioVisualizerService` starts and stops. `SystemAudioTap` is the
/// only real one; tests supply a fake, so none of them opens a real tap.
///
/// `nonisolated` for the same reason as `SystemAudioTap` below.
nonisolated protocol AudioCaptureEngine: AnyObject {
    func start() -> AudioCaptureStartResult
    func stop()
}

nonisolated enum AudioCaptureStartResult {
    case success
    /// Why capture could not start, for the log and `lastError`.
    case failure(String)
}

/// Captures system output audio with a Core Audio process tap feeding a
/// private aggregate device, and reduces each buffer to bands.
///
/// The tap is created `.unmuted`: this observes the output, it must never
/// silence what the user is listening to.
///
/// `nonisolated` on purpose: this target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated class here
/// would be main-actor isolated — wrong for a type whose work happens on a
/// Core Audio realtime thread and a background analysis queue.
private nonisolated final class SystemAudioTap: AudioCaptureEngine {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AudioViz")

    private let onBands: ([Float]) -> Void
    private let analyzer = AudioAnalyzer()
    /// The FFT runs here, never on the realtime IO thread: the analysis
    /// allocates, and allocating in a Core Audio callback is how you get
    /// dropouts in the audio the user is actually listening to.
    private let analysisQueue = DispatchQueue(label: "com.techie.PopNotch.audioviz",
                                              qos: .userInitiated)
    /// Thins publishes to `AudioVisualizerService.publishInterval`. Touched
    /// only on `analysisQueue`, like the analyzer.
    private var throttle = PublishThrottle(interval: AudioVisualizerService.publishInterval)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(onBands: @escaping ([Float]) -> Void) {
        self.onBands = onBands
    }

    func start() -> AudioCaptureStartResult {
        // 1. Tap the global output. Excluding nothing: the visualiser should
        //    react to everything audible, not just one player.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            return .failure("Could not create the process tap (\(Self.describe(tapStatus))). System Audio Recording permission is likely not granted.")
        }
        Self.logger.notice("Tap created (id \(self.tapID, privacy: .public))")

        // 2. A private aggregate device whose only member is that tap.
        //    Private so it never appears in the user's sound settings.
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PopNotch Visualiser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard aggStatus == noErr else {
            cleanUp()
            return .failure("Could not create the aggregate device (\(Self.describe(aggStatus))).")
        }
        Self.logger.notice("Aggregate device created (id \(self.aggregateID, privacy: .public))")

        // 3. IO proc: copy the frames out and get off the realtime thread.
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            guard let buffer = list.first, let raw = buffer.mData else { return }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(
                start: raw.assumingMemoryBound(to: Float.self), count: count))
            self.analysisQueue.async {
                // Analysed on every buffer, so the smoothing keeps its time
                // base; published at most once per `publishInterval`.
                guard let bands = self.analyzer.bands(from: samples),
                      self.throttle.admit(at: ProcessInfo.processInfo.systemUptime)
                else { return }
                self.onBands(bands)
            }
        }
        guard ioStatus == noErr, let procID else {
            cleanUp()
            return .failure("Could not create the IO proc (\(Self.describe(ioStatus))).")
        }

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanUp()
            return .failure("Could not start the device (\(Self.describe(startStatus))). System Audio Recording permission is likely not granted.")
        }
        Self.logger.notice("Capture started (\(AudioVisualizerService.bandCount, privacy: .public) bands, \(AudioAnalyzer.fftSize, privacy: .public)-point FFT)")
        return .success
    }

    func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanUp()
    }

    /// Torn down in reverse order of creation. Leaving a private aggregate
    /// device or a live tap behind outlives the process's usefulness and is
    /// exactly what "release all resources" means here.
    private func cleanUp() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        Self.logger.notice("Tap and aggregate device released")
    }

    deinit { cleanUp() }

    /// OSStatus as its four-character code when it is one, which is how
    /// Core Audio errors are actually documented.
    private static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(decoding: chars, as: UTF8.self))' \(status)"
        }
        return "\(status)"
    }
}

/// Windowing, FFT and smoothing. Unchanged from the ScreenCaptureKit
/// version: only the source of the PCM changed.
///
/// `nonisolated` for the same reason as `SystemAudioTap`: it runs on the
/// analysis queue, never on the main actor.
private nonisolated final class AudioAnalyzer {

    /// 1024 samples at 48kHz is ~21ms — fast enough to track a beat, long
    /// enough for usable low-frequency resolution. The tap happens to
    /// deliver exactly 1024-frame buffers.
    static let fftSize = 1024

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private var window: [Float]
    /// Previous frame, for the eased rise and slower fall.
    private var smoothed = [Float](repeating: 0, count: AudioVisualizerService.bandCount)
    /// Adaptive ceiling offset, in dB, tracking recent loudness. Starts at 0
    /// (the static references) and follows the material from there.
    private var gain: Float = 0

    init() {
        log2n = vDSP_Length(log2(Float(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: Self.fftSize)
        // Hann: without a window the FFT of a chopped signal smears energy
        // across every bin and the bands all move together.
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func bands(from samples: [Float]) -> [Float]? {
        guard let fftSetup, samples.count >= Self.fftSize else { return nil }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        samples.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        }

        let half = Self.fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { winPtr in
                    winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Fold once, then let the ceiling follow the same numbers the
        // mapping is about to use.
        let decibels = AudioVisualizerService.bandDecibels(
            magnitudes: magnitudes, into: AudioVisualizerService.bandCount)
        gain = AudioVisualizerService.updatedGain(
            current: gain, excess: AudioVisualizerService.excess(bandDecibels: decibels))
        let raw = AudioVisualizerService.normalize(bandDecibels: decibels, gain: gain)
        // Eased rise, slower fall: see `AudioVisualizerService.barAttack`
        // and `barRelease`.
        for i in smoothed.indices {
            smoothed[i] = AudioVisualizerService.smoothed(previous: smoothed[i], raw: raw[i])
        }
        return smoothed
    }
}

/// Lets a publish through at most once per `interval`, measured from the last
/// one it let through.
///
/// It admits once 90% of the interval has passed rather than all of it.
/// Buffers arrive with a little scheduling jitter, and without that margin a
/// buffer landing a hair early would be held back to the next one, so the
/// stride would flip between two buffers and three and the rate would wobble.
nonisolated struct PublishThrottle {

    let interval: TimeInterval
    private(set) var lastAdmitted: TimeInterval?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    mutating func admit(at now: TimeInterval) -> Bool {
        if let lastAdmitted, now - lastAdmitted < interval * 0.9 {
            return false
        }
        lastAdmitted = now
        return true
    }
}
