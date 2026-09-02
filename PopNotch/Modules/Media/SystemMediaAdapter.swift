import Foundation
import os

/// Reads the system-wide now-playing session — whatever app currently owns it.
///
/// Unlike `SpotifyAdapter` and `MusicAdapter`, which each speak one app's
/// scripting dictionary, this source reports the same session Control Center
/// shows: Spotify, Music, a browser playing video, anything that registers
/// with MediaRemote.
///
/// **Why a subprocess and not `MediaRemoteClient`.** MediaRemote's read API is
/// gated to entitled callers, which is why `MediaRemoteClient` sits unused in
/// this folder (see the note in `MediaSource.swift`). The gate applies to the
/// calling binary, so a separate tool that satisfies it can read the session
/// and hand the result over as plain JSON on stdout.
///
/// Lifecycle mirrors `SpotifyAdapter`: push-first, no timers. The tool is
/// launched once by `startObserving()` and streams a line per change for as
/// long as it runs, so this satisfies hard rule 9 without a suspend path —
/// there is nothing polling to suspend. `stopObserving()` terminates it.
///
/// What this source cannot do: `media-control` exposes no queue and no
/// favourite, so `upNext` and `favorite` keep the protocol defaults (nil and
/// `.unsupported`). It is not an oversight and must not be faked by peeking
/// at another player.
@MainActor
final class SystemMediaAdapter: MediaSource {

    private nonisolated static let logger = Logger(subsystem: "com.techie.PopNotch", category: "SystemMedia")

    // TODO: NOT SHIPPABLE. `/opt/homebrew/bin/media-control` is a Homebrew
    // install — an absolute path into a package manager most users do not
    // have, living outside the app bundle, that Homebrew can upgrade or remove
    // out from under us. It is here so the read path could be built and logged
    // against real data.
    //
    // Vendoring it is not "ship a script". Measured against 0.7.6, what runs
    // is four separate things:
    //   • bin/media-control — itself a Perl script, not a binary
    //   • lib/media-control/mediaremote-adapter.pl — what it actually execs
    //   • Frameworks/MediaRemoteAdapter.framework — an arm64 Mach-O dylib
    //   • lib/media-control/MediaRemoteAdapterTestClient — an arm64 Mach-O
    //     executable
    // plus a dependency on /usr/bin/perl, which Apple has deprecated: the
    // bundled scripting runtimes are documented as slated for removal, so
    // anything vendored on top of them inherits that clock.
    //
    // The real work is the two Mach-O objects — embedding them means signing
    // them with the app's identity under Hardened Runtime and carrying them
    // through notarization, and every added binary is a notarization risk
    // (CLAUDE.md, distribution). That is a decision to record in
    // PROJECT-CONTEXT.md, not a chore to do inline. Whatever replaces this
    // must be resolved via `Bundle`, never an absolute path, and must land
    // before this source is registered in AppDelegate.
    static let toolPath = "/opt/homebrew/bin/media-control"

    /// Whether this source is wired up at all.
    ///
    /// **False since 1.0.3.** The source is unregistered because `toolPath`
    /// is not in the app bundle (see the TODO above), so it worked only on a
    /// machine that happened to have the Homebrew formula installed.
    ///
    /// This is the single switch, not a comment: `AppDelegate` consults it
    /// when building the sources array, and the Settings tab consults it
    /// when deciding whether to offer "Prefer music over video" — a
    /// preference that means nothing while no source reads it. Flipping this
    /// to `true` restores the source and its setting together, which is why
    /// it exists rather than the two places each carrying their own guard
    /// and drifting apart.
    ///
    /// The stored preference and its schema field are deliberately untouched
    /// while this is false: hiding a control must not discard what the user
    /// already chose.
    static let isRegistered = false

    let sourceID = "system"
    var onUpdate: ((NowPlaying?) -> Void)?

    /// Always false. This source sends no Apple Events, so the Automation
    /// permission that gates the other two adapters does not apply. A missing
    /// or unlaunchable tool is a *capability* problem, not a permission one,
    /// and must not raise the in-notch "allow Automation" banner.
    private(set) var permissionDenied = false

    private var process: Process?
    private var stdoutPipe: Pipe?

    /// The merged payload, retained across lines. A `diff` line carries only
    /// the fields that changed, so this is merged into rather than replaced —
    /// replacing it is what would drop artist and artwork on a position-only
    /// update.
    private var state = SystemMediaPayload()

    /// When `elapsed` was last actually measured. Kept separately because
    /// `NowPlaying.capturedAt` defaults to construction time, and this snapshot
    /// is rebuilt on every line: stamping "now" onto an unchanged `elapsed`
    /// would drag the projected playhead backwards on each metadata-only diff.
    private var elapsedAnchor = Date()

    /// Decoded artwork, keyed by the base64 it came from, so a position update
    /// does not re-decode 40-odd KB. Carrying the same `String` instance
    /// forward through a merge makes the common comparison a pointer check.
    private var artworkCache: (encoded: String, data: Data)?

    /// Bundle ids that already have a dedicated adapter. Reading their
    /// sessions here would put the same track on two sources and leave
    /// `MediaModule` arbitrating between an adapter that can seek, favourite
    /// and read a queue and one that cannot. Referenced, never re-spelled:
    /// a literal here would silently stop matching if either constant moved.
    private static let dedicatedBundleIDs: Set<String> = [
        SpotifyAdapter.bundleID, MusicAdapter.bundleID
    ]

    /// The last artwork decoded, and the track it belonged to.
    ///
    /// A full (non-diff) line for a track in progress can arrive with no
    /// artwork at all, with the diff carrying it landing ~13ms later —
    /// measured on hardware 2026-09-01. Rendered as it arrives that is album
    /// art blinking off and back on at every track change, so the previous
    /// image stands in while the identifier is unchanged.
    private var retainedArtwork: (identifier: String, data: Data)?

    /// Pending "nothing is playing", held briefly. One app releases the
    /// session before the next claims it — measured at 2ms between
    /// `nothing` and the replacement — and publishing that gap empties the
    /// notch for a frame. A real payload cancels this before it fires.
    private var emptyTask: Task<Void, Never>?
    private static let emptyDebounceMS = 150

    /// Prefer a session that has an album over one that does not. Mirrors
    /// `AppSettings.preferMusicOverVideo`; AppDelegate pushes it in, the same
    /// way the visualiser's enabled flag is applied.
    var prefersMusicOverVideo = true

    /// The last music-tier snapshot and the app it came from, kept so a video
    /// from that same app can be ignored rather than replacing it.
    ///
    /// Released on an empty payload or a change of app — never held open
    /// ended, or a track that stopped long ago would pin the notch.
    private var retainedMusic: (bundleID: String, snapshot: NowPlaying)?

    private var lastSnapshot: NowPlaying?
    /// So the first successful diff merge leaves a durable `.notice` behind
    /// instead of only memory-only `.debug` chatter.
    private let firstDiffGate = OnceGate()
    /// The missing-tool line is logged once per adapter, not once per call:
    /// `startObserving()` and `refresh()` both reach it.
    private var toolMissingLogged = false

    /// There is no single player to ask about. True when the stream is up and
    /// some app owns the session; `MediaModule` uses this for handoff, so it
    /// must mean "this source has something", not "a process exists".
    var isPlayerRunning: Bool {
        process?.isRunning == true && state.bundleIdentifier != nil
    }

    // MARK: - Observing

    func startObserving() {
        guard process == nil else { return }
        guard toolIsPresent else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.toolPath)
        task.arguments = ["stream"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // Line assembly and JSON decoding run on the pipe's own queue; only
        // finished envelopes cross to the main actor. A line carrying artwork
        // is ~45KB, and parsing that on the main thread is exactly the kind of
        // work the performance budget is about.
        let assembler = LineAssembler()
        let malformed = OnceGate()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return } // EOF; terminationHandler follows
            var envelopes: [SystemMediaEnvelope] = []
            for line in assembler.lines(from: chunk) {
                guard let envelope = SystemMediaParsing.decode(line: line) else {
                    // Skipped, never fatal: one unreadable line must not take
                    // the stream down, and a tool that starts emitting garbage
                    // must not fill the log either — hence once per stream.
                    //
                    // `.debug` is deliberate and is the exception to the
                    // house rule, not a violation of it: this is chatter, and
                    // `.debug` is memory-only, so reading it back needs
                    // `log stream --level debug` rather than plain `log show`.
                    if malformed.firstTime() {
                        Self.logger.debug(
                            "Skipping unparseable stdout line (\(line.count) bytes); stream continues"
                        )
                    }
                    continue
                }
                envelopes.append(envelope)
            }
            guard !envelopes.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.ingest(envelopes)
            }
        }

        // Deliberately no restart here. A tool that dies on launch would
        // otherwise be relaunched forever, which is a poll wearing a disguise.
        // `refresh()` is the recovery path.
        task.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleStreamExit(status: status)
            }
        }

        do {
            try task.run()
        } catch {
            Self.logger.error(
                "media-control stream failed to launch: \(error.localizedDescription, privacy: .public)"
            )
            pipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        process = task
        stdoutPipe = pipe
        Self.logger.notice("Observing system now-playing via media-control stream")
    }

    func stopObserving() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            // Cleared first: this is an expected exit and must not be logged
            // as the stream dying.
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdoutPipe = nil
        emptyTask?.cancel()
        emptyTask = nil
        state = SystemMediaPayload()
        artworkCache = nil
        retainedArtwork = nil
        retainedMusic = nil
        lastSnapshot = nil
        Self.logger.notice("System now-playing stream stopped")
    }

    deinit {
        // The observer the other adapters drop is cheap to leak; a child
        // process is not. terminate() is safe to call from any thread.
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
    }

    private var toolIsPresent: Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath) else {
            if !toolMissingLogged {
                toolMissingLogged = true
                Self.logger.notice(
                    "media-control not found at \(Self.toolPath, privacy: .public); system source inert"
                )
            }
            return false
        }
        return true
    }

    private func handleStreamExit(status: Int32) {
        guard process != nil else { return } // already torn down by stopObserving
        Self.logger.error(
            "media-control stream exited (status \(status, privacy: .public)); system source inert until refresh"
        )
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        publish()
    }

    // MARK: - Pull

    /// Restarts a dead stream and re-publishes what is retained.
    ///
    /// Deliberately not a synchronous `media-control get`, which is what the
    /// other two adapters do with their Apple Events: this is called on hover,
    /// and blocking the main actor on a subprocess launch would stutter the
    /// panel it was called to fill. The stream already delivers current state
    /// on connect, so restarting is the pull.
    func refresh() {
        if process == nil { startObserving() }
        publish()
    }

    // MARK: - Ingest

    /// Internal rather than private so the tier and merge behaviour can be
    /// driven directly in tests, the way `LineAssembler` is: everything above
    /// this point is a subprocess and a pipe.
    func ingest(_ envelopes: [SystemMediaEnvelope]) {
        for envelope in envelopes { apply(envelope) }
        publish()
    }

    private func apply(_ envelope: SystemMediaEnvelope) {
        // Only "data" carries session state. A future line type must not be
        // read as an empty payload and clear the current track.
        guard envelope.type == "data" else { return }
        let incoming = envelope.payload ?? SystemMediaPayload()

        // A diff carries only what changed, so it merges over the retained
        // state. A non-diff payload is a complete snapshot and replaces it —
        // including the empty one the stream opens with, which is how "nothing
        // is playing" arrives rather than as a null payload.
        let isDiff = envelope.diff == true

        // Re-anchor only on a fresh position measurement, or when the
        // transport flips without one. A metadata-only diff keeps the old
        // anchor so the projected playhead stays continuous.
        let playingChanged = incoming.playing != nil && incoming.playing != state.playing
        if incoming.elapsedTime != nil || playingChanged || !isDiff {
            elapsedAnchor = Date()
        }

        state = isDiff ? incoming.merged(over: state) : incoming
        if isDiff { logDiff(carried: incoming, merged: state) }
    }

    /// Evidence for the one thing about this source that a finished snapshot
    /// cannot show: that a partial line merged instead of replacing.
    ///
    /// The first is a `.notice` so it survives to disk; the rest are `.debug`,
    /// because a position tick a second is chatter and this adapter is meant
    /// to run for days.
    private func logDiff(carried: SystemMediaPayload, merged: SystemMediaPayload) {
        let fields = carried.presentFieldNames.joined(separator: ",")
        let art = merged.artworkData?.count ?? 0
        let retained = "title=\(merged.title != nil) artist=\(merged.artist != nil) artwork=\(art)ch elapsed=\(merged.elapsedTime ?? -1)"
        if firstDiffGate.firstTime() {
            Self.logger.notice(
                "First diff merged: carried=[\(fields, privacy: .public)] retained \(retained, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "diff carried=[\(fields, privacy: .public)] retained \(retained, privacy: .public)"
            )
        }
    }

    private func publish() {
        // A session owned by a player with its own adapter is not ours to
        // report. Emitting nil rather than skipping matters: if Spotify takes
        // the session while this source holds the notch, saying nothing would
        // leave the old track frozen on screen.
        guard !isDedicatedSession else {
            scheduleEmpty()
            return
        }
        guard let snapshot = SystemMediaParsing.snapshot(
            from: state, artwork: resolvedArtwork(), capturedAt: elapsedAnchor
        ) else {
            // Nothing at all: whatever music this was holding has genuinely
            // stopped, so stop holding it.
            retainedMusic = nil
            scheduleEmpty()
            return
        }

        if let retained = retainedMusic, Self.releasesHold(retained, against: snapshot) {
            retainedMusic = nil
        }

        switch SystemMediaParsing.tier(of: state) {
        case .music:
            if let bundle = snapshot.sourceBundleID {
                retainedMusic = (bundle, snapshot)
            }
        case .video:
            // What survives `releasesHold` is narrow by design: the same app,
            // the same item, still playing. In practice that is a track whose
            // album momentarily goes missing from a payload — a report that
            // would otherwise reclassify what is playing as video and swap the
            // notch out from under it. A genuinely different item is a
            // different session and was already released above.
            if prefersMusicOverVideo, let retained = retainedMusic,
               retained.bundleID == snapshot.sourceBundleID {
                return
            }
        }

        // A real payload arrived, so any pending gap was only a gap.
        emptyTask?.cancel()
        emptyTask = nil

        // NowPlaying's == ignores capturedAt, so this drops the repeats the
        // stream emits without a user-visible change.
        guard snapshot != lastSnapshot else { return }
        logTransition(to: snapshot, from: lastSnapshot)
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    /// Whether a retained music track has stopped being a reason to decline a
    /// video.
    ///
    /// Any one of these means the retained snapshot is no longer the session,
    /// and holding it would pin a track the user is not listening to.
    nonisolated static func releasesHold(
        _ retained: (bundleID: String, snapshot: NowPlaying), against incoming: NowPlaying
    ) -> Bool {
        // A different app owns the session; the retained track is not coming
        // back to it.
        if retained.bundleID != incoming.sourceBundleID { return true }

        // macOS reports one session at a time, so a different item *is* a
        // different session. Whatever was retained is not what is playing, and
        // a browser switching from a track to a video is exactly this case.
        if retained.snapshot.artworkIdentifier != incoming.artworkIdentifier { return true }

        // Suppression is for an *active* track outranking a video, never a
        // paused one. This is also what keeps the scrub bar and the lyrics
        // honest: both project forward from `elapsed` for as long as
        // `isPlaying` is true, so a held paused track would keep advancing and
        // scrolling against audio that stopped — observed on hardware
        // 2026-09-01, together with transport buttons acting on the video.
        if !retained.snapshot.isPlaying { return true }

        return false
    }

    private var isDedicatedSession: Bool {
        guard let bundle = state.bundleIdentifier else { return false }
        return Self.dedicatedBundleIDs.contains(bundle)
    }

    /// Holds the empty state briefly rather than publishing it on arrival.
    /// Already-empty stays empty with no timer, and a pending wait is never
    /// restarted — the debounce measures from the first empty line, not the
    /// last.
    private func scheduleEmpty() {
        guard lastSnapshot != nil, emptyTask == nil else { return }
        emptyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.emptyDebounceMS))
            guard !Task.isCancelled, let self else { return }
            self.emptyTask = nil
            guard self.lastSnapshot != nil else { return }
            self.lastSnapshot = nil
            Self.logger.notice("System now playing: nothing")
            self.onUpdate?(nil)
        }
    }

    /// Artwork for the current state, falling back to what this same track
    /// had a moment ago. Requires a real identifier: with none there is no
    /// evidence the art still belongs to what is playing.
    private func resolvedArtwork() -> Data? {
        if let decoded = decodedArtwork(for: state.artworkData) {
            if let id = state.contentItemIdentifier, !id.isEmpty {
                retainedArtwork = (id, decoded)
            }
            return decoded
        }
        guard let id = state.contentItemIdentifier, !id.isEmpty,
              let retained = retainedArtwork, retained.identifier == id
        else { return nil }
        return retained.data
    }

    private func decodedArtwork(for encoded: String?) -> Data? {
        guard let encoded, !encoded.isEmpty else { return nil }
        if let artworkCache, artworkCache.encoded == encoded { return artworkCache.data }
        // ignoreUnknownCharacters: the payload is machine-generated, but a
        // stray wrap would otherwise turn all artwork into nil silently.
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              !data.isEmpty
        else {
            Self.logger.error("Artwork base64 did not decode (\(encoded.count, privacy: .public) chars)")
            return nil
        }
        artworkCache = (encoded, data)
        return data
    }

    /// Verification lives here, since none of this is visible on screen.
    /// Titles and artists are user content and stay redacted; everything
    /// logged public is either an app identifier or a measurement.
    private func logTransition(to snapshot: NowPlaying, from previous: NowPlaying?) {
        if snapshot.artworkIdentifier != previous?.artworkIdentifier {
            Self.logger.notice(
                """
                System track: source=\(snapshot.sourceBundleID ?? "?", privacy: .public) \
                playing=\(snapshot.isPlaying, privacy: .public) \
                title=\(snapshot.title?.count ?? 0, privacy: .public)ch \
                artist=\(snapshot.artist?.count ?? 0, privacy: .public)ch \
                duration=\(snapshot.duration ?? -1, format: .fixed(precision: 1), privacy: .public)s \
                artwork=\(snapshot.artworkData?.count ?? 0, privacy: .public)B
                """
            )
        } else if snapshot.isPlaying != previous?.isPlaying {
            Self.logger.notice(
                "System transport: playing=\(snapshot.isPlaying, privacy: .public) at \(snapshot.elapsed ?? -1, format: .fixed(precision: 1), privacy: .public)s"
            )
        }
    }

    // MARK: - Commands

    func send(_ command: MediaCommand) {
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "toggle-play-pause"
        case .nextTrack: verb = "next-track"
        case .previousTrack: verb = "previous-track"
        }
        runTool([verb])
    }

    func seek(to seconds: TimeInterval) {
        // Non-localized on purpose: String(format:) with no locale renders a
        // dot, and the tool parses a dot. The AppleScript adapters have the
        // mirror image of this problem on the way in.
        runTool(["seek", String(format: "%.2f", max(0, seconds))])
    }

    /// Fire and forget. Never waits: these run on the main actor in response
    /// to a button press, and the result arrives on the stream anyway.
    private func runTool(_ arguments: [String]) {
        guard toolIsPresent else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.toolPath)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Self.logger.error(
                "media-control \(arguments.first ?? "?", privacy: .public) failed to launch"
            )
        }
    }
}

// MARK: - Line assembly

/// Reassembles newline-delimited JSON from arbitrary chunk boundaries.
///
/// There is no maximum line length: artwork ships as base64 inside the
/// payload, so a single line measured 45,905 bytes against the live tool and a
/// track with larger art will be bigger. The buffer grows until a newline
/// arrives; a chunk may hold a fragment, several whole lines, or both.
///
/// Not `Sendable` and not locked: `FileHandle` serialises `readabilityHandler`
/// invocations for a given handle, and this instance is reachable from nothing
/// else.
///
/// Internal rather than private for the same reason `SpotifyParsing` is: the
/// chunk-boundary behaviour is the part worth exercising directly.
nonisolated final class LineAssembler {

    private var buffer = Data()

    func lines(from chunk: Data) -> [Data] {
        buffer.append(chunk)
        var complete: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { complete.append(Data(line)) }
            // Rebased copy: slice indices stay anchored to the original range
            // otherwise, and the next firstIndex would walk consumed bytes.
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return complete
    }
}

/// One-shot latch, so a repeating condition is reported once per stream
/// rather than once per occurrence.
///
/// Touched only from the pipe's read handler, which `FileHandle` serialises.
private nonisolated final class OnceGate {
    private var fired = false
    func firstTime() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

// MARK: - Wire format

/// One `{"type":..., "diff":..., "payload":{...}}` line.
nonisolated struct SystemMediaEnvelope: Decodable, Sendable {
    let type: String?
    let diff: Bool?
    let payload: SystemMediaPayload?
}

/// The payload's fields, all optional because a `diff` line carries only what
/// changed. Absent and explicitly-null are indistinguishable here; the tool
/// emits absent, and both correctly mean "keep what is retained".
///
/// Names match the tool's wire format exactly — `elapsedTime`, not `elapsed`,
/// and `playing`, not `isPlaying` — so this decodes with no CodingKeys.
/// Seconds throughout, unlike Spotify's milliseconds.
nonisolated struct SystemMediaPayload: Decodable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    /// Base64. Decoded in the adapter, which caches it, rather than here.
    var artworkData: String?
    var artworkMimeType: String?
    var duration: TimeInterval?
    var elapsedTime: TimeInterval?
    var playing: Bool?
    var playbackRate: Double?
    var bundleIdentifier: String?
    var contentItemIdentifier: String?

    init() {}

    /// Names of the fields this payload actually carries. Logging only, so a
    /// diff line can be shown to have carried a subset of the whole.
    var presentFieldNames: [String] {
        var names: [String] = []
        if title != nil { names.append("title") }
        if artist != nil { names.append("artist") }
        if album != nil { names.append("album") }
        if artworkData != nil { names.append("artworkData") }
        if artworkMimeType != nil { names.append("artworkMimeType") }
        if duration != nil { names.append("duration") }
        if elapsedTime != nil { names.append("elapsedTime") }
        if playing != nil { names.append("playing") }
        if playbackRate != nil { names.append("playbackRate") }
        if bundleIdentifier != nil { names.append("bundleIdentifier") }
        if contentItemIdentifier != nil { names.append("contentItemIdentifier") }
        return names
    }

    /// This payload's fields laid over `old`, keeping `old` wherever this one
    /// says nothing. The whole point of the diff handling: a position-only
    /// update names `elapsedTime` and nothing else, and artist, album and
    /// artwork have to survive it.
    func merged(over old: SystemMediaPayload) -> SystemMediaPayload {
        var result = old
        if let title { result.title = title }
        if let artist { result.artist = artist }
        if let album { result.album = album }
        if let artworkData { result.artworkData = artworkData }
        if let artworkMimeType { result.artworkMimeType = artworkMimeType }
        if let duration { result.duration = duration }
        if let elapsedTime { result.elapsedTime = elapsedTime }
        if let playing { result.playing = playing }
        if let playbackRate { result.playbackRate = playbackRate }
        if let bundleIdentifier { result.bundleIdentifier = bundleIdentifier }
        if let contentItemIdentifier { result.contentItemIdentifier = contentItemIdentifier }
        return result
    }
}

/// What kind of thing a system session is carrying. Not a ranking of two
/// candidates: macOS reports one session at a time, so this only ever
/// describes the single session on offer.
nonisolated enum SystemSessionTier: Sendable {
    case music
    case video
}

/// Pure parsing, split out for tests — same arrangement as `SpotifyParsing`.
///
/// Split isolation on purpose. The project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything here is
/// main-actor isolated unless it says otherwise: `decode(line:)` is marked
/// `nonisolated` because it runs on the pipe's queue, while `snapshot(...)`
/// keeps the default because `NowPlaying` is main-actor isolated like the rest
/// of the model layer. Dropping the annotation compiles under Swift 5 but
/// hops 45KB of JSON onto the main thread, and is an error in Swift 6.
enum SystemMediaParsing {

    /// Decodes one line. Returns nil for anything unrecognisable rather than
    /// throwing: one malformed line must not take the stream down.
    nonisolated static func decode(line: Data) -> SystemMediaEnvelope? {
        guard let envelope = try? JSONDecoder().decode(SystemMediaEnvelope.self, from: line) else {
            return nil
        }
        // Every field is optional, so unrelated JSON decodes "successfully"
        // into an all-nil envelope — which `apply` would read as a full empty
        // payload and use to wipe the retained track. A line with no `type` is
        // not one of ours; treat it as unparseable.
        guard envelope.type != nil else { return nil }
        return envelope
    }

    /// Whether a session looks like music or like video.
    ///
    /// `album` is the whole test, and it is the only field that separates the
    /// two. Verified with `media-control get` on 2026-09-01: a YouTube Music
    /// track reports `album: "Camp"`, a YouTube video reports `album: ""`,
    /// and every other field — `bundleIdentifier` and `processIdentifier`
    /// included — is identical. There is no richer signal available.
    nonisolated static func tier(of payload: SystemMediaPayload) -> SystemSessionTier {
        let album = payload.album ?? ""
        return album.isEmpty ? .video : .music
    }

    /// Builds a snapshot from merged state, or nil when there is nothing to
    /// show — the empty payload the tool opens with, and what it sends when
    /// the last session goes away.
    ///
    /// `artwork` is passed in already decoded so this stays pure and the
    /// 40KB base64 is not re-decoded on every position tick.
    static func snapshot(
        from payload: SystemMediaPayload, artwork: Data?, capturedAt: Date
    ) -> NowPlaying? {
        var snapshot = NowPlaying()
        snapshot.isPlaying = payload.playing ?? false
        snapshot.title = payload.title.nonEmpty
        snapshot.artist = payload.artist.nonEmpty
        snapshot.album = payload.album.nonEmpty
        snapshot.artworkData = artwork
        snapshot.artworkIdentifier = payload.contentItemIdentifier.nonEmpty
        snapshot.duration = payload.duration
        snapshot.elapsed = payload.elapsedTime
        snapshot.sourceBundleID = payload.bundleIdentifier.nonEmpty
        snapshot.capturedAt = capturedAt

        guard snapshot.hasContent else { return nil }
        return snapshot
    }
}

private extension Optional where Wrapped == String {
    /// Empty strings are how the tool spells "no album", and `hasContent`
    /// counts any non-nil title as presence — so they have to become nil.
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
