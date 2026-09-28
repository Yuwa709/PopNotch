import Accelerate
import CoreAudio
import AudioToolbox
import Foundation
import os

/// The gain state one aggregate's IOProc reads, preallocated so the realtime
/// thread never allocates, and shaped so it never locks either.
///
/// **Threading.** The engine queue writes `targets` and `mapping`; the IO
/// thread reads them and owns `current` exclusively after init. All shared
/// values are aligned 4-byte words. This project is arm64-only by decision
/// (`ARCHS = arm64`, no Intel Mac has a notch), and ARMv8 guarantees
/// single-copy atomicity for aligned word loads and stores, so a plain read
/// on the IO thread sees a whole value, never a torn one. Ordering is
/// handled structurally, not with barriers: a mapping row is written
/// *before* the HAL call that creates the topology it describes, and the IO
/// thread selects the row by the buffer count the HAL actually presents —
/// measured in the spike (M1, 2026-09-18): stream indices shift on a
/// tap-list edit, so the count is the only safe key.
final class TapRenderState {

    static let maxLegs = 8

    /// Per-slot target gain, engine-written.
    let targets: UnsafeMutablePointer<Float>
    /// Per-slot ramp position, IO-thread-private after `prepareSlot`.
    let current: UnsafeMutablePointer<Float>
    /// `mapping[bufferCount * maxLegs + streamIndex]` = slot, or -1 for a
    /// stream the engine has not mapped, which renders at unity.
    let mapping: UnsafeMutablePointer<Int32>
    /// Per-frame gain step: full scale in ~40 ms at the aggregate's rate.
    let slewPerFrame: Float

    init(sampleRate: Double) {
        slewPerFrame = Float(1.0 / (0.040 * max(sampleRate, 8000)))
        targets = .allocate(capacity: Self.maxLegs)
        current = .allocate(capacity: Self.maxLegs)
        mapping = .allocate(capacity: (Self.maxLegs + 1) * Self.maxLegs)
        targets.initialize(repeating: 1, count: Self.maxLegs)
        current.initialize(repeating: 1, count: Self.maxLegs)
        mapping.initialize(repeating: -1, count: (Self.maxLegs + 1) * Self.maxLegs)
    }

    deinit {
        targets.deallocate()
        current.deallocate()
        mapping.deallocate()
    }

    /// Engine side, before a slot can be mapped: the ramp starts at unity so
    /// an engaging app is level-matched to the original it just replaced.
    func prepareSlot(_ slot: Int, targetGain: Float) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        current[slot] = 1
        targets[slot] = targetGain
    }

    func setTarget(_ gain: Float, slot: Int) {
        guard slot >= 0, slot < Self.maxLegs else { return }
        targets[slot] = gain
    }

    /// Engine side: publish which slot each stream feeds when the callback
    /// presents `bufferCount` buffers. Written before the topology edit that
    /// makes that count real.
    func setMapping(bufferCount: Int, slots: [Int32]) {
        guard bufferCount >= 0, bufferCount <= Self.maxLegs else { return }
        for stream in 0..<Self.maxLegs {
            mapping[bufferCount * Self.maxLegs + stream] =
                stream < slots.count ? slots[stream] : -1
        }
    }
}

/// One output device, as the engine needs it for qualification.
struct TapHALDevice: Equatable {
    var uid: String
    var name: String
    var sampleRate: Double
    /// True only for a single interleaved 2-channel output stream — the one
    /// layout the IOProc writes. Stereo split across streams is excluded.
    var isStereoOut: Bool
    var isAirPlay: Bool
    /// The device also carries input streams (a headset's microphone). An
    /// aggregate exposes its sub-devices' input streams to the IOProc
    /// alongside the tap streams, which would corrupt the buffer-count
    /// mapping key and pass the microphone into its own output at unity.
    /// Unmeasured territory, so v1 excludes such devices (caught in the
    /// Phase 5 code review, 2026-09-19).
    var hasInputStreams: Bool
}

/// Everything the tap engine asks of Core Audio, behind a seam so tests run
/// the entire lifecycle against a fake. No test creates a real tap or
/// aggregate (docs/FUTURE-audio-mixer.md, *Carried from the plan*).
///
/// Called only on the engine's serial queue.
protocol TapHAL: AnyObject {
    /// A `.mutedWhenTapped` private tap on these process objects.
    func makeTap(processObjects: [AudioObjectID]) -> (tap: AudioObjectID, uid: String)?
    /// An `.unmuted` global tap: the permission probe (decision 3 — the
    /// audio-recording prompt belongs to the toggle, not to first playback).
    func makeProbeTap() -> (tap: AudioObjectID, uid: String)?
    func destroyTap(_ tap: AudioObjectID)

    /// A private aggregate over `tapUIDs`, rendering to `outputDeviceUID`
    /// (nil for the probe's tap-only aggregate).
    func makeAggregate(outputDeviceUID: String?, tapUIDs: [String]) -> AudioObjectID?
    /// Live tap-list edit; measured to work in both directions (M1).
    func setTapList(_ uids: [String], onAggregate: AudioObjectID) -> Bool
    func destroyAggregate(_ id: AudioObjectID)

    /// Installs the canonical gain-and-mix IOProc reading `render`.
    func installIOProc(onAggregate: AudioObjectID, render: TapRenderState) -> AudioDeviceIOProcID?
    func destroyIOProc(_ proc: AudioDeviceIOProcID, onAggregate: AudioObjectID)
    /// Blocks during the permission prompt; that is why the engine queue,
    /// never main, calls it.
    func start(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus
    func stop(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID)

    func processObject(forPID pid: pid_t) -> AudioObjectID?
    func device(forUID uid: String) -> TapHALDevice?
    /// Every device with output streams that a user could route an app to,
    /// sorted by name. This process's own private aggregates (the engine's
    /// and the visualiser's) are left out: they are visible only to us, and
    /// they are the machinery, not a destination.
    func outputDevices() -> [TapHALDevice]

    /// coreaudiod restarted: every object this engine holds is invalid.
    var onServiceRestarted: (() -> Void)? { get set }
    /// The system's device list changed: something was plugged in or
    /// unplugged — or one of our own aggregates came or went, which the
    /// engine filters out by comparing `outputDevices()`.
    var onDevicesChanged: (() -> Void)? { get set }
    /// The named device's nominal rate or stream layout changed.
    var onDeviceFormatChanged: ((String) -> Void)? { get set }
    /// Registers format listeners for exactly these device UIDs (the ones
    /// with a live aggregate), dropping listeners for any other.
    func watchDeviceFormats(uids: Set<String>)
}

/// The real Core Audio implementation.
nonisolated final class CoreAudioTapHAL: TapHAL {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "TapHAL")

    var onServiceRestarted: (() -> Void)?
    var onDeviceFormatChanged: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var restartListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var formatListeners: [String: (device: AudioObjectID, block: AudioObjectPropertyListenerBlock)] = [:]
    /// Serializes listener bookkeeping with the engine queue's calls.
    private let listenerQueue = DispatchQueue(label: "com.techie.PopNotch.taphal.listeners")

    init() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = Self.address(kAudioHardwarePropertyServiceRestarted)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Self.logger.notice("coreaudiod restarted; every tap object is invalid")
            self?.onServiceRestarted?()
        }
        if AudioObjectAddPropertyListenerBlock(system, &addr, listenerQueue, block) == noErr {
            restartListener = block
        } else {
            Self.logger.error("Could not watch for coreaudiod restarts")
        }
        // Push-only, like the restart listener: a routed device being
        // unplugged, or coming back, is what makes the engine re-resolve
        // routes. No timer (hard rule 9); nothing to suspend.
        var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        if AudioObjectAddPropertyListenerBlock(system, &devicesAddr, listenerQueue, devicesBlock) == noErr {
            devicesListener = devicesBlock
        } else {
            Self.logger.error("Could not watch the device list; routes will not follow unplugs")
        }
    }

    func makeTap(processObjects: [AudioObjectID]) -> (tap: AudioObjectID, uid: String)? {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "PopNotch Volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            Self.logger.error("Create tap failed (\(status, privacy: .public))")
            return nil
        }
        return (tapID, description.uuid.uuidString)
    }

    func makeProbeTap() -> (tap: AudioObjectID, uid: String)? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "PopNotch Volume Probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            Self.logger.error("Create probe tap failed (\(status, privacy: .public))")
            return nil
        }
        return (tapID, description.uuid.uuidString)
    }

    func destroyTap(_ tap: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tap)
    }

    func makeAggregate(outputDeviceUID: String?, tapUIDs: [String]) -> AudioObjectID? {
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PopNotch Volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: $0]
            },
        ]
        if let outputDeviceUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
        } else {
            dict[kAudioAggregateDeviceSubDeviceListKey] = [] as [[String: Any]]
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard status == noErr else {
            Self.logger.error("Create aggregate failed (\(status, privacy: .public))")
            return nil
        }
        return aggID
    }

    func setTapList(_ uids: [String], onAggregate id: AudioObjectID) -> Bool {
        var addr = Self.address(kAudioAggregateDevicePropertyTapList)
        var value = uids as CFArray
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(id, &addr, 0, nil,
                                       UInt32(MemoryLayout<CFArray>.size), $0)
        }
        if status != noErr {
            Self.logger.error("Live tap-list edit failed (\(status, privacy: .public))")
        }
        return status == noErr
    }

    func destroyAggregate(_ id: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(id)
    }

    func installIOProc(onAggregate id: AudioObjectID, render: TapRenderState) -> AudioDeviceIOProcID? {
        var procID: AudioDeviceIOProcID?
        // The realtime path: no allocation, no locks, no ObjC, and `render`
        // is captured strongly once here, so no retain traffic per callback.
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, id, nil) {
            _, inputData, _, outputData, _ in
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            guard let out = outputs.first, let outRaw = out.mData else { return }
            let outSamples = Int(out.mDataByteSize) / MemoryLayout<Float>.size
            let outPtr = outRaw.assumingMemoryBound(to: Float.self)
            vDSP_vclr(outPtr, 1, vDSP_Length(outSamples))

            // The per-sample work is vDSP whenever possible: the app ships
            // and runs as a Debug build, where a per-frame Swift loop costs
            // ~50x its Release self (measured 2026-09-19: 3.2 s/60 s of one
            // core for a single leg, against a 0.19 s Release reference).
            // vDSP is a library call and pays no such tax. Realtime-safe:
            // no allocation, no locks.
            let bufferCount = min(inputs.count, TapRenderState.maxLegs)
            let row = bufferCount * TapRenderState.maxLegs
            for (stream, buffer) in inputs.enumerated() where stream < bufferCount {
                guard let raw = buffer.mData else { continue }
                let samples = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, outSamples)
                guard samples > 0 else { continue }
                let inPtr = raw.assumingMemoryBound(to: Float.self)
                let slot = Int(render.mapping[row + stream])
                if slot < 0 || slot >= TapRenderState.maxLegs {
                    // Unmapped stream: pass through at unity. Safe for the
                    // one-callback window around a topology edit.
                    vDSP_vadd(outPtr, 1, inPtr, 1, outPtr, 1, vDSP_Length(samples))
                    continue
                }
                var gain = render.current[slot]
                let target = render.targets[slot]
                if gain == target {
                    // Steady state — the overwhelmingly common case: one
                    // scaled accumulate over the whole buffer.
                    if gain != 0 {
                        vDSP_vsma(inPtr, 1, &gain, outPtr, 1, outPtr, 1, vDSP_Length(samples))
                    }
                    continue
                }
                // Ramping: a couple of buffers per gain change. Scalar per
                // frame, clamped to whole frames so no bounds check is
                // needed inside the channel loop.
                let slew = render.slewPerFrame
                let channels = Int(max(1, buffer.mNumberChannels))
                let whole = (samples / channels) * channels
                var i = 0
                while i < whole {
                    let delta = target - gain
                    if delta > slew { gain += slew }
                    else if delta < -slew { gain -= slew }
                    else { gain = target }
                    for c in 0..<channels {
                        outPtr[i + c] += inPtr[i + c] * gain
                    }
                    i += channels
                }
                render.current[slot] = gain
            }
        }
        guard status == noErr, let procID else {
            Self.logger.error("Create IOProc failed (\(status, privacy: .public))")
            return nil
        }
        return procID
    }

    func destroyIOProc(_ proc: AudioDeviceIOProcID, onAggregate id: AudioObjectID) {
        AudioDeviceDestroyIOProcID(id, proc)
    }

    func start(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceStart(aggregate, proc)
    }

    func stop(_ aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        AudioDeviceStop(aggregate, proc)
    }

    func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                                &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    func device(forUID uid: String) -> TapHALDevice? {
        let ids = Self.allDeviceIDs()
        for id in ids where Self.string(id, kAudioDevicePropertyDeviceUID) == uid {
            return Self.describe(id, uid: uid)
        }
        return nil
    }

    func outputDevices() -> [TapHALDevice] {
        Self.allDeviceIDs()
            .compactMap { id -> TapHALDevice? in
                guard Self.streamLayout(id, scope: kAudioObjectPropertyScopeOutput).streams > 0,
                      (Self.scalar(id, kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) == 0,
                      !Self.isOwnPrivateAggregate(id),
                      let uid = Self.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
                return Self.describe(id, uid: uid)
            }
            .sorted { ($0.name.localizedLowercase, $0.uid) < ($1.name.localizedLowercase, $1.uid) }
    }

    private static func describe(_ id: AudioObjectID, uid: String) -> TapHALDevice {
        let transport = scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0
        let out = streamLayout(id, scope: kAudioObjectPropertyScopeOutput)
        let input = streamLayout(id, scope: kAudioObjectPropertyScopeInput)
        return TapHALDevice(
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            sampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48000,
            isStereoOut: out.streams == 1 && out.channels == 2,
            isAirPlay: transport == kAudioDeviceTransportTypeAirPlay,
            hasInputStreams: input.streams > 0)
    }

    /// A private aggregate is visible only to the process that made it, so
    /// any we can see is ours. The composition's private flag is the
    /// principled test; the name prefix covers an aggregate whose
    /// composition cannot be read.
    private static func isOwnPrivateAggregate(_ id: AudioObjectID) -> Bool {
        guard scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self)
                == kAudioDeviceTransportTypeAggregate else { return false }
        if let composition = dictionary(id, kAudioAggregateDevicePropertyComposition),
           let isPrivate = composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber,
           isPrivate.boolValue {
            return true
        }
        return string(id, kAudioObjectPropertyName)?.hasPrefix("PopNotch ") ?? false
    }

    func watchDeviceFormats(uids: Set<String>) {
        for (uid, listener) in formatListeners where !uids.contains(uid) {
            var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(listener.device, &addr, listenerQueue, listener.block)
            var cfg = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(listener.device, &cfg, listenerQueue, listener.block)
            formatListeners[uid] = nil
        }
        for uid in uids where formatListeners[uid] == nil {
            guard let id = Self.allDeviceIDs().first(where: {
                Self.string($0, kAudioDevicePropertyDeviceUID) == uid
            }) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.onDeviceFormatChanged?(uid)
            }
            var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
            var cfg = Self.address(kAudioDevicePropertyStreamConfiguration,
                                   scope: kAudioObjectPropertyScopeOutput)
            let a = AudioObjectAddPropertyListenerBlock(id, &addr, listenerQueue, block)
            let b = AudioObjectAddPropertyListenerBlock(id, &cfg, listenerQueue, block)
            if a == noErr || b == noErr {
                formatListeners[uid] = (id, block)
            } else {
                Self.logger.error("Could not watch device format for \(uid, privacy: .public)")
            }
        }
    }

    // MARK: - Property plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func streamLayout(_ id: AudioObjectID,
                                     scope: AudioObjectPropertyScope) -> (streams: Int, channels: Int) {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return (0, 0) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return (0, 0) }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return (list.count, list.reduce(0) { $0 + Int($1.mNumberChannels) })
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  as type: T.Type) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr
        else { return nil }
        return pointer.pointee
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func dictionary(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector) -> [String: Any]? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var value: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }
}
