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
    /// Switching on is what pulls the players: at launch, where
    /// `NotchCoordinator.register` applies the stored preference, and again
    /// when re-enabled from Settings. Not in `init`, so a user who has media
    /// switched off never sends an Apple Event or sees the Automation prompt.
    @ObservationIgnored var isEnabled = true {
        didSet { if isEnabled { pullSources() } }
    }

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

    /// True while a lyrics lookup is running for a track that *replaced* a
    /// track which had lyrics. The view keeps the lyric area at full height
    /// while it is set, so the panel does not shrink on the transient nil.
    ///
    /// This exists because the panel is top-anchored: shrinking pulls the
    /// bottom edge up past the transport buttons, so the cursor that just
    /// pressed Next ends up outside the frame and AppKit fires a *correct*
    /// mouseExited, which collapses the panel. Measured: a 59pt drop, from a
    /// 275pt panel to 216pt, with the transport row sitting inside the band
    /// that vanishes.
    private(set) var lyricsReserved = false

    /// Whether the lyric area currently occupies its full height — either
    /// showing lyrics, or holding the space for a lookup in flight. Reflow is
    /// driven by changes to *this*, not to `lyrics`, so content swapping
    /// inside an unchanged height never resizes the panel.
    var lyricsOccupiesHeight: Bool { lyrics != nil || lyricsReserved }
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
    /// Shuffle and repeat, mirrored from the active source the same way
    /// `likedCurrent` and `upNext` are. The mirror is the point: the
    /// adapters are not `@Observable`, so a view reading them directly
    /// renders whatever was true at its last unrelated re-evaluation.
    /// These are observable stored properties, and writing them is what
    /// makes the buttons redraw.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?
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
    /// Injected, not owned. The progress row renders the spectrum, and this
    /// module is what tells the service whether they may capture: the
    /// tracked player's play state, and whether the player screen, whose
    /// progress row draws it, is on screen. Nil in tests that do not care.
    @ObservationIgnored let visualizer: AudioVisualizerService?
    @ObservationIgnored private let webAPI: SpotifyWebAPI?
    /// The open panel's live-sync clock. Exists only between
    /// `didBecomeVisible()` and `didResignVisible()`, and is stopped by
    /// display sleep in between — hard rule 9, all three clauses.
    @ObservationIgnored private var liveSyncTimer: Timer?
    @ObservationIgnored private var liveSyncWanted = false
    /// Between `didBecomeVisible()` and `didResignVisible()`: this module's
    /// expanded view is on screen. The spectrum needs this as well as the
    /// screen, because the player stays the current screen of a closed panel.
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    /// Two seconds: the three-property read costs ~50ms on the main actor, so
    /// this is a 2.5% duty cycle. One second would double it for a playhead
    /// the local projection already keeps smooth between reads.
    static let liveSyncInterval: TimeInterval = 2

    /// Whether the clock is running. Exposed so "nothing polls while the panel
    /// is closed" is a test rather than a comment.
    var isLiveSyncing: Bool { liveSyncTimer != nil }

    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hadPresence = false
    @ObservationIgnored private var hadExpandedContent = false

    /// Which adapter currently owns the notch. Written only by
    /// `handleUpdate(_:from:)`; every command routes here rather than to
    /// "the first running player", which was correct only while one adapter
    /// existed.
    @ObservationIgnored private var activeSource: (any MediaSource)?

    /// What each source last reported, keyed by `sourceID`, holding only
    /// snapshots with content. `shouldTakeOver` needs to know whether a
    /// *dedicated* adapter has anything, which cannot be answered from the
    /// one snapshot currently being delivered.
    @ObservationIgnored private var snapshots: [ModuleID: NowPlaying] = [:]

    /// True when Spotify or Music has a track — playing or paused. The system
    /// source is a fallback and may not take the notch while this holds.
    private var dedicatedSourceHasContent: Bool {
        sources.contains { !($0 is SystemMediaAdapter) && snapshots[$0.sourceID] != nil }
    }

    /// Where the notch goes when the owner falls silent: whoever still has
    /// something, dedicated adapters ahead of the system source.
    private func fallbackSource(excluding source: any MediaSource) -> (any MediaSource)? {
        let candidates = sources.filter { $0 !== source && snapshots[$0.sourceID] != nil }
        return candidates.first { !($0 is SystemMediaAdapter) } ?? candidates.first
    }

    /// Whether the current track's favourite can be changed. False for
    /// Spotify without a connected account, because `starred` is read-only
    /// in its dictionary — the UI must not offer a toggle there.
    var canToggleFavorite: Bool {
        if activeSource?.sourceID == "spotify" {
            return webAPI != nil && accountConnected && !libraryForbidden
        }
        return activeSource?.favorite.isEditable ?? false
    }

    /// Spotify has refused this account's library with a 403. See
    /// `SpotifyAccount.libraryAccessForbidden`.
    var libraryForbidden: Bool { account?.libraryAccessForbidden == true }

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

    /// What the expanded view shows, in branch order: the full-lyrics
    /// takeover, the player, the permission banner, or nothing.
    ///
    /// The one place that condition lives. `MediaExpandedView` switches on
    /// it and `hasExpandedContent` tests it for nil; neither restates the
    /// tests, so the panel's chrome-only decision cannot drift from what
    /// the view would actually draw.
    enum ExpandedScreen {
        case fullLyrics
        case player(NowPlaying)
        case permissionDenied
    }

    var expandedScreen: ExpandedScreen? {
        if showFullLyrics { return .fullLyrics }
        if let playing = nowPlaying, playing.hasContent { return .player(playing) }
        if permissionDenied { return .permissionDenied }
        return nil
    }

    var hasExpandedContent: Bool { expandedScreen != nil }

    init(sources: [MediaSource],
         account: SpotifyAccount? = nil,
         visualizer: AudioVisualizerService? = nil) {
        self.sources = sources
        self.account = account
        self.visualizer = visualizer
        self.webAPI = account.map(SpotifyWebAPI.init(account:))
        for source in sources {
            source.onUpdate = { [weak self, weak source] snapshot in
                guard let source else { return }
                self?.handleUpdate(snapshot, from: source)
            }
            source.startObserving()
        }

        // Display sleep stops the clock even with the panel pinned open —
        // the same observers every polling service in this app carries.
        // Block-based rather than selector-based: this class is not an
        // NSObject, and `SpotifyAdapter` already uses this exact form.
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displayAsleep = true
                    self?.updateLiveSync()
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displayAsleep = false
                    self?.updateLiveSync()
                }
            }
        ]
    }

    deinit {
        // This app runs for days; a timer that outlives its module compounds.
        liveSyncTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
    }

    /// Picks which player owns the notch when more than one is running.
    ///
    /// Rules, in order:
    /// 0. **Dedicated adapters outrank the system source, playing or paused.**
    ///    `SystemMediaAdapter` reports whatever owns the system session, which
    ///    includes a browser tab; without this a YouTube Music tab would take
    ///    the notch off a paused Spotify. It may only take over when neither
    ///    Spotify nor Music has anything at all. This deliberately overrides
    ///    rule 1 for that source: audible does not beat dedicated.
    /// 1. Between the two dedicated adapters, a source reporting *playing*
    ///    audio wins. Two players cannot both be audible for long, and the
    ///    audible one is what the user means.
    /// 2. Otherwise the incumbent keeps the notch, so a paused Spotify in the
    ///    background cannot stomp a paused Music the user is actually looking
    ///    at. This is the "never switch silently" rule from Phase 4 task 2.
    /// 3. A source losing content only clears the notch if it *held* it; the
    ///    notch then falls back to any other source that still has something.
    ///
    /// Before this existed the module was last-writer-wins, which was correct
    /// only because exactly one adapter was registered.
    private func shouldTakeOver(_ snapshot: NowPlaying?, from source: any MediaSource) -> Bool {
        // Rule 0, both directions: the system source waits for the dedicated
        // ones to be empty, and yields the moment either has something.
        if source is SystemMediaAdapter { return !dedicatedSourceHasContent }
        if snapshot?.hasContent == true, activeSource is SystemMediaAdapter { return true }

        if snapshot?.isPlaying == true { return true }
        guard let active = activeSource else { return snapshot?.hasContent == true }
        return active === source
    }

    private func handleUpdate(_ snapshot: NowPlaying?, from source: any MediaSource) {
        // Recorded before arbitrating, so `dedicatedSourceHasContent` answers
        // for the state including this update rather than the one before it.
        snapshots[source.sourceID] = snapshot?.hasContent == true ? snapshot : nil

        guard shouldTakeOver(snapshot, from: source) else { return }

        if activeSource !== source, snapshot?.hasContent == true {
            Self.logger.notice("Active media source -> \(source.sourceID, privacy: .public)")
        }

        if snapshot?.hasContent == true {
            activeSource = source
        } else if activeSource === source {
            // The owner went quiet. Promote whoever still has something —
            // republished, not just recorded: the other source has no reason
            // to emit again, so without this the notch blanks even though a
            // usable snapshot is sitting right here.
            if let next = fallbackSource(excluding: source) {
                activeSource = next
                Self.logger.notice(
                    "Active media source -> \(next.sourceID, privacy: .public) (owner went quiet)")
                adoptSourceExtras()
                handleUpdate(snapshots[next.sourceID])
                return
            }
            activeSource = nil
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
            shuffling = nil
            repeating = nil
            return
        }
        // Above the account guard, deliberately: the Web API owns Up Next
        // and the like, but the playback modes come from the scripting
        // interface for every Spotify user, connected or not. Below it they
        // would never mirror for a connected account.
        shuffling = active.shuffling
        repeating = active.repeating
        if active is SpotifyAdapter {
            guard !accountConnected else { return } // Web API path owns these
            setUpNext(nil)
            likedCurrent = active.favorite.value
        } else {
            setUpNext(active.upNext)
            likedCurrent = active.favorite.value
        }
    }

    // MARK: - Playback modes

    /// Whether shuffle and repeat apply to whoever owns the notch.
    ///
    /// Spotify only this task. Music's dictionary has the terms but they are
    /// unread here, and the system source's payload carries neither — so the
    /// controls are **absent** for those, not dimmed. A control that cannot
    /// act must not occupy space pretending it might.
    ///
    /// Reads the mirror, so the panel re-renders when a read changes it.
    var showsPlaybackModes: Bool {
        activeSource is SpotifyAdapter && shuffling != nil
    }

    var isShuffling: Bool { shuffling == true }
    var isRepeating: Bool { repeating == true }

    func toggleShuffle() {
        guard let on = shuffling else { return }
        activeSource?.setShuffling(!on)
        // Optimistic, onto the MIRROR, which is what redraws the glyph under
        // the click. The adapter made the same assumption internally; the
        // next modes read confirms both or corrects both.
        shuffling = !on
    }

    func toggleRepeat() {
        guard let on = repeating else { return }
        activeSource?.setRepeating(!on)
        repeating = !on
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
        // The visualiser's tap is whole-system, so it is gated on the player
        // the notch is actually showing: paused, stopped or empty means the
        // tap comes down rather than reacting to unrelated system audio.
        visualizer?.setPlaying(snapshot?.isPlaying == true)
        // This update can change which screen is showing — content arriving
        // or leaving, the full-lyrics takeover ending on a new track — so the
        // spectrum follows at every exit below.
        defer { updateSpectrumVisibility() }

        // Recompute the accent only when the artwork bytes actually change —
        // a 24x24 downsample pass, cheap, but not worth repeating per tick.
        if snapshot?.artworkData != accentSourceData {
            accentSourceData = snapshot?.artworkData
            artworkAccent = snapshot?.artworkData.flatMap(ArtworkColor.dominant(in:))
            artworkImage = snapshot?.artworkData.flatMap(NSImage.init(data:))
        }

        let hasPresence = snapshot?.hasContent == true
        let presenceFlipped = hasPresence != hadPresence
        hadPresence = hasPresence
        // Expanded content can flip without presence flipping — the
        // permission banner appearing under an empty snapshot — and the open
        // panel has to move between chrome-only and the card on that too.
        // Presence already re-renders the panel, so only the remaining case
        // reflows: a play or stop never measures twice.
        let expandedFlipped = hasExpandedContent != hadExpandedContent
        hadExpandedContent = hasExpandedContent
        if presenceFlipped {
            onPresenceChange?()
        } else if expandedFlipped {
            onContentReflow?()
        }

        guard let snapshot, snapshot.hasContent else { return }
        let key = snapshot.artworkIdentifier ?? "\(snapshot.title ?? "")|\(snapshot.artist ?? "")"
        guard key != lastTrackKey else { return }

        lastTrackKey = key
        // Auto-announcing track changes (a 4s live-activity pop) shipped and
        // was experienced as a glitch — the notch "expands for a second and
        // goes back" uninvited. Off until it can be a designed banner; the
        // live-activity plumbing stays for whatever earns it next.

        // New track: leave the full-lyrics takeover and clear the old
        // lyrics — but deliberately WITHOUT reflowing. The area holds its
        // current height via `lyricsReserved` until the lookup resolves, so
        // the panel keeps its size across the change. Reflowing here is what
        // collapsed the notch out from under the cursor on every skip.
        showFullLyrics = false
        lyricsReserved = lyrics != nil
        lyrics = nil
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
        guard let artist = snapshot.artist, let title = snapshot.title else {
            // Nothing to look up, so the reservation would never be released
            // and the area would hold empty space forever.
            finishLyrics(nil, trackKey: trackKey)
            return
        }
        // Music can answer from its own `lyrics` property; Spotify cannot,
        // and returns nil here, sending the lookup straight to LRCLIB.
        let embedded = activeSource?.embeddedLyrics()
        lyricsService.fetch(
            artist: artist, title: title, duration: snapshot.duration, embeddedLRC: embedded
        ) { [weak self] lines in
            guard let self else { return }
            self.finishLyrics(lines, trackKey: trackKey)
        }
    }

    /// Applies a resolved lookup and reflows only if the lyric area's height
    /// actually changed.
    ///
    /// - lyrics -> lyrics: same height, no reflow (the common skip).
    /// - lyrics -> none: shrinks, so reflow. This is the honest "this track
    ///   has no lyrics" case the panel should resize for.
    /// - none -> lyrics: grows, so reflow. Growing is safe: the bottom edge
    ///   moves away from the cursor, never past it.
    private func finishLyrics(_ lines: [LyricsLine]?, trackKey: String) {
        guard lastTrackKey == trackKey else { return } // stale reply
        let occupiedBefore = lyricsOccupiesHeight
        lyrics = lines
        lyricsReserved = false
        if occupiedBefore != lyricsOccupiesHeight {
            onContentReflow?()
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

    /// The expanded view is on screen. Starts the live-sync clock, and lets
    /// the spectrum capture if the player is the screen showing. No pull
    /// here, because `AppleScriptRunner` is synchronous and an Apple Event
    /// per hover would land inside the expand animation. Push observation
    /// keeps the snapshot current in between.
    func didBecomeVisible() {
        isVisible = true
        liveSyncWanted = true
        updateLiveSync()
        updateSpectrumVisibility()
    }

    /// One pull from every player, plus the account extras.
    ///
    /// Sources observe by push and say nothing until playback changes, so
    /// without this a track already playing at launch would not put the
    /// wings up until the next skip. It is also what raises the one-time
    /// Automation prompt. It ran from `didBecomeVisible()` while visibility
    /// meant standby membership, which in practice fired once, at launch.
    private func pullSources() {
        sources.forEach { $0.refresh() }
        refreshAccountExtras()
    }

    // MARK: - Live sync

    /// Runs the clock iff the panel wants it and the display is awake.
    /// One decision point, so the two conditions cannot drift apart.
    private func updateLiveSync() {
        let shouldRun = liveSyncWanted && !displayAsleep
        guard shouldRun != (liveSyncTimer != nil) else { return }
        if shouldRun {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.liveSyncInterval,
                                             repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.liveSyncTick() }
            }
            // `.common`: the panel is open *because* the mouse is tracking,
            // and a `.default`-mode timer does not fire during tracking.
            RunLoop.main.add(timer, forMode: .common)
            liveSyncTimer = timer
            Self.logger.notice("Live sync started (\(Self.liveSyncInterval, privacy: .public)s)")
        } else {
            liveSyncTimer?.invalidate()
            liveSyncTimer = nil
            Self.logger.notice("Live sync stopped")
        }
    }

    /// One beat. Two skips, both cheap and both before any Apple Event:
    /// a source that is not Spotify has nothing this reads, and a paused
    /// player has a position that is not moving and modes that rarely
    /// change — they are read on the next play instead.
    private func liveSyncTick() {
        guard let spotify = activeSource as? SpotifyAdapter else { return }
        guard nowPlaying?.isPlaying == true else { return }
        spotify.refreshLive()
    }

    // MARK: - Spectrum

    /// Whether a screen draws the spectrum. Only the player does, and only
    /// with a duration: the spectrum lives in its progress row, which a track
    /// without one does not get (`NowPlaying.hasDuration`, the same test the
    /// row makes). The full-lyrics takeover and the permission banner replace
    /// the player without one. Pure, so the mapping is a test rather than a
    /// reading of `MediaExpandedView`.
    static func drawsSpectrum(on screen: ExpandedScreen?) -> Bool {
        guard case .player(let playing) = screen else { return false }
        return playing.hasDuration
    }

    /// Tells the visualiser whether its spectrum is on screen. Called wherever
    /// either input changes — visibility, and the screen showing — and the
    /// service ignores repeats, so calling it freely costs nothing.
    ///
    /// Deliberately not called from `notchDidCollapse()`: that runs while
    /// this module still counts as visible, so leaving the full-lyrics
    /// takeover there would briefly turn capture back on. The resign that
    /// follows it stops capture instead.
    private func updateSpectrumVisibility() {
        guard let visualizer else { return }
        visualizer.setSpectrumVisible(isVisible && Self.drawsSpectrum(on: expandedScreen))
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
            // Not asked again once refused. The 403 is a property of the
            // account, not of this track, so re-asking on every track change
            // would be a loop with extra steps — and each attempt is a
            // request that cannot succeed. `likedCurrent` stays nil, which
            // hides the heart outright rather than dimming a dead one.
            guard let self else { return }
            let liked: Bool? = if let trackID, !self.libraryForbidden {
                await webAPI.isSaved(trackID: trackID)
            } else { nil }
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

    /// Brings the Spotify app forward, and does nothing else.
    ///
    /// This activates Spotify — permitted because it is a direct response to
    /// the user tapping the artwork, not a hover (hard rule 4 protects
    /// against hover-stealing).
    ///
    /// **Deliberately not a navigation.** It previously opened a
    /// `spotify:` URI — the playback context when the Web API had supplied
    /// one, the track otherwise — which made the same tap land somewhere
    /// different depending on whether an account happened to be connected,
    /// and could move the user off what they were looking at. Bringing the
    /// app forward is the one behaviour that is the same every time.
    ///
    /// Behaves like clicking Spotify in the Dock, which is stronger than
    /// activation in two ways that both matter here: it **launches** Spotify
    /// if it is quit, and it sends a reopen event if it is already running,
    /// which restores a window the user had minimised.
    /// `NSRunningApplication.activate()` does neither — against a minimised
    /// Spotify it brings forward an app with nothing on screen.
    func activateSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SpotifyAdapter.bundleID)
        else {
            Self.logger.error("Artwork tap: Spotify is not installed; nothing to open")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Captured rather than reached through `Self`: the handler runs off
        // the main actor.
        let logger = Self.logger
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            logger.error(
                "Artwork tap: could not open Spotify - \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggles the full-lyrics takeover. Pins the notch open while on.
    func toggleFullLyrics() {
        guard lyrics?.isEmpty == false else { return }
        showFullLyrics.toggle()
        updateSpectrumVisibility()
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
        // A 403 arriving mid-flight retires the control; the optimistic
        // value below must not be left behind as a heart nobody can change.
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
            guard let self else { return }
            if self.libraryForbidden {
                self.likedCurrent = nil
            } else if !accepted {
                self.likedCurrent = !target
            }
        }
    }

    func didResignVisible() {
        // Observation is push-based and stays on — that is how the collapsed
        // wings follow track changes. The one timer this module owns, the
        // live-sync clock, stops here (hard rule 9): behind the wings with
        // Spotify playing, it was an Apple Event every two seconds for a
        // playhead nobody could see.
        isVisible = false
        liveSyncWanted = false
        updateLiveSync()
        updateSpectrumVisibility()
    }
}
