import AppKit
import os

/// Reads and controls Spotify.
///
/// Metadata arrives two ways:
/// - **Push:** Spotify broadcasts `com.spotify.client.PlaybackStateChanged`
///   as a distributed notification on every track/state change, with title,
///   artist, album, duration, and position in userInfo. No polling, no
///   permission needed.
/// - **Pull:** an AppleScript query fills in what the notification lacks —
///   initial state at launch and the artwork URL. Apple Events need the
///   Automation permission (one system prompt, first call).
///
/// Artwork itself is an image fetch from the URL Spotify's scripting
/// interface hands us — a network call permitted by the hard rule 6 decision
/// recorded in PROJECT-CONTEXT.md. `artwork url` is the only usable route:
/// the dictionary's `artwork` property is image data that Spotify does not
/// populate, so reading it yields nothing.
///
/// What this dictionary cannot do, verified against `sdef`:
/// - **No queue.** There is no playlist, context, or queue class. `next
///   track` is a *command* that skips; it returns no data. `upNext` is
///   therefore always nil here, and never derived by skipping.
/// - **No favourite state.** `starred` is in the dictionary with
///   `access="r"`, but Spotify does not implement the handler: reading it
///   throws **-10000 (errAEEventFailed)** against the live app, measured
///   2026-08-28. It was briefly in the query script and took every other
///   field down with it, because AppleScript aborts the whole `return`
///   expression when one property fails — which is how nine working fields,
///   artwork included, were lost to one unimplemented term. Favourite is
///   therefore `.unsupported` here, not `.readOnly`. Do not re-add it.
@MainActor
final class SpotifyAdapter: MediaSource {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Spotify")
    static let bundleID = "com.spotify.client"
    static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    let sourceID = "spotify"
    var onUpdate: ((NowPlaying?) -> Void)?
    private(set) var permissionDenied = false

    private var observer: NSObjectProtocol?
    /// Last fetched artwork, keyed by its URL so a track change refetches
    /// exactly once and pause/resume does not refetch at all.
    private var artworkCache: (url: String, data: Data)?
    private var lastSnapshot: NowPlaying?
    private var artworkTask: URLSessionDataTask?

    /// Constant: Spotify exposes no readable favourite over AppleScript at
    /// all (see the header note on `starred`). With an account connected the
    /// Web API supplies a real, writable like; `MediaModule` owns that path
    /// and never consults this property.
    let favorite: FavoriteState = .unsupported

    var isPlayerRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    // MARK: - Observing

    func startObserving() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleNotification(note.userInfo ?? [:])
            }
        }
        Self.logger.notice("Observing Spotify playback notifications")
    }

    func stopObserving() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        artworkTask?.cancel()
    }

    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        guard let snapshot = SpotifyParsing.decode(notification: userInfo) else {
            lastSnapshot = nil
            onUpdate?(nil)
            return
        }
        let isNewTrack = snapshot.artworkIdentifier != lastSnapshot?.artworkIdentifier
        publish(snapshot)
        // The notification carries no artwork; fetch it via AppleScript once
        // per track. Skipped entirely once the user has declined Automation.
        if isNewTrack && !permissionDenied {
            refresh()
        }
    }

    // MARK: - Pull

    /// Exposed for the regression test that asserts `starred` never returns.
    static var queryScriptSource: String { queryScript }

    /// One query returning newline-separated fields; see SpotifyParsing.
    private static let queryScript = """
        tell application "Spotify"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & "\\n" & name of t & "\\n" & artist of t \
                & "\\n" & album of t & "\\n" & (duration of t as text) \
                & "\\n" & (player position as text) & "\\n" & artwork url of t \
                & "\\n" & (id of t as text)
        end tell
        """

    func refresh() {
        // Never Apple-Event a dead app: "tell application" would launch it.
        guard isPlayerRunning else {
            lastSnapshot = nil
            onUpdate?(nil)
            return
        }
        // Deliberately no `guard !permissionDenied`: refresh() is called on
        // hover, so a user who grants access in System Settings recovers on
        // their next hover instead of having to relaunch. A genuine denial
        // returns -1743 immediately without re-prompting, so retrying here
        // costs nothing and cannot produce a dialog loop.
        switch AppleScriptRunner.run(Self.queryScript) {
        case .success(let descriptor):
            if permissionDenied {
                permissionDenied = false
                Self.logger.notice("Automation permission now granted; pull path re-enabled")
            }
            guard let output = descriptor.stringValue,
                  let parsed = SpotifyParsing.parse(scriptOutput: output)
            else {
                lastSnapshot = nil
                onUpdate?(nil)
                return
            }
            Self.logger.notice(
                "Pull ok: artwork=\(parsed.artworkURL == nil ? "none" : "url", privacy: .public), upNext=nil (no queue in dictionary)"
            )
            publish(parsed.snapshot)
            if let url = parsed.artworkURL { fetchArtwork(from: url) }
        case .failure(let failure):
            // Log every failure, not just denials. A -10000 from one
            // unimplemented property used to produce no adapter-level line
            // at all, so a totally dead pull path looked identical to a
            // healthy one — artwork silently missing with permission
            // reporting green. Never let a failure mode be silent again.
            if failure.isPermissionDenied {
                permissionDenied = true
                Self.logger.notice("Automation permission denied for Spotify; pull path disabled")
            } else {
                Self.logger.error(
                    "Spotify pull failed (\(failure.code, privacy: .public)) — not a permission problem; artwork and pull-only fields will be missing"
                )
            }
        }
    }

    private func publish(_ snapshot: NowPlaying) {
        var merged = snapshot
        // Keep artwork across pause/resume and metadata-only updates.
        if merged.artworkData == nil, let cache = artworkCache,
           merged.artworkIdentifier == lastSnapshot?.artworkIdentifier {
            merged.artworkData = cache.data
        }
        lastSnapshot = merged
        onUpdate?(merged)
    }

    // MARK: - Artwork

    private func fetchArtwork(from urlString: String) {
        if artworkCache?.url == urlString {
            attachArtwork(artworkCache!.data)
            return
        }
        guard let url = URL(string: urlString), url.scheme == "https" else { return }

        artworkTask?.cancel()
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.artworkCache = (urlString, data)
                self.attachArtwork(data)
            }
        }
        artworkTask?.resume()
    }

    private func attachArtwork(_ data: Data) {
        guard var snapshot = lastSnapshot else { return }
        snapshot.artworkData = data
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    // MARK: - Commands

    func seek(to seconds: TimeInterval) {
        guard isPlayerRunning else { return }
        // Integer seconds sidestep locale decimal-separator issues in the
        // script source; nobody scrubs to sub-second precision by hand.
        let target = max(0, Int(seconds))
        if case .failure(let failure) = AppleScriptRunner.run(
            "tell application \"Spotify\" to set player position to \(target)"
        ) {
            if failure.isPermissionDenied { permissionDenied = true }
            return
        }
        // Optimistic: reflect the jump immediately rather than waiting for
        // Spotify's next notification.
        if var snapshot = lastSnapshot {
            snapshot.elapsed = TimeInterval(target)
            snapshot.capturedAt = Date()
            lastSnapshot = snapshot
            onUpdate?(snapshot)
        }
    }

    func send(_ command: MediaCommand) {
        guard isPlayerRunning else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        }
        if case .failure(let failure) = AppleScriptRunner.run("tell application \"Spotify\" to \(verb)"),
           failure.isPermissionDenied {
            permissionDenied = true
        }
    }
}

/// Pure parsing, split out for tests.
enum SpotifyParsing {

    /// Decodes the distributed notification's userInfo. Returns nil when
    /// there is nothing to show (stopped, or the payload is unrecognisable).
    static func decode(notification userInfo: [AnyHashable: Any]) -> NowPlaying? {
        guard let state = userInfo["Player State"] as? String, state != "Stopped" else {
            return nil
        }
        var snapshot = NowPlaying()
        snapshot.isPlaying = state == "Playing"
        snapshot.title = userInfo["Name"] as? String
        snapshot.artist = userInfo["Artist"] as? String
        snapshot.album = userInfo["Album"] as? String
        if let ms = (userInfo["Duration"] as? NSNumber)?.doubleValue {
            snapshot.duration = ms / 1000
        }
        snapshot.elapsed = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        snapshot.artworkIdentifier = userInfo["Track ID"] as? String
        snapshot.sourceBundleID = SpotifyAdapter.bundleID
        return snapshot.hasContent ? snapshot : nil
    }

    /// Parses the query script's newline-separated output:
    /// state, title, artist, album, duration-ms, position-s, artwork URL, id.
    ///
    /// Eight fields, and deliberately no ninth. `starred` was appended here
    /// once and reverted — see the note on `SpotifyAdapter`.
    static func parse(scriptOutput: String)
        -> (snapshot: NowPlaying, artworkURL: String?)? {
        guard scriptOutput != "stopped" else { return nil }
        let lines = scriptOutput.components(separatedBy: "\n")
        guard lines.count >= 8 else { return nil }

        var snapshot = NowPlaying()
        snapshot.isPlaying = lines[0] == "playing"
        snapshot.title = lines[1].isEmpty ? nil : lines[1]
        snapshot.artist = lines[2].isEmpty ? nil : lines[2]
        snapshot.album = lines[3].isEmpty ? nil : lines[3]
        // AppleScript renders reals with the locale's decimal separator.
        if let ms = Double(lines[4].replacingOccurrences(of: ",", with: ".")) {
            snapshot.duration = ms / 1000
        }
        snapshot.elapsed = Double(lines[5].replacingOccurrences(of: ",", with: "."))
        snapshot.artworkIdentifier = lines[7].isEmpty ? nil : lines[7]
        snapshot.sourceBundleID = SpotifyAdapter.bundleID

        guard snapshot.hasContent else { return nil }
        let url = lines[6].isEmpty ? nil : lines[6]
        return (snapshot, url)
    }
}
