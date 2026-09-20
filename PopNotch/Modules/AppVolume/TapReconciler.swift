import CoreAudio
import Foundation

/// What the mixer wants for one owner, as the service reports it.
struct TapDesire: Equatable {
    var key: String
    /// The live slider position, 0...100. 100 means untouched.
    var position: Int
    var isPlaying: Bool
    var pids: [pid_t]
    /// UIDs of the output devices the owner's processes are using.
    var deviceUIDs: [String]
}

/// One live leg, as the engine holds it.
struct TapLegFacts: Equatable {
    var key: String
    var deviceUID: String
    var pids: [pid_t]
    var gain: Float
}

/// The page's per-row engine state.
///
/// Deliberately carries no position: the row draws its knob from the live
/// slider position, and a position in here would change on every pointer
/// move, republishing every row through the main actor and re-measuring
/// the panel at pointer rate. This answers only "can this row be adjusted,
/// and is a tap live?".
enum TapRowState: Equatable {
    /// No tap exists and none is called for.
    case notTapped
    /// A tap is live for this owner.
    case engaged
    /// A tap is called for but cannot exist; the row explains itself.
    case inert(reason: String)
}

/// One step of work for the engine to execute, in order.
enum TapPlanOp: Equatable {
    case engage(key: String, deviceUID: String, pids: [pid_t], gain: Float)
    case setGain(key: String, gain: Float)
    /// Ramp to unity, then remove. `afterGrace` marks the stopped-playing
    /// cause, which the engine defers by its grace period.
    case disengage(key: String, afterGrace: Bool)
    /// The owner's pid set changed (a helper restarted): tear the leg down
    /// and re-engage on the new pids. Measured cheapest as a leg rebuild via
    /// the live tap-list edit (M1).
    case rebuild(key: String, deviceUID: String, pids: [pid_t], gain: Float)
}

/// Pure planning: desired rows plus current legs in, ops plus row states
/// out. No Core Audio, no clocks, no queues — tested with fixtures.
enum TapReconciler {

    /// Linear for v1. Positions, not gains, are what settings store, so this
    /// taper can be retuned without a migration.
    nonisolated static func gain(atPosition position: Int) -> Float {
        Float(min(max(position, 0), 100)) / 100
    }

    nonisolated static func plan(desires: [TapDesire],
                                 legs: [TapLegFacts],
                                 tapsEnabled: Bool,
                                 permissionDenied: Bool,
                                 legsOnDevice: (String) -> Int,
                                 device: (String) -> TapHALDevice?)
        -> (ops: [TapPlanOp], states: [String: TapRowState]) {

        var ops: [TapPlanOp] = []
        var states: [String: TapRowState] = [:]
        let legsByKey = Dictionary(uniqueKeysWithValues: legs.map { ($0.key, $0) })
        var keptKeys = Set<String>()

        for desire in desires {
            let leg = legsByKey[desire.key]

            func drop(_ state: TapRowState, afterGrace: Bool = false) {
                states[desire.key] = state
                if leg != nil { ops.append(.disengage(key: desire.key, afterGrace: afterGrace)) }
            }

            guard tapsEnabled else { drop(.notTapped); continue }
            guard !permissionDenied else { drop(.inert(reason: "permission needed")); continue }
            guard desire.position < 100 else { drop(.notTapped); continue }
            guard desire.isPlaying || leg != nil else {
                // Not playing and not tapped: nothing to build. The position
                // is remembered and applies at the next play (restore path).
                states[desire.key] = .notTapped
                continue
            }
            guard desire.isPlaying else { drop(.notTapped, afterGrace: true); continue }
            guard desire.deviceUIDs.count == 1, let uid = desire.deviceUIDs.first else {
                drop(.inert(reason: desire.deviceUIDs.isEmpty
                    ? "no output device" : "on several outputs"))
                continue
            }
            guard let dev = device(uid) else { drop(.notTapped); continue }
            guard !dev.isAirPlay else { drop(.inert(reason: "AirPlay output")); continue }
            // A headset's microphone would ride into the aggregate as extra
            // input streams, corrupting the gain mapping and echoing the mic
            // (see `TapHALDevice.hasInputStreams`). Excluded until measured.
            guard !dev.hasInputStreams else {
                drop(.inert(reason: "output has a microphone"))
                continue
            }
            guard dev.isStereoOut else { drop(.inert(reason: "not a stereo output")); continue }

            let target = gain(atPosition: desire.position)
            if let leg {
                keptKeys.insert(desire.key)
                if leg.deviceUID != uid {
                    // The app moved devices. One engage op: the engine's
                    // engage retires the existing leg itself, after the new
                    // one is up — make-before-break, measured safe in M2
                    // (the mute holds until the last tap goes). A separate
                    // disengage here would land on the NEW leg, since ops
                    // are keyed by owner and the engage replaces the leg.
                    ops.append(.engage(key: desire.key, deviceUID: uid,
                                       pids: desire.pids, gain: target))
                } else if Set(leg.pids) != Set(desire.pids) {
                    ops.append(.rebuild(key: desire.key, deviceUID: uid,
                                        pids: desire.pids, gain: target))
                } else if leg.gain != target {
                    ops.append(.setGain(key: desire.key, gain: target))
                }
                states[desire.key] = .engaged
            } else if legsOnDevice(uid) >= TapRenderState.maxLegs {
                states[desire.key] = .inert(reason: "too many adjusted apps")
            } else {
                ops.append(.engage(key: desire.key, deviceUID: uid,
                                   pids: desire.pids, gain: target))
                states[desire.key] = .engaged
            }
        }

        // Legs whose owner vanished from the rows entirely: the app is gone.
        let desired = Set(desires.map(\.key))
        for leg in legs where !desired.contains(leg.key) && !keptKeys.contains(leg.key) {
            ops.append(.disengage(key: leg.key, afterGrace: false))
        }
        return (ops, states)
    }
}
