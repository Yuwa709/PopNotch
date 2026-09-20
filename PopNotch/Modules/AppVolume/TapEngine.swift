import AppKit
import CoreAudio
import Foundation
import os

/// The Phase 5 tap engine: per-app volume for everything that is not
/// Spotify or Music, via `.mutedWhenTapped` process taps mixed back to the
/// owner's own output device through one shared aggregate per device.
///
/// Owned by AppDelegate (v1 plan, decision 4). Every Core Audio call runs on
/// one serial queue, never main — `AudioDeviceStart` blocks while the
/// permission prompt is up (measured 17 s in the spike). The desired state
/// arrives from `AppVolumeService` as `TapDesire` rows; `TapReconciler`
/// (pure) turns desired-versus-actual into ops; this type executes them.
///
/// Lifecycle facts this design leans on, all measured 2026-09-18 (see
/// docs/FUTURE-audio-mixer.md, *Phase 5 pre-build measurements*):
/// - a live aggregate's tap list is editable both ways with IO running,
///   and the mute follows list membership, so same-device topology changes
///   never rebuild the aggregate;
/// - stream indices shift on removal, so per-stream gain mapping is keyed
///   by the callback's buffer count (`TapRenderState`);
/// - with two taps on one process the mute holds until the last one goes,
///   so a device move is make-before-break;
/// - revoking the grant does nothing to a live tap (TCC checks at start),
///   so there is no runtime watchdog: a failed start marks the permission
///   denied and the taps toggle is the recovery lever.
nonisolated final class TapEngine {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "TapEngine")

    /// How long a disengage ramp gets before the leg is removed. The IOProc
    /// slews full scale in ~40 ms; 120 ms covers any start gain with margin.
    private let rampDelay: TimeInterval
    /// The one-shot grace after an owner stops outputting, so a brief pause
    /// does not tear down and rebuild the whole path (carried from the
    /// plan). Cancelled by a resume; the fire re-checks before acting.
    private let graceDelay: TimeInterval

    private let hal: TapHAL
    /// nil under test: calls run synchronously in the caller's context.
    private let queue: DispatchQueue?
    /// Delayed work, injectable so tests fire it deterministically.
    /// Returns a cancel closure.
    private let schedule: (TimeInterval, @escaping () -> Void) -> () -> Void
    /// Delivers `onStatesChange` (main queue in production).
    private let notify: (@escaping () -> Void) -> Void

    /// Row states for the page, keyed by owner key. Delivered via `notify`.
    var onStatesChange: (([String: TapRowState]) -> Void)?

    // MARK: - Engine-context state (queue-confined in production)

    private final class Leg {
        let key: String
        let deviceUID: String
        let tapID: AudioObjectID
        let tapUID: String
        var pids: [pid_t]
        var gain: Float
        let slot: Int
        var rampingOut = false
        var cancelRetire: (() -> Void)?
        var cancelGrace: (() -> Void)?

        init(key: String, deviceUID: String, tapID: AudioObjectID, tapUID: String,
             pids: [pid_t], gain: Float, slot: Int) {
            self.key = key
            self.deviceUID = deviceUID
            self.tapID = tapID
            self.tapUID = tapUID
            self.pids = pids
            self.gain = gain
            self.slot = slot
        }
    }

    private final class Aggregate {
        let deviceUID: String
        let id: AudioObjectID
        let procID: AudioDeviceIOProcID
        let render: TapRenderState
        /// Tap-list order; stream indices follow it.
        var legs: [Leg] = []
        /// Round-robin start for slot assignment, so a just-freed slot is
        /// not immediately reused: a live tap-list edit's topology effect
        /// lags the call (measured ≤1 s), and a straggling callback still
        /// mapping the old layout may write the departed leg's ramp state
        /// into a reused slot. Rotation keeps a freed slot cold for seven
        /// further assignments, far beyond the lag.
        var slotCursor = 0

        init(deviceUID: String, id: AudioObjectID, procID: AudioDeviceIOProcID,
             render: TapRenderState) {
            self.deviceUID = deviceUID
            self.id = id
            self.procID = procID
            self.render = render
        }
    }

    private enum Permission { case unknown, granted, denied }

    private var aggregates: [String: Aggregate] = [:]
    /// The active leg per owner. A leg mid-retirement (device move, ramp-out)
    /// leaves this map and lives only in its aggregate's `legs` until removed.
    private var activeLegs: [String: Leg] = [:]
    private var desires: [TapDesire] = []
    private var tapsEnabled = false
    private var permission: Permission = .unknown
    private var published: [String: TapRowState] = [:]

    init(hal: TapHAL? = nil,
         queue: DispatchQueue? = DispatchQueue(label: "com.techie.PopNotch.tapengine"),
         rampDelay: TimeInterval = 0.12,
         graceDelay: TimeInterval = 3.0,
         schedule: ((TimeInterval, @escaping () -> Void) -> () -> Void)? = nil,
         notify: ((@escaping () -> Void) -> Void)? = nil) {
        self.hal = hal ?? CoreAudioTapHAL()
        self.queue = queue
        self.rampDelay = rampDelay
        self.graceDelay = graceDelay
        if let schedule {
            self.schedule = schedule
        } else if let queue {
            self.schedule = { delay, block in
                let item = DispatchWorkItem(block: block)
                queue.asyncAfter(deadline: .now() + delay, execute: item)
                return { item.cancel() }
            }
        } else {
            self.schedule = { _, block in block(); return {} }
        }
        self.notify = notify ?? { block in DispatchQueue.main.async(execute: block) }

        self.hal.onServiceRestarted = { [weak self] in
            self?.onQueue { self?.handleServiceRestarted() }
        }
        self.hal.onDeviceFormatChanged = { [weak self] uid in
            self?.onQueue { self?.handleFormatChanged(uid) }
        }
        if queue != nil {
            // One reconcile on wake: rebuild whatever died or moved while
            // asleep. willSleep needs nothing — a tap is the playing app's
            // audio path and the HAL quiesces IO itself.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Self.logger.notice("Woke; reconciling taps")
                self?.onQueue { self?.reconcile() }
            }
        }
    }

    /// Held so the observation is removable; AppDelegate owns the one
    /// engine for the process lifetime, but the token must not be dropped.
    private var wakeObserver: NSObjectProtocol?

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func onQueue(_ block: @escaping () -> Void) {
        if let queue { queue.async(execute: block) } else { block() }
    }

    // MARK: - API (any thread; work hops to the engine queue)

    func apply(desires: [TapDesire]) {
        onQueue {
            self.desires = desires
            self.reconcile()
        }
    }

    /// Decision 3: the audio-recording prompt belongs to the moment the user
    /// turns taps on, so the Settings toggle passes `probing: true` and runs
    /// the probe start right here. Launch restore passes `probing: false` —
    /// launch must never prompt; on a granted machine the first engage
    /// start just succeeds, on a revoked one it fails into the inert rows.
    func setTapsEnabled(_ on: Bool, probing: Bool) {
        onQueue {
            guard on != self.tapsEnabled else { return }
            self.tapsEnabled = on
            Self.logger.notice("Taps \(on ? "enabled" : "disabled", privacy: .public)")
            if on && probing && self.permission != .granted {
                self.probe()
            }
            if on && !probing && self.permission == .denied {
                // A fresh session gets a fresh chance; the last denial may
                // have been revoked-and-regranted since.
                self.permission = .unknown
            }
            self.reconcile()
        }
    }

    /// Synchronous full teardown for `applicationWillTerminate`. No ramp: a
    /// clean destroy restores audio within 0.5 s (measured), and quit must
    /// not wait on the engine — bounded, because the queue may be sitting
    /// inside a prompt-blocked `AudioDeviceStart` (measured 17 s, unbounded
    /// until answered). A timed-out quit is the SIGKILL path, which fails
    /// open by `.mutedWhenTapped` (measured, 0.2 s).
    func shutdownSync() {
        let work = {
            self.tapsEnabled = false
            self.desires = []
            for aggregate in self.aggregates.values { self.teardown(aggregate) }
            self.aggregates = [:]
            self.activeLegs = [:]
            Self.logger.notice("Engine shut down")
        }
        guard let queue else { work(); return }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            work()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            Self.logger.error("Engine shutdown timed out (queue blocked, likely on the permission prompt); quitting anyway — taps fail open")
        }
    }

    // MARK: - Reconciling

    /// Re-entrancy guard: executing an op can change the inputs (a failed
    /// start marks the permission denied) and ask for another pass. The
    /// nested request is queued and the loop re-plans, so what gets
    /// published is never a plan the ops themselves invalidated.
    private var reconcileInProgress = false
    private var reconcileQueued = false
    /// Keys whose engage failed this pass without changing any planner
    /// input (process vanished, tap creation refused). Their published
    /// state is downgraded rather than re-planned: re-planning would emit
    /// the same failing op forever.
    private var engageFailures: Set<String> = []

    private func reconcile() {
        guard !reconcileInProgress else {
            reconcileQueued = true
            return
        }
        reconcileInProgress = true
        defer { reconcileInProgress = false }
        repeat {
            reconcileQueued = false
            engageFailures = []
            let legFacts = activeLegs.values.map {
                TapLegFacts(key: $0.key, deviceUID: $0.deviceUID, pids: $0.pids, gain: $0.gain)
            }
            // One lookup per distinct device per pass: `device(forUID:)`
            // enumerates every Core Audio device and reads a UID off each,
            // while a live slider drag reconciles at pointer rate.
            var deviceCache: [String: TapHALDevice?] = [:]
            let plan = TapReconciler.plan(
                desires: desires,
                legs: legFacts,
                tapsEnabled: tapsEnabled,
                permissionDenied: permission == .denied,
                legsOnDevice: { uid in self.aggregates[uid]?.legs.count ?? 0 },
                device: { uid in
                    if let cached = deviceCache[uid] { return cached }
                    let device = self.hal.device(forUID: uid)
                    deviceCache[uid] = device
                    return device
                })
            for op in plan.ops { execute(op) }
            guard !reconcileQueued else { continue }
            // A pause with an unchanged gain plans no op, so nothing else
            // cancels a stale grace timer when playback resumes; without
            // this, a second pause soon after would inherit the first
            // pause's nearly-expired timer.
            let playingKeys = Set(desires.filter(\.isPlaying).map(\.key))
            for (key, leg) in activeLegs where leg.cancelGrace != nil && playingKeys.contains(key) {
                leg.cancelGrace?()
                leg.cancelGrace = nil
            }
            var states = plan.states
            for key in engageFailures where states[key] == plan.states[key] {
                states[key] = .notTapped
            }
            hal.watchDeviceFormats(uids: Set(aggregates.keys))
            publish(states)
        } while reconcileQueued
    }

    private func execute(_ op: TapPlanOp) {
        switch op {
        case .engage(let key, let deviceUID, let pids, let gain):
            engage(key: key, deviceUID: deviceUID, pids: pids, gain: gain)
        case .setGain(let key, let gain):
            guard let leg = activeLegs[key],
                  let aggregate = aggregates[leg.deviceUID] else { return }
            leg.cancelGrace?()
            leg.cancelGrace = nil
            leg.gain = gain
            aggregate.render.setTarget(gain, slot: leg.slot)
            Self.logger.notice("Gain \(key, privacy: .public) -> \(gain, privacy: .public)")
        case .disengage(let key, let afterGrace):
            guard let leg = activeLegs[key], !leg.rampingOut else { return }
            if afterGrace {
                guard leg.cancelGrace == nil else { return }
                Self.logger.notice("Grace started for \(key, privacy: .public)")
                leg.cancelGrace = schedule(graceDelay) { [weak self] in
                    self?.graceExpired(key: key)
                }
            } else {
                beginRampOut(leg)
            }
        case .rebuild(let key, let deviceUID, let pids, let gain):
            // A helper restarted under a new pid. The old process is usually
            // dead (its stream silent, measured), so no ramp: remove and
            // re-engage in one queue turn.
            Self.logger.notice("Rebuilding leg \(key, privacy: .public) for new pids")
            if let leg = activeLegs.removeValue(forKey: key) {
                leg.rampingOut = true  // an immediate retirement, no ramp
                remove(leg)
            }
            engage(key: key, deviceUID: deviceUID, pids: pids, gain: gain)
        }
    }

    private func graceExpired(key: String) {
        guard let leg = activeLegs[key] else { return }
        leg.cancelGrace = nil
        // Re-check: a resume between scheduling and firing keeps the leg.
        let stillStopped = !(desires.first { $0.key == key }?.isPlaying ?? false)
        guard stillStopped else { return }
        Self.logger.notice("Grace expired for \(key, privacy: .public)")
        beginRampOut(leg)
    }

    // MARK: - Legs

    private func engage(key: String, deviceUID: String, pids: [pid_t], gain: Float) {
        guard permission != .denied, tapsEnabled else { return }
        // A leg mid-ramp-out on the same device (a slider wiggle through
        // 100, or a resume racing an expired grace) is revived rather than
        // doubled: a second tap on the same pids would render the app at
        // both legs' gains summed for the ramp window.
        if let aggregate = aggregates[deviceUID],
           let retiring = aggregate.legs.first(where: { $0.key == key && $0.rampingOut }),
           Set(retiring.pids) == Set(pids) {
            retiring.cancelRetire?()
            retiring.cancelRetire = nil
            retiring.rampingOut = false
            retiring.gain = gain
            aggregate.render.setTarget(gain, slot: retiring.slot)
            activeLegs[key] = retiring
            Self.logger.notice("Revived \(key, privacy: .public) mid-rampout at gain \(gain, privacy: .public)")
            return
        }
        // A leg already active for this key at engage time is a device move:
        // it retires (make-before-break) while the new leg takes over.
        if let old = activeLegs.removeValue(forKey: key) { beginRampOut(old) }

        let objects = pids.compactMap { hal.processObject(forPID: $0) }
        guard !objects.isEmpty else {
            Self.logger.notice("No process objects for \(key, privacy: .public); not engaging")
            engageFailures.insert(key)
            return
        }
        guard let (tapID, tapUID) = hal.makeTap(processObjects: objects) else {
            engageFailures.insert(key)
            return
        }

        if let aggregate = aggregates[deviceUID] {
            guard let slot = freeSlot(in: aggregate) else {
                Self.logger.error("No free slot on \(deviceUID, privacy: .public)")
                hal.destroyTap(tapID)
                engageFailures.insert(key)
                return
            }
            let leg = Leg(key: key, deviceUID: deviceUID, tapID: tapID, tapUID: tapUID,
                          pids: pids, gain: gain, slot: slot)
            aggregate.render.prepareSlot(slot, targetGain: gain)
            let newLegs = aggregate.legs + [leg]
            // Mapping for the grown topology goes in before the edit that
            // makes it real; the IOProc keys rows by buffer count.
            aggregate.render.setMapping(bufferCount: newLegs.count,
                                        slots: newLegs.map { Int32($0.slot) })
            guard hal.setTapList(newLegs.map(\.tapUID), onAggregate: aggregate.id) else {
                hal.destroyTap(tapID)
                engageFailures.insert(key)
                return
            }
            aggregate.legs = newLegs
            activeLegs[key] = leg
            Self.logger.notice("Engaged \(key, privacy: .public) gain \(gain, privacy: .public) on \(deviceUID, privacy: .public) (slot \(slot, privacy: .public), \(newLegs.count, privacy: .public) legs)")
            return
        }

        // First leg on this device: build the aggregate around it.
        guard let device = hal.device(forUID: deviceUID) else {
            hal.destroyTap(tapID)
            engageFailures.insert(key)
            return
        }
        let render = TapRenderState(sampleRate: device.sampleRate)
        let leg = Leg(key: key, deviceUID: deviceUID, tapID: tapID, tapUID: tapUID,
                      pids: pids, gain: gain, slot: 0)
        render.prepareSlot(0, targetGain: gain)
        render.setMapping(bufferCount: 1, slots: [0])
        guard let aggID = hal.makeAggregate(outputDeviceUID: deviceUID, tapUIDs: [tapUID]) else {
            hal.destroyTap(tapID)
            engageFailures.insert(key)
            return
        }
        guard let procID = hal.installIOProc(onAggregate: aggID, render: render) else {
            hal.destroyAggregate(aggID)
            hal.destroyTap(tapID)
            engageFailures.insert(key)
            return
        }
        let status = hal.start(aggID, proc: procID)
        guard status == noErr else {
            // Authorization surfaces exactly here (no preflight API exists).
            Self.logger.error("Start failed on \(deviceUID, privacy: .public) (\(status, privacy: .public)); treating capture permission as denied")
            hal.destroyIOProc(procID, onAggregate: aggID)
            hal.destroyAggregate(aggID)
            hal.destroyTap(tapID)
            permission = .denied
            reconcile()
            return
        }
        let aggregate = Aggregate(deviceUID: deviceUID, id: aggID, procID: procID, render: render)
        aggregate.legs = [leg]
        aggregates[deviceUID] = aggregate
        activeLegs[key] = leg
        Self.logger.notice("Engaged \(key, privacy: .public) gain \(gain, privacy: .public) on new aggregate for \(deviceUID, privacy: .public)")
    }

    /// Disengage step one: ramp to unity so the handover is level-matched
    /// (disengage measured clean), then remove after the ramp.
    private func beginRampOut(_ leg: Leg) {
        guard !leg.rampingOut else { return }
        leg.rampingOut = true
        leg.cancelGrace?()
        leg.cancelGrace = nil
        activeLegs.removeValue(forKey: leg.key)
        aggregates[leg.deviceUID]?.render.setTarget(1, slot: leg.slot)
        Self.logger.notice("Ramping out \(leg.key, privacy: .public)")
        leg.cancelRetire = schedule(rampDelay) { [weak self] in
            self?.remove(leg)
        }
    }

    /// Disengage step two: edit the leg out of the live tap list (the
    /// unmute — mute follows membership, measured), destroy its tap, and
    /// fold the aggregate when it was the last one.
    private func remove(_ leg: Leg) {
        // A stale retire can fire after a revival cancelled it (cancelling
        // a work item already dequeued does not stop it): a leg that is no
        // longer ramping out is active again and must stay.
        guard leg.rampingOut else { return }
        leg.cancelRetire = nil
        leg.cancelGrace?()
        guard let aggregate = aggregates[leg.deviceUID],
              aggregate.legs.contains(where: { $0 === leg }) else {
            hal.destroyTap(leg.tapID)
            return
        }
        let remaining = aggregate.legs.filter { $0 !== leg }
        guard !remaining.isEmpty else {
            aggregates.removeValue(forKey: leg.deviceUID)
            teardown(aggregate)
            hal.watchDeviceFormats(uids: Set(aggregates.keys))
            Self.logger.notice("Last leg left; aggregate for \(leg.deviceUID, privacy: .public) torn down")
            return
        }
        // Survivor stream indices shift down (measured); their new mapping
        // is published before the edit, keyed by the shrunken buffer count.
        aggregate.render.setMapping(bufferCount: remaining.count,
                                    slots: remaining.map { Int32($0.slot) })
        if !hal.setTapList(remaining.map(\.tapUID), onAggregate: aggregate.id) {
            Self.logger.error("Tap-list removal failed for \(leg.key, privacy: .public); rebuilding aggregate")
            aggregates.removeValue(forKey: leg.deviceUID)
            teardown(aggregate)
            reconcile()
            return
        }
        aggregate.legs = remaining
        hal.destroyTap(leg.tapID)
        Self.logger.notice("Removed \(leg.key, privacy: .public); \(remaining.count, privacy: .public) legs remain on \(leg.deviceUID, privacy: .public)")
    }

    private func freeSlot(in aggregate: Aggregate) -> Int? {
        let used = Set(aggregate.legs.map(\.slot))
        for offset in 0..<TapRenderState.maxLegs {
            let slot = (aggregate.slotCursor + offset) % TapRenderState.maxLegs
            if !used.contains(slot) {
                aggregate.slotCursor = (slot + 1) % TapRenderState.maxLegs
                return slot
            }
        }
        return nil
    }

    /// Stop → destroy IOProc → destroy aggregate → destroy taps: the spike's
    /// reverse-of-creation order.
    private func teardown(_ aggregate: Aggregate) {
        for leg in aggregate.legs {
            // Cancel AND clear: the closures retain their work items, whose
            // blocks retain the leg — left set, a mid-ramp leg would leak.
            leg.cancelRetire?()
            leg.cancelRetire = nil
            leg.cancelGrace?()
            leg.cancelGrace = nil
            if activeLegs[leg.key] === leg { activeLegs.removeValue(forKey: leg.key) }
        }
        hal.stop(aggregate.id, proc: aggregate.procID)
        hal.destroyIOProc(aggregate.procID, onAggregate: aggregate.id)
        hal.destroyAggregate(aggregate.id)
        for leg in aggregate.legs { hal.destroyTap(leg.tapID) }
        aggregate.legs = []
    }

    // MARK: - Permission probe

    /// One deliberate start at toggle-on, so the prompt happens there and
    /// nowhere else (decision 3). An unmuted global tap: it changes nothing
    /// audible and is destroyed straight after.
    private func probe() {
        guard let (tapID, tapUID) = hal.makeProbeTap() else {
            permission = .denied
            Self.logger.error("Probe tap creation failed; capture unavailable")
            return
        }
        guard let aggID = hal.makeAggregate(outputDeviceUID: nil, tapUIDs: [tapUID]) else {
            hal.destroyTap(tapID)
            permission = .denied
            return
        }
        let render = TapRenderState(sampleRate: 48000)
        guard let procID = hal.installIOProc(onAggregate: aggID, render: render) else {
            hal.destroyAggregate(aggID)
            hal.destroyTap(tapID)
            permission = .denied
            return
        }
        Self.logger.notice("Capture probe starting (may block on the permission prompt)")
        let status = hal.start(aggID, proc: procID)
        hal.stop(aggID, proc: procID)
        hal.destroyIOProc(procID, onAggregate: aggID)
        hal.destroyAggregate(aggID)
        hal.destroyTap(tapID)
        permission = status == noErr ? .granted : .denied
        Self.logger.notice("Capture probe -> \(status == noErr ? "granted" : "denied (\(status))", privacy: .public)")
    }

    // MARK: - External invalidation

    /// Every held ID is stale after a coreaudiod restart; drop references
    /// without destroy calls and rebuild from desires. Never routed to the
    /// permission-denied state — the grant did not change.
    private func handleServiceRestarted() {
        for aggregate in aggregates.values {
            for leg in aggregate.legs {
                leg.cancelRetire?()
                leg.cancelRetire = nil
                leg.cancelGrace?()
                leg.cancelGrace = nil
            }
        }
        // The IOProc blocks and their render states are knowingly dropped
        // unreleased: destroying against IDs the restarted daemon has
        // invalidated is riskier than a few KB per restart. Recorded.
        aggregates = [:]
        activeLegs = [:]
        reconcile()
    }

    private func handleFormatChanged(_ uid: String) {
        guard let aggregate = aggregates.removeValue(forKey: uid) else { return }
        Self.logger.notice("Device format changed on \(uid, privacy: .public); rebuilding")
        teardown(aggregate)
        reconcile()
    }

    // MARK: - Publishing

    private func publish(_ states: [String: TapRowState]) {
        guard states != published else { return }
        published = states
        guard let onStatesChange else { return }
        notify { onStatesChange(states) }
    }
}
