import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import Accelerate
import Observation
import os

/// System-audio capture reduced to a small band spectrum, for a future
/// notch visualiser.
///
/// Distinct from `ArtworkVisualizerView`, which derives a glow from album
/// artwork and never touches audio. This reads the actual output signal.
///
/// **Permission.** ScreenCaptureKit audio is gated by Screen Recording.
/// `project.pbxproj` carries no screen-capture or `NSAudioCaptureUsageDescription`
/// string, and CLAUDE.md is clear that requesting a permission without its
/// usage string gets the process killed. So this never *requests* anything:
/// it calls `CGPreflightScreenCaptureAccess()`, which was verified not to
/// prompt, and declines to start when that is false. Granting happens in
/// System Settings. Add the usage strings before changing that.
///
/// **Lifetime.** Off by default. Capture runs only while explicitly enabled
/// *and* the panel is visible, and is torn down on disable, on the panel
/// going away, and on deinit — hard rule 9's "nothing runs when nobody is
/// looking", expressed without a timer.
@MainActor
@Observable
final class AudioVisualizerService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "AudioViz")

    /// Bands published to any future view. Log-spaced, so low frequencies —
    /// where music actually lives — are not crushed into one bar.
    static let bandCount = 16

    private(set) var bands: [Float] = Array(repeating: 0, count: bandCount)
    private(set) var isRunning = false
    /// Why capture is not running, when that is worth showing or logging.
    private(set) var lastError: String?

    @ObservationIgnored private(set) var isEnabled = false
    @ObservationIgnored private var panelVisible = false
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var tap: AudioTap?
    /// Throttles the verification logging; no timer, just a clock check on
    /// buffers that are arriving anyway.
    @ObservationIgnored private var lastLogged = Date.distantPast

    /// Folds FFT bins into log-spaced bands, normalised to roughly 0...1.
    ///
    /// Log spacing because linear bins put almost everything musical in the
    /// first band or two. Internal for tests.
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
            // dB, then squashed into 0...1. Raw magnitudes span orders of
            // magnitude and would render as one tall bar and fifteen flat ones.
            let db = 20 * log10f(max(mean, 1e-9))
            bands[band] = min(1, max(0, (db + 60) / 60))
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

    private var shouldRun: Bool { isEnabled && panelVisible }

    private func reconcile() {
        if shouldRun {
            if stream == nil { start() }
        } else if stream != nil {
            stop(reason: isEnabled ? "panel not visible" : "disabled")
        }
    }

    // MARK: - Capture

    private func start() {
        // Preflight only. Never CGRequestScreenCaptureAccess: see the note on
        // this type. This call does not prompt.
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "Screen Recording permission is required for audio capture."
            isRunning = false
            Self.logger.notice("Permission check: DENIED (Screen Recording not granted); not starting")
            return
        }
        Self.logger.notice("Permission check: granted")

        Task { [weak self] in
            guard let self else { return }
            do {
                // Audio needs a content filter even when video is unwanted, so
                // take a display and shrink the video side to almost nothing.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    self.fail("No display available to attach the audio stream to.")
                    return
                }
                guard self.shouldRun else { return } // disabled while awaiting

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = AudioTap.sampleRate
                config.channelCount = 1
                // Video is unavoidable baggage; make it as small as allowed.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                let tap = AudioTap { [weak self] bands in
                    Task { @MainActor in self?.publish(bands) }
                }
                try stream.addStreamOutput(tap, type: .audio,
                                           sampleHandlerQueue: AudioTap.queue)
                try await stream.startCapture()

                guard self.shouldRun else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.tap = tap
                self.isRunning = true
                self.lastError = nil
                Self.logger.notice("Capture started (\(Self.bandCount, privacy: .public) bands, \(AudioTap.fftSize, privacy: .public)-point FFT)")
            } catch {
                self.fail("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        isRunning = false
        stream = nil
        tap = nil
        Self.logger.error("\(message, privacy: .public)")
    }

    private func stop(reason: String) {
        guard let stream else { return }
        self.stream = nil
        tap = nil
        isRunning = false
        bands = Array(repeating: 0, count: Self.bandCount)
        Self.logger.notice("Capture stopped (\(reason, privacy: .public))")
        Task { try? await stream.stopCapture() }
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
        // Nonisolated: touch only the stream handle and let it tear itself
        // down. No main-actor state, no logging.
        if let stream { Task { try? await stream.stopCapture() } }
    }
}

/// Receives audio buffers off the main thread and reduces each to bands.
///
/// Separate from the service on purpose: `SCStream` delivers on its own
/// queue, and the FFT has no business running on the main actor.
private final class AudioTap: NSObject, SCStreamOutput {

    static let sampleRate = 48_000
    /// 1024 samples at 48kHz is ~21ms — fast enough to track a beat, long
    /// enough for usable low-frequency resolution.
    static let fftSize = 1024
    static let queue = DispatchQueue(label: "com.techie.PopNotch.audioviz", qos: .userInitiated)

    private let onBands: ([Float]) -> Void
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private var window: [Float]
    /// Previous frame, for the decay that stops the bars strobing.
    private var smoothed = [Float](repeating: 0, count: AudioVisualizerService.bandCount)

    init(onBands: @escaping ([Float]) -> Void) {
        self.onBands = onBands
        log2n = vDSP_Length(log2(Float(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: Self.fftSize)
        super.init()
        // Hann: without a window the FFT of a chopped signal smears energy
        // across every bin and the bands all move together.
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let samples = Self.monoSamples(from: sampleBuffer) else { return }
        guard let bands = magnitudes(samples) else { return }
        onBands(bands)
    }

    /// Flattens the buffer to mono floats. Returns nil rather than guessing
    /// when the layout is not what was configured.
    private static func monoSamples(from buffer: CMSampleBuffer) -> [Float]? {
        try? buffer.withAudioBufferList { list, _ -> [Float]? in
            guard let first = list.first,
                  let data = first.mData else { return nil }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                             count: count))
        } ?? nil
    }

    private func magnitudes(_ samples: [Float]) -> [Float]? {
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

        let raw = AudioVisualizerService.fold(magnitudes: magnitudes, into: AudioVisualizerService.bandCount)
        // Attack fast, release slow: a bar that falls as fast as it rises
        // reads as flicker rather than as level.
        for i in smoothed.indices {
            smoothed[i] = raw[i] > smoothed[i] ? raw[i] : smoothed[i] * 0.82 + raw[i] * 0.18
        }
        return smoothed
    }
}
