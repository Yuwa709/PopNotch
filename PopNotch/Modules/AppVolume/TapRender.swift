import Accelerate
import CoreAudio

/// The IOProc's body: bass boost and its limiter, then gain, then mix, for
/// every stream the aggregate presents. A method rather than a closure so
/// tests can drive it with synthesized buffers; no test ever runs it on a
/// device.
///
/// The per-sample work is vDSP whenever possible: the app ships and runs as
/// a Debug build, where a per-frame Swift loop costs ~50x its Release self
/// (measured 2026-09-19: 3.2 s/60 s of one core for a single leg, against a
/// 0.19 s Release reference). vDSP is a library call and pays no such tax.
/// Realtime-safe: no allocation, no locks, no ObjC — everything touched
/// here was allocated in `init`.
extension TapRenderState {

    nonisolated func render(inputs: UnsafeMutableAudioBufferListPointer,
                            outputs: UnsafeMutableAudioBufferListPointer) {
        guard let out = outputs.first, let outRaw = out.mData else { return }
        let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
        let outPtr = outRaw.assumingMemoryBound(to: Float.self)
        vDSP_vclr(outPtr, 1, vDSP_Length(outSamples))

        let bufferCount = min(inputs.count, Self.maxLegs)
        let row = bufferCount * Self.maxLegs
        for (stream, buffer) in inputs.enumerated() where stream < bufferCount {
            guard let raw = buffer.mData else { continue }
            let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, outSamples)
            guard samples > 0 else { continue }
            let inPtr = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
            let slot = Int(mapping[row + stream])
            if slot < 0 || slot >= Self.maxLegs {
                // Unmapped stream: pass through at unity, unfiltered. Safe
                // for the one-callback window around a topology edit.
                vDSP_vadd(outPtr, 1, inPtr, 1, outPtr, 1, vDSP_Length(samples))
                continue
            }
            let channels = Int(max(1, buffer.mNumberChannels))
            // The slot changed hands since this thread last filtered it:
            // its history is the previous leg's and must not ring on.
            let generation = generations[slot]
            if generation != seenGenerations[slot] {
                seenGenerations[slot] = generation
                resetFilter(slot)
            }
            let level = Int(bassLevels[slot])
            let applied = Int(appliedLevels[slot])
            if (level == 0 && applied == 0) || channels > Self.channelsFiltered {
                // No boost — the common case, and exactly the Phase 5 path.
                mix(inPtr, into: outPtr, samples: samples, slot: slot, channels: channels)
                continue
            }
            boostAndMix(inPtr, into: outPtr, samples: samples, slot: slot,
                        channels: channels, level: level, applied: applied)
        }
    }

    private nonisolated func resetFilter(_ slot: Int) {
        appliedLevels[slot] = 0
        let count = Self.channelsFiltered * Self.delayPerChannel
        vDSP_vclr(delays + slot * count, 1, vDSP_Length(count))
        resetLimiter(slot)
    }

    private nonisolated func resetLimiter(_ slot: Int) {
        limiterGains[slot] = 1
        limiterHolds[slot] = 0
        let lane = Self.channelsFiltered * Self.maxLookahead
        vDSP_vclr(limiterDelays + slot * lane, 1, vDSP_Length(lane))
    }

    /// The boosted path, a chunk at a time so any buffer size fits the
    /// preallocated scratch: shelf, then limiter, then gain and mix. A level
    /// change crossfades over this one callback from the old curve (or dry,
    /// for off) to the new one, both run over the same input, so the switch
    /// never clicks.
    ///
    /// The limiter delays the boosted audio by its lookahead, so switching
    /// on and off crossfades between the dry signal and a copy 1 ms behind
    /// it. Switching on, the limiter's delay line starts silent; the fade
    /// waits out that silence before it begins, or it would dip.
    private nonisolated func boostAndMix(_ input: UnsafePointer<Float>,
                                         into output: UnsafeMutablePointer<Float>,
                                         samples: Int, slot: Int, channels: Int,
                                         level: Int, applied: Int) {
        let historyCount = Self.channelsFiltered * Self.delayPerChannel
        let history = delays + slot * historyCount
        let whole = (samples / channels) * channels
        guard whole > 0 else { return }
        let fading = level != applied
        if fading && applied == 0 {
            // Off to on: any history here is from an earlier on-period of
            // this leg, not from the audio arriving now.
            vDSP_vclr(history, 1, vDSP_Length(historyCount))
            resetLimiter(slot)
        }
        if fading && applied != 0 && level != 0 {
            // Level to level: the outgoing curve runs on a copy, and the
            // incoming one inherits the real history — close enough to its
            // own steady state for the crossfade to hide the difference.
            crossfadeDelay.update(from: history, count: historyCount)
        }
        let outgoing = scratch
        let incoming = scratch + Self.chunkSamples
        let mixed = scratch + 2 * Self.chunkSamples
        // Off to on: dry until the limiter's delay line has filled with
        // boosted audio. Half the buffer at most, for a buffer shorter than
        // two lookaheads.
        let wait = fading && applied == 0 ? min(limiterLookahead * channels, whole / 2) : 0
        var fade = Crossfade(fadeIn: 0, fadeOut: 1, step: 1 / Float(max(whole - wait - 1, 1)), wait: wait)

        var offset = 0
        while offset < whole {
            let count = min(Self.chunkSamples, whole - offset)
            let source = input + offset
            let destination = output + offset
            guard fading else {
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                limit(incoming, count: count, slot: slot, channels: channels)
                mix(incoming, into: destination, samples: count, slot: slot, channels: channels)
                offset += count
                continue
            }
            if applied != 0 && level != 0 {
                // Both curves through one limiter: its delay stays continuous.
                biquad(applied, history: crossfadeDelay, source, into: outgoing, count: count, channels: channels)
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                fade.run(new: incoming, old: outgoing, into: mixed, count: count, at: offset)
                limit(mixed, count: count, slot: slot, channels: channels)
            } else if level != 0 {
                biquad(level, history: history, source, into: incoming, count: count, channels: channels)
                limit(incoming, count: count, slot: slot, channels: channels)
                fade.run(new: incoming, old: source, into: mixed, count: count, at: offset)
            } else {
                biquad(applied, history: history, source, into: outgoing, count: count, channels: channels)
                limit(outgoing, count: count, slot: slot, channels: channels)
                fade.run(new: source, old: outgoing, into: mixed, count: count, at: offset)
            }
            mix(mixed, into: destination, samples: count, slot: slot, channels: channels)
            offset += count
        }
        appliedLevels[slot] = Int32(level)
    }

    /// The limiter (`BassBoost.Limiter`), in place over one chunk: the
    /// chunk comes out `limiterLookahead` frames late, times a gain that
    /// ramps linearly between knots one block apart. Each knot is the
    /// gain the knee allows for the loudest sample, either channel, in the
    /// block before it and the block after it — which the lookahead lets
    /// it see — so no sample passes the ceiling. Per block, not per sample:
    /// a peak scan and a ramp per channel, all vDSP, so the Debug build's
    /// per-sample tax never applies.
    private nonisolated func limit(_ buffer: UnsafeMutablePointer<Float>,
                                   count: Int, slot: Int, channels: Int) {
        let frames = count / channels
        guard frames > 0 else { return }
        let block = limiterLookahead
        let delayed = block * channels
        let line = limiterDelays + slot * Self.channelsFiltered * Self.maxLookahead
        let work = limiterScratch
        work.update(from: line, count: delayed)
        (work + delayed).update(from: buffer, count: frames * channels)

        var gain = limiterGains[slot]
        var hold = Int(limiterHolds[slot])
        var frame = 0
        while frame < frames {
            let length = min(block, frames - frame)
            var peak: Float = 0
            vDSP_maxmgv(work + frame * channels, 1, &peak, vDSP_Length((length + block) * channels))
            let allowed = BassBoost.Limiter.gain(forPeak: peak)
            let next: Float
            if allowed <= gain * BassBoost.Limiter.holdMargin {
                // At or past the current reduction: attack, or settle the
                // last 0.1 dB up onto exactly what this peak needs — held
                // below it, the gain would sit up to 0.1 dB too low for as
                // long as the note lasts. Either way, re-arm the hold.
                next = allowed
                hold = limiterHoldFrames
            } else if hold > 0 {
                next = gain
                hold = max(hold - length, 0)
            } else {
                let recovered = 1 - (1 - gain) * exp(-Float(length) / limiterReleaseFrames)
                next = min(allowed, recovered)
            }
            var step = (next - gain) / Float(length)
            for channel in 0..<channels {
                var start = gain
                vDSP_vrampmul(work + frame * channels + channel, channels, &start, &step,
                              buffer + frame * channels + channel, channels, vDSP_Length(length))
            }
            gain = next
            frame += length
        }
        line.update(from: work + frames * channels, count: delayed)
        limiterGains[slot] = gain
        limiterHolds[slot] = Int32(hold)
    }

    /// One section per channel over interleaved samples, each channel with
    /// its own history: left's bass never leaks into right's filter.
    private nonisolated func biquad(_ level: Int, history: UnsafeMutablePointer<Float>,
                                    _ source: UnsafePointer<Float>,
                                    into destination: UnsafeMutablePointer<Float>,
                                    count: Int, channels: Int) {
        guard BassBoost.levels.contains(level), let setup = setups[level] else {
            destination.update(from: source, count: count)
            return
        }
        let frames = vDSP_Length(count / channels)
        for channel in 0..<channels {
            vDSP_biquad(setup, history + channel * Self.delayPerChannel,
                        source + channel, channels,
                        destination + channel, channels, frames)
        }
    }

    /// Gain and accumulate: the Phase 5 path, unchanged.
    private nonisolated func mix(_ input: UnsafePointer<Float>,
                                 into output: UnsafeMutablePointer<Float>,
                                 samples: Int, slot: Int, channels: Int) {
        var gain = current[slot]
        let target = targets[slot]
        if gain == target {
            // Steady state — the overwhelmingly common case: one scaled
            // accumulate over the whole buffer.
            if gain != 0 {
                vDSP_vsma(input, 1, &gain, output, 1, output, 1, vDSP_Length(samples))
            }
            return
        }
        // Ramping: a couple of buffers per gain change. Scalar per frame,
        // clamped to whole frames so no bounds check is needed inside the
        // channel loop.
        let slew = slewPerFrame
        let whole = (samples / channels) * channels
        var i = 0
        while i < whole {
            let delta = target - gain
            if delta > slew { gain += slew }
            else if delta < -slew { gain -= slew }
            else { gain = target }
            for c in 0..<channels {
                output[i + c] += input[i + c] * gain
            }
            i += channels
        }
        current[slot] = gain
    }
}

/// One callback's crossfade, carried across chunks: `new` ramps in and
/// `old` out, per sample, after `wait` samples of `old` alone.
private struct Crossfade {
    var fadeIn: Float
    var fadeOut: Float
    var step: Float
    let wait: Int

    nonisolated mutating func run(new: UnsafePointer<Float>, old: UnsafePointer<Float>,
                                  into mixed: UnsafeMutablePointer<Float>, count: Int, at offset: Int) {
        let held = min(max(wait - offset, 0), count)
        if held > 0 { mixed.update(from: old, count: held) }
        let ramped = count - held
        guard ramped > 0 else { return }
        var negativeStep = -step
        vDSP_vrampmul(new + held, 1, &fadeIn, &step, mixed + held, 1, vDSP_Length(ramped))
        vDSP_vrampmuladd(old + held, 1, &fadeOut, &negativeStep, mixed + held, 1, vDSP_Length(ramped))
    }
}
