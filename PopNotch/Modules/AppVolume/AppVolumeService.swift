import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// One row on the mixer page. Distinct from `AudioAppRow`, which is the
/// playing-now grouping the logs are built from: a mixer row also covers an
/// app that played earlier this session and is still running, and carries
/// the states the page draws — playing or not, and greyed-with-reason for
/// the never-tap set.
struct MixerRow: Equatable {
    var owner: AudioOwner
    /// The live pids currently attributed to this owner; empty once its
    /// audio processes have gone away (a session row kept by the app-running
    /// check).
    var pids: [pid_t]
    var isPlaying: Bool
    /// Non-nil for apps in `NeverTapSet`: the short reason the row shows.
    var neverTapReason: String?
}

/// Per-app volume's engine service, owned by AppDelegate rather than being a
/// NotchModule (docs/FUTURE-audio-mixer.md, *v1 plan*, decision 4).
/// `AppVolumeModule` is only the Settings toggle and the door; it starts and
/// stops the watching here.
///
/// **Phase 4: read-only.** It watches which processes are playing, resolves
/// each to the app that owns it, and publishes the mixer page's rows: apps
/// playing now, plus apps that played this session and are still running
/// (so a volume can be set before the next join sound, not scrambled for
/// during it). No tap, no audio device. The tap engine is Phase 5.
@MainActor
@Observable
final class AppVolumeService {

    /// The log the rows are verified from. Injected so tests can pass a
    /// disabled one: the test host is a copy of PopNotch, writing to the
    /// same subsystem and category, and its fixture rows were once mistaken
    /// for real ones (2026-09-18).
    nonisolated static let defaultLogger = Logger(subsystem: "com.techie.PopNotch", category: "AppVolume")

    /// What is playing now, one row per owning app, sorted by name. The
    /// Phase 3 verification logs are built from this, so its meaning does
    /// not change: playing now, nothing else.
    private(set) var rows: [AudioAppRow] = []
    /// Playing processes that are never listed or tapped: PopNotch itself,
    /// system daemons, system agents. Kept for the logs.
    private(set) var hiddenCount = 0

    /// What the mixer page lists (v1 plan, *Accepted defaults*): apps
    /// playing now, plus apps that played this session and are still
    /// running. Unattributable audio never appears — the resolver hides it
    /// before rows are built.
    private(set) var mixerRows: [MixerRow] = []

    /// Fires after `mixerRows` changes, so the coordinator can re-measure
    /// an open mixer page whose row count just changed. Distinct from
    /// observation: the panel's frame is applied imperatively, not by a
    /// SwiftUI view watching the service.
    @ObservationIgnored var onRowsChange: (() -> Void)?

    /// Spotify's and Music's own volume (decision 3: AppleScript, never a
    /// tap). Rows whose owner it handles get a working slider now, shared
    /// with the player screen's; every other row stays inert until the tap
    /// engine (Phase 5). Set by AppDelegate once the media module exists;
    /// weak because the coordinator's arbiter already owns that module.
    @ObservationIgnored weak var playerVolumes: ScriptedPlayerVolumes?

    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let source: AudioProcessSource
    @ObservationIgnored private let resolve: (AudioProcessSnapshot) -> AudioOwnerResult?
    /// Whether an app with this bundle ID is still running — the check that
    /// keeps a session row alive after its audio processes exit (Chrome's
    /// audio helper outlives playback by a minute, then quits while Chrome
    /// stays). Injected so tests never depend on what is really running.
    @ObservationIgnored private let isAppRunning: (String) -> Bool
    /// Resolved once per process object: its owner cannot change while it
    /// lives, and gathering facts costs a signature lookup.
    @ObservationIgnored private var resolved: [AudioObjectID: AudioOwnerResult] = [:]
    /// Owners seen playing since watching started, keyed by owner key.
    /// Pruned when the owner is neither connected to Core Audio nor (for
    /// apps) still running.
    @ObservationIgnored private var sessionOwners: [String: AudioOwner] = [:]
    @ObservationIgnored private var lastLogged: String?

    /// `resolve` is injectable so tests never touch real processes. The
    /// default gathers public facts and runs the resolver chain; nil means
    /// the process vanished before it could be inspected.
    init(source: AudioProcessSource? = nil,
         resolve: ((AudioProcessSnapshot) -> AudioOwnerResult?)? = nil,
         isAppRunning: ((String) -> Bool)? = nil,
         logger: Logger = AppVolumeService.defaultLogger) {
        self.source = source ?? CoreAudioProcessSource()
        self.logger = logger
        self.isAppRunning = isAppRunning ?? { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
        let selfPID = getpid()
        self.resolve = resolve ?? { snapshot in
            ProcessFactsGatherer.facts(pid: snapshot.pid, bundleID: snapshot.bundleID)
                .map { AudioOwnerResolver.resolve($0, selfPID: selfPID) }
        }
    }

    func startWatching() {
        source.onChange = { [weak self] processes in self?.update(processes) }
        source.start()
    }

    func stopWatching() {
        source.stop()
        source.onChange = nil
        resolved = [:]
        sessionOwners = [:]
        rows = []
        hiddenCount = 0
        publishMixerRows([])
    }

    /// Re-evaluates the session rows from the current process list, without
    /// waiting for the next audio event. Called when the mixer page opens:
    /// an app that quit since the last event would otherwise still show,
    /// because its quitting only fires a Core Audio notification if it still
    /// held audio process objects.
    func refreshRows() {
        update(source.processes)
    }

    /// The mixer page just opened: re-prune the rows, then read the current
    /// volume of each listed scripted player, since Spotify and Music post
    /// nothing when their own slider or a phone changes it. One Apple Event
    /// per such row (~17ms each, at most two), click-driven, never on a
    /// cadence.
    func pageDidOpen() {
        refreshRows()
        guard let playerVolumes else { return }
        for row in mixerRows where playerVolumes.handlesVolume(for: row.owner.key) {
            playerVolumes.refreshVolume(for: row.owner.key)
        }
    }

    private func update(_ processes: [AudioProcessSnapshot]) {
        let live = Set(processes.map(\.objectID))
        resolved = resolved.filter { live.contains($0.key) }

        var results: [(pid: pid_t, result: AudioOwnerResult)] = []
        for process in processes where process.isRunningOutput {
            if let known = resolved[process.objectID] {
                results.append((process.pid, known))
            } else if let result = resolve(process) {
                resolved[process.objectID] = result
                results.append((process.pid, result))
            }
        }
        let built = AudioRowBuilder.rows(from: results)
        rows = built.rows
        hiddenCount = built.hidden.count
        log(built.rows, hidden: built.hidden)
        publishMixerRows(buildMixerRows(processes: processes, playing: built.rows))
    }

    /// The session bookkeeping behind the mixer page. `resolved` only ever
    /// holds objects that have played (resolution happens on first output),
    /// so "connected" below means "has played and its process object is
    /// still registered with Core Audio" — which covers paused apps, whose
    /// objects persist.
    private func buildMixerRows(processes: [AudioProcessSnapshot],
                                playing: [AudioAppRow]) -> [MixerRow] {
        var liveByKey: [String: (owner: AudioOwner, pids: [pid_t])] = [:]
        for process in processes {
            guard case .shown(let owner)? = resolved[process.objectID] else { continue }
            liveByKey[owner.key, default: (owner, [])].pids.append(process.pid)
        }
        for row in playing {
            sessionOwners[row.owner.key] = row.owner
        }
        // Kept while connected, or — for apps — while the app itself still
        // runs. Web content and unbundled tools have no app to check, so
        // their rows go when their processes do.
        sessionOwners = sessionOwners.filter { key, owner in
            liveByKey[key] != nil || (owner.kind == .app && isAppRunning(key))
        }
        let playingKeys = Set(playing.map(\.owner.key))
        return sessionOwners.values
            .map { owner in
                MixerRow(owner: owner,
                         pids: (liveByKey[owner.key]?.pids ?? []).sorted(),
                         isPlaying: playingKeys.contains(owner.key),
                         neverTapReason: NeverTapSet.reason(for: owner.key))
            }
            .sorted { ($0.owner.name.localizedLowercase, $0.owner.key)
                    < ($1.owner.name.localizedLowercase, $1.owner.key) }
    }

    private func publishMixerRows(_ newRows: [MixerRow]) {
        guard newRows != mixerRows else { return }
        mixerRows = newRows
        onRowsChange?()
    }

    /// At `.notice`, and only when something changed, so the log is a record
    /// of what played and how each process was attributed, not a stream.
    private func log(_ rows: [AudioAppRow], hidden: [(name: String, reason: AudioHiddenReason)]) {
        var lines = rows.map { row in
            "\(row.owner.name) [\(row.owner.key)] \(row.owner.kind.rawValue), via \(row.owner.resolution.rawValue), pids \(row.pids.map(String.init).joined(separator: ","))"
        }
        if !hidden.isEmpty {
            lines.append("hidden: " + hidden.map { "\($0.name) (\($0.reason.rawValue))" }.joined(separator: ", "))
        }
        let summary = lines.joined(separator: "; ")
        guard summary != lastLogged else { return }
        lastLogged = summary
        logger.notice("Audio rows (\(rows.count, privacy: .public)): \(summary.isEmpty ? "none playing" : summary, privacy: .public)")
    }
}
