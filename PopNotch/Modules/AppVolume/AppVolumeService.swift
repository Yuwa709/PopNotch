import CoreAudio
import Foundation
import Observation
import os

/// Per-app volume's engine service, owned by AppDelegate rather than being a
/// NotchModule (docs/FUTURE-audio-mixer.md, *v1 plan*, decision 4).
///
/// **Phase 3: read-only.** It watches which processes are playing, resolves
/// each to the app that owns it, groups them into rows, and logs the rows.
/// No tap, no audio device, no UI. The tap engine is Phase 5; the page that
/// shows these rows is Phase 4.
@MainActor
@Observable
final class AppVolumeService {

    /// The log the rows are verified from. Injected so tests can pass a
    /// disabled one: the test host is a copy of PopNotch, writing to the
    /// same subsystem and category, and its fixture rows were once mistaken
    /// for real ones (2026-09-18).
    nonisolated static let defaultLogger = Logger(subsystem: "com.techie.PopNotch", category: "AppVolume")

    /// What is playing now, one row per owning app, sorted by name.
    private(set) var rows: [AudioAppRow] = []
    /// Playing processes that are never listed or tapped: PopNotch itself,
    /// system daemons, system agents. Kept for the logs.
    private(set) var hiddenCount = 0

    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let source: AudioProcessSource
    @ObservationIgnored private let resolve: (AudioProcessSnapshot) -> AudioOwnerResult?
    /// Resolved once per process object: its owner cannot change while it
    /// lives, and gathering facts costs a signature lookup.
    @ObservationIgnored private var resolved: [AudioObjectID: AudioOwnerResult] = [:]
    @ObservationIgnored private var lastLogged: String?

    /// `resolve` is injectable so tests never touch real processes. The
    /// default gathers public facts and runs the resolver chain; nil means
    /// the process vanished before it could be inspected.
    init(source: AudioProcessSource? = nil,
         resolve: ((AudioProcessSnapshot) -> AudioOwnerResult?)? = nil,
         logger: Logger = AppVolumeService.defaultLogger) {
        self.source = source ?? CoreAudioProcessSource()
        self.logger = logger
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
        rows = []
        hiddenCount = 0
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
