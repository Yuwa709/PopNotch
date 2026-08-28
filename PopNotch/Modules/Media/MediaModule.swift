import SwiftUI
import Observation
import os

/// Now playing in the notch — the reason the app exists.
///
/// Owns the player adapters; the active snapshot is whichever source
/// reported most recently. Sources observe by push (no timers), so the
/// module hears track changes even while not displayed and answers them by
/// requesting a live activity: the notch pops open with the new song.
@MainActor
@Observable
final class MediaModule: NotchModule {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Media")

    /// Permanent settings key; never rename.
    @ObservationIgnored let id: ModuleID = "media"
    @ObservationIgnored let displayName = "Now Playing"
    @ObservationIgnored let priority: ModulePriority = .elevated
    @ObservationIgnored var isEnabled = true

    /// Seconds the notch stays open on a track change.
    @ObservationIgnored static let popDuration: TimeInterval = 4

    /// Wired by AppDelegate to the coordinator.
    @ObservationIgnored var onLiveActivityRequest: ((LiveActivityRequest) -> Void)?

    /// Fires when whether-there-is-anything-to-show flips — the coordinator
    /// resizes the collapsed panel between idle and compact on it. Content
    /// *changes* do not fire it; the wing views observe those themselves.
    @ObservationIgnored var onPresenceChange: (() -> Void)?

    /// Fires when expanded-content height changes shape (lyrics appearing or
    /// clearing), so the coordinator can re-measure the open panel.
    @ObservationIgnored var onContentReflow: (() -> Void)?

    private(set) var nowPlaying: NowPlaying?
    /// Synced lyrics for the current track, nil while absent or unfetched.
    private(set) var lyrics: [LyricsLine]?
    /// Accent pulled from the current artwork; views fall back to the fixed
    /// peach when nil (colorless art, or artwork not yet loaded).
    private(set) var artworkAccent: Color?
    /// Decoded once per artwork change rather than per render — the
    /// visualizer needs an NSImage and SwiftUI bodies run often.
    private(set) var artworkImage: NSImage?
    @ObservationIgnored private var accentSourceData: Data?

    /// Account-backed extras (nil until the user connects Spotify).
    private(set) var upNext: SpotifyUpNext?
    private(set) var likedCurrent: Bool?
    /// Official artist metadata: avatar, follower count, genres.
    private(set) var artistInfo: SpotifyArtistInfo?
    private(set) var artistImageData: Data?
    /// Spotify's 0-100 popularity score for the current track.
    private(set) var trackPopularity: Int?
    /// Cached per artist so skipping within an album costs no extra calls.
    @ObservationIgnored private var artistCache: [String: (SpotifyArtistInfo, Data?)] = [:]

    /// Where playback was started from, e.g. `spotify:playlist:...`. Drives
    /// the artwork tap. Not `@Observable` state — nothing renders from it.
    /// Kept across a track change rather than cleared: within one playlist
    /// the context does not change, so the stale value is the right value,
    /// and the refresh overwrites it a round trip later either way.
    @ObservationIgnored private var playbackContextURI: String?

    /// When true the expanded notch shows full scrolling lyrics instead of
    /// the player, and stays open regardless of hover until dismissed.
    private(set) var showFullLyrics = false

    @ObservationIgnored private let sources: [MediaSource]
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private let account: SpotifyAccount?
    @ObservationIgnored private let webAPI: SpotifyWebAPI?
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hadPresence = false

    var accountConnected: Bool { account?.isConnected == true }

    var permissionDenied: Bool {
        sources.allSatisfy(\.permissionDenied)
    }

    init(sources: [MediaSource], account: SpotifyAccount? = nil) {
        self.sources = sources
        self.account = account
        self.webAPI = account.map(SpotifyWebAPI.init(account:))
        for source in sources {
            source.onUpdate = { [weak self] snapshot in
                self?.handleUpdate(snapshot)
            }
            source.startObserving()
        }
    }

    private func handleUpdate(_ snapshot: NowPlaying?) {
        nowPlaying = snapshot

        // Recompute the accent only when the artwork bytes actually change —
        // a 24x24 downsample pass, cheap, but not worth repeating per tick.
        if snapshot?.artworkData != accentSourceData {
            accentSourceData = snapshot?.artworkData
            artworkAccent = snapshot?.artworkData.flatMap(ArtworkColor.dominant(in:))
            artworkImage = snapshot?.artworkData.flatMap(NSImage.init(data:))
        }

        let hasPresence = snapshot?.hasContent == true
        if hasPresence != hadPresence {
            hadPresence = hasPresence
            onPresenceChange?()
        }

        guard let snapshot, snapshot.hasContent else { return }
        let key = snapshot.artworkIdentifier ?? "\(snapshot.title ?? "")|\(snapshot.artist ?? "")"
        guard key != lastTrackKey else { return }

        lastTrackKey = key
        // Auto-announcing track changes (a 4s live-activity pop) shipped and
        // was experienced as a glitch — the notch "expands for a second and
        // goes back" uninvited. Off until it can be a designed banner; the
        // live-activity plumbing stays for whatever earns it next.

        // New track: leave the full-lyrics takeover, clear old lyrics
        // (shrinking the open panel if showing), and fetch this track's.
        showFullLyrics = false
        if lyrics != nil {
            lyrics = nil
            onContentReflow?()
        }
        fetchLyrics(for: snapshot, trackKey: key)
        refreshAccountExtras()
    }

    func send(_ command: MediaCommand) {
        // v1: one adapter. With several, route to the one that is running.
        sources.first { $0.isPlayerRunning }?.send(command)
    }

    func seek(to seconds: TimeInterval) {
        sources.first { $0.isPlayerRunning }?.seek(to: seconds)
    }

    private func fetchLyrics(for snapshot: NowPlaying, trackKey: String) {
        guard let artist = snapshot.artist, let title = snapshot.title else { return }
        lyricsService.fetch(artist: artist, title: title, duration: snapshot.duration, key: trackKey) { [weak self] lines in
            guard let self, self.lastTrackKey == trackKey else { return } // stale reply
            self.lyrics = lines
            if lines != nil {
                self.onContentReflow?()
            }
        }
    }

    // MARK: - NotchModule

    func makeCompactView() -> AnyView { AnyView(MediaCompactView(module: self)) }
    func makeExpandedView() -> AnyView { AnyView(MediaExpandedView(module: self)) }

    /// The wings: artwork left of the housing, waveform right of it — the
    /// "music is on" indicator visible without hovering.
    func makeCompactLeadingView() -> AnyView? {
        guard nowPlaying?.hasContent == true else { return nil }
        return AnyView(MediaWingArtwork(module: self))
    }

    func makeCompactTrailingView() -> AnyView? {
        guard nowPlaying?.hasContent == true else { return nil }
        // The 3pt nudge is wing-placement tuning (user-measured); it lives
        // here so the same waveform sits naturally in the expanded layout.
        return AnyView(MediaWingWaveform(module: self).offset(x: -3))
    }

    func didBecomeVisible() {
        // Pull once so the first hover after launch has data and artwork.
        // This is what triggers the one-time Automation permission prompt.
        sources.forEach { $0.refresh() }
        refreshAccountExtras()
    }

    // MARK: - Account extras

    /// The current track's Spotify ID, when the URI is a track at all.
    private var currentTrackID: String? {
        nowPlaying?.artworkIdentifier.flatMap(SpotifyWebAPI.trackID(fromURI:))
    }

    /// Event-driven only (track change, panel opening): no polling loop.
    private func refreshAccountExtras() {
        guard let webAPI, accountConnected else { return }
        let trackID = currentTrackID
        Task { [weak self] in
            let next = await webAPI.fetchUpNext()
            let context = await webAPI.fetchPlaybackContext()
            let liked: Bool? = if let trackID { await webAPI.isSaved(trackID: trackID) } else { nil }
            guard let self else { return }
            self.upNext = next
            if let context { self.playbackContextURI = context }
            self.likedCurrent = liked
            await self.refreshArtistDetail(trackID: trackID, webAPI: webAPI)
        }
    }

    /// Official track and artist metadata: popularity score, artist avatar,
    /// follower count. Two calls on a track change, then cached per artist.
    private func refreshArtistDetail(trackID: String?, webAPI: SpotifyWebAPI) async {
        guard let trackID, let detail = await webAPI.fetchTrackDetail(trackID: trackID) else {
            trackPopularity = nil
            return
        }
        trackPopularity = detail.popularity

        if let cached = artistCache[detail.artistID] {
            artistInfo = cached.0
            artistImageData = cached.1
            return
        }
        guard let info = await webAPI.fetchArtist(id: detail.artistID) else { return }
        var imageData: Data?
        if let url = info.imageURL {
            imageData = await webAPI.fetchImage(url)
        }
        artistCache[detail.artistID] = (info, imageData)
        artistInfo = info
        artistImageData = imageData
        onContentReflow?()
    }

    /// Opens what is playing in the Spotify app. This activates Spotify —
    /// permitted because it is a direct response to the user tapping the
    /// artwork, not a hover (hard rule 4 protects against hover-stealing).
    ///
    /// Prefers the playback *context* — the playlist or collection the user
    /// started from — over the track URI, which lands on the canonical album
    /// page instead of wherever they actually were. Falls back to the track
    /// when there is no context: autoplay and radio genuinely have none, and
    /// so does every case where the account is not connected.
    func openInSpotify() {
        guard let uri = playbackContextURI ?? nowPlaying?.artworkIdentifier,
              let url = URL(string: uri) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Toggles the full-lyrics takeover. Pins the notch open while on.
    func toggleFullLyrics() {
        guard lyrics?.isEmpty == false else { return }
        showFullLyrics.toggle()
        onContentReflow?()
    }

    /// The notch collapsed (cursor left). Leave the lyrics takeover so the
    /// next hover shows the player, matching how every other view collapses.
    func notchDidCollapse() {
        showFullLyrics = false
    }

    func toggleLike() {
        guard let webAPI, let trackID = currentTrackID else { return }
        let target = !(likedCurrent ?? false)
        likedCurrent = target // optimistic; revert on failure
        Task { [weak self] in
            let accepted = await webAPI.setSaved(target, trackID: trackID)
            if !accepted { self?.likedCurrent = !target }
        }
    }

    func didResignVisible() {
        // Observation is push-based with no timers, so it stays on — that is
        // how track changes can pop the notch while we are off screen.
    }
}
