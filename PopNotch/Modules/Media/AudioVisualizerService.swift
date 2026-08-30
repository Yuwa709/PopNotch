import Foundation
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
/// enabled, panel-visible and *actively playing* hold, and is torn down the
/// moment any of them stops — hard rule 9's "nothing runs when nobody is
/// looking", expressed without a timer.
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
    @ObservationIgnored private var panelVisible = false
    /// Driven by the media module from the active source's player state.
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var capture: SystemAudioTap?
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

    /// How far below its reference a band stays visible. 45 dB reaches down
    /// to the quiet parts of a mix without letting noise light the bars.
    nonisolated static let dynamicWindow: Float = 45

    /// Folds FFT bins into log-spaced bands, normalised to roughly 0...1.
    ///
    /// Log spacing because linear bins put almost everything musical in the
    /// first band or two. Pure, and on the service rather than the private tap so it is testable.
    nonisolated static func fold(magnitudes: [Float], into bandCount: Int) -> [Float] {
        guard !magnitudes.isEmpty, bandCount > 0 else {
            return [Float](repeating: 0, count: max(0, bandCount))
        }
        var bands = [Float](repeating: 0, count: bandCount)
        let maxBin = Float(magnitudes.count)
        for band in 0..<bandCount {
            let lo = Int(powf(maxBin, Float(band) / Float(bandCount)))
            let hi = max(lo + 1, Int(powf(maxBin, Float(band + 1) / Float(bandCount))))
            let upper = min(hi, magnitudes.count)
            guard lo < upper else { continue }
            var sum: Float = 0
            for bin in lo..<upper { sum += magnitudes[bin] }
            let mean = sum / Float(upper - lo)
            // dB against this band's own reference, so the spectral tilt of
            // real music does not pin the bass and starve the treble.
            let db = 20 * log10f(max(mean, 1e-9))
            let reference = band < Self.referenceDB.count ? Self.referenceDB[band] : 0
            bands[band] = min(1, max(0, (db - (reference - Self.dynamicWindow)) / Self.dynamicWindow))
        }
        return bands
    }

    // MARK: - Control

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        Self.logger.notice("Visualiser \(on ? "enabled" : "disabled", privacy: .public)")
        reconcile()
    }

    /// Called by whatever owns panel visibility. Capture must not run for a
    /// panel nobody can see.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        reconcile()
    }

    /// Called by the media module whenever the active source's play state
    /// changes. Not a poll: this rides the adapter's existing push updates.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        reconcile()
    }

    private var shouldRun: Bool { isEnabled && panelVisible && isPlaying }

    private func reconcile() {
        if shouldRun {
            if capture == nil { start() }
        } else if capture != nil {
            stop(reason: stopReason)
        }
    }

    private var stopReason: String {
        if !isEnabled { return "disabled" }
        if !panelVisible { return "panel not visible" }
        return "playback stopped"
    }

    // MARK: - Capture

    private func start() {
        let engine = SystemAudioTap { [weak self] bands in
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
            // Authorization shows up here, since the audio-only grant has no
            // preflight. Quiet decline, no retry loop.
            Self.logger.error("Capture failed: \(reason, privacy: .public)")
        }
    }

    private func stop(reason: String) {
        guard let engine = capture else { return }
        capture = nil
        isRunning = false
        bands = Array(repeating: 0, count: Self.bandCount)
        engine.stop()
        Self.logger.notice("Capture stopped (\(reason, privacy: .public))")
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
private nonisolated final class SystemAudioTap {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AudioViz")

    enum StartResult {
        case success
        case failure(String)
    }

    private let onBands: ([Float]) -> Void
    private let analyzer = AudioAnalyzer()
    /// The FFT runs here, never on the realtime IO thread: the analysis
    /// allocates, and allocating in a Core Audio callback is how you get
    /// dropouts in the audio the user is actually listening to.
    private let analysisQueue = DispatchQueue(label: "com.techie.PopNotch.audioviz",
                                              qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(onBands: @escaping ([Float]) -> Void) {
        self.onBands = onBands
    }

    func start() -> StartResult {
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
                guard let bands = self.analyzer.bands(from: samples) else { return }
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
    /// Previous frame, for the decay that stops the bars strobing.
    private var smoothed = [Float](repeating: 0, count: AudioVisualizerService.bandCount)

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

        let raw = AudioVisualizerService.fold(magnitudes: magnitudes,
                                              into: AudioVisualizerService.bandCount)
        // Attack fast, release slow: a bar that falls as fast as it rises
        // reads as flicker rather than as level.
        for i in smoothed.indices {
            smoothed[i] = raw[i] > smoothed[i] ? raw[i] : smoothed[i] * 0.82 + raw[i] * 0.18
        }
        return smoothed
    }
}
