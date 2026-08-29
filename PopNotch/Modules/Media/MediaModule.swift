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
    /// Injected, not owned: caffeinate is an app-level concern that merely
    /// renders inside this widget. Nil in tests and previews.
    @ObservationIgnored let caffeinate: CaffeinateService?
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private let account: SpotifyAccount?
    @ObservationIgnored private let webAPI: SpotifyWebAPI?
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hadPresence = false

    /// Which adapter currently owns the notch. Written only by
    /// `handleUpdate(_:from:)`; every command routes here rather than to
    /// "the first running player", which was correct only while one adapter
    /// existed.
    @ObservationIgnored private var activeSource: (any MediaSource)?

    /// Whether the current track's favourite can be changed. False for
    /// Spotify without a connected account, because `starred` is read-only
    /// in its dictionary — the UI must not offer a toggle there.
    var canToggleFavorite: Bool {
        if activeSource?.sourceID == "spotify" { return webAPI != nil && accountConnected }
        return activeSource?.favorite.isEditable ?? false
    }

    var accountConnected: Bool { account?.isConnected == true }

    /// Drives the in-notch "allow Automation" banner, which renders only
    /// when the widget is empty. Denial explains emptiness only for a player
    /// that is actually **running**: its pull path is dead, so there is
    /// nothing to show. A denied-but-closed player is not the reason the
    /// widget is empty — granting it would display nothing — and belongs to
    /// the Permissions tab, not this banner.
    ///
    /// Was `allSatisfy` when one adapter existed; with two, a never-probed
    /// MusicAdapter kept its flag false forever and a denied Spotify could
    /// never surface the banner.
    var permissionDenied: Bool {
        sources.contains { $0.isPlayerRunning && $0.permissionDenied }
    }

    init(sources: [MediaSource],
         account: SpotifyAccount? = nil,
         caffeinate: CaffeinateService? = nil) {
        self.sources = sources
        self.account = account
        self.caffeinate = caffeinate
        self.webAPI = account.map(SpotifyWebAPI.init(account:))
        for source in sources {
            source.onUpdate = { [weak self, weak source] snapshot in
                guard let source else { return }
                self?.handleUpdate(snapshot, from: source)
            }
            source.startObserving()
        }
    }

    /// Picks which player owns the notch when more than one is running.
    ///
    /// Rules, in order:
    /// 1. A source reporting *playing* audio always wins. Two players cannot
    ///    both be audible for long, and the audible one is what the user means.
    /// 2. Otherwise the incumbent keeps the notch, so a paused Spotify in the
    ///    background cannot stomp a paused Music the user is actually looking
    ///    at. This is the "never switch silently" rule from Phase 4 task 2.
    /// 3. A source losing content only clears the notch if it *held* it; the
    ///    notch then falls back to any other source that still has something.
    ///
    /// Before this existed the module was last-writer-wins, which was correct
    /// only because exactly one adapter was registered.
    private func shouldTakeOver(_ snapshot: NowPlaying?, from source: any MediaSource) -> Bool {
        if snapshot?.isPlaying == true { return true }
        guard let active = activeSource else { return snapshot?.hasContent == true }
        return active === source
    }

    private func handleUpdate(_ snapshot: NowPlaying?, from source: any MediaSource) {
        guard shouldTakeOver(snapshot, from: source) else { return }

        if activeSource !== source, snapshot?.hasContent == true {
            Self.logger.notice("Active media source -> \(source.sourceID, privacy: .public)")
        }

        if snapshot?.hasContent == true {
            activeSource = source
        } else if activeSource === source {
            // The owner went quiet: hand off to another source still playing
            // something rather than blanking the notch outright.
            activeSource = sources.first { $0 !== source && $0.isPlayerRunning }
        }

        adoptSourceExtras()
        handleUpdate(snapshot)
    }

    /// Resolves Up Next and favourite for whichever source owns the notch.
    ///
    /// Precedence is per source, because the two dictionaries expose
    /// genuinely different things:
    /// - **Music** answers both itself, with no network: a real queue via
    ///   `current playlist`, and a read-write `favorited`.
    /// - **Spotify** answers neither usefully. It has no queue class at all,
    ///   and `starred` is read-only. Its Up Next and its *editable* like come
    ///   from the optional Web API; with no account connected it degrades to
    ///   `starred` as display-only, which is all the dictionary permits.
    ///
    /// Synchronous and free — the adapter refreshed these during its own
    /// Apple Event before calling back.
    private func adoptSourceExtras() {
        guard let active = activeSource else {
            setUpNext(nil)
            likedCurrent = nil
            return
        }
        if active is SpotifyAdapter {
            guard !accountConnected else { return } // Web API path owns these
            setUpNext(nil)
            likedCurrent = active.favorite.value
        } else {
            setUpNext(active.upNext)
            likedCurrent = active.favorite.value
        }
    }

    /// The Up Next slot is removed from the layout entirely when there is
    /// nothing queued, so its arrival or departure changes the expanded
    /// panel's height and the coordinator has to re-measure.
    ///
    /// Only *presence* reflows. Swapping one queued title for another leaves
    /// the slot the same size, and reflowing on every track change would
    /// re-measure the panel for nothing.
    private func setUpNext(_ next: UpNextTrack?) {
        let had = upNext != nil
        upNext = next
        if had != (next != nil) { onContentReflow?() }
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

    /// The adapter commands go to: whoever owns the notch, falling back to
    /// any running player before the notch has been claimed.
    private var commandTarget: (any MediaSource)? {
        activeSource ?? sources.first { $0.isPlayerRunning }
    }

    func send(_ command: MediaCommand) {
        commandTarget?.send(command)
    }

    func seek(to seconds: TimeInterval) {
        commandTarget?.seek(to: seconds)
    }

    private func fetchLyrics(for snapshot: NowPlaying, trackKey: String) {
        guard let artist = snapshot.artist, let title = snapshot.title else { return }
        // Music can answer from its own `lyrics` property; Spotify cannot,
        // and returns nil here, sending the lookup straight to LRCLIB.
        let embedded = activeSource?.embeddedLyrics()
        lyricsService.fetch(
            artist: artist, title: title, duration: snapshot.duration, embeddedLRC: embedded
        ) { [weak self] lines in
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
    ///
    /// Gated on Spotify owning the notch: querying Spotify's Web API while
    /// Apple Music is playing would report the wrong player's queue and the
    /// wrong track's like state.
    private func refreshAccountExtras() {
        guard let webAPI, accountConnected, activeSource is SpotifyAdapter else { return }
        let trackID = currentTrackID
        Task { [weak self] in
            let next = await webAPI.fetchUpNext()
            let context = await webAPI.fetchPlaybackContext()
            let liked: Bool? = if let trackID { await webAPI.isSaved(trackID: trackID) } else { nil }
            guard let self else { return }
            self.setUpNext(next)
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

    /// Only ever called when `canToggleFavorite` is true. Spotify writes go
    /// through the Web API because its `starred` is read-only; Music writes
    /// go straight to the player.
    func toggleLike() {
        guard canToggleFavorite else { return }
        let target = !(likedCurrent ?? false)
        likedCurrent = target // optimistic; revert on failure

        if let active = activeSource, !(active is SpotifyAdapter) {
            active.setFavorite(target)
            likedCurrent = active.favorite.value
            return
        }
        guard let webAPI, let trackID = currentTrackID else {
            likedCurrent = !target
            return
        }
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
