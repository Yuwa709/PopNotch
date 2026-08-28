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
    @ObservationIgnored private var accentSourceData: Data?

    @ObservationIgnored private let sources: [MediaSource]
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hadPresence = false

    var permissionDenied: Bool {
        sources.allSatisfy(\.permissionDenied)
    }

    init(sources: [MediaSource]) {
        self.sources = sources
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

        // New track: clear old lyrics (shrinking the open panel if showing)
        // and fetch this track's. The service caches, misses included.
        if lyrics != nil {
            lyrics = nil
            onContentReflow?()
        }
        fetchLyrics(for: snapshot, trackKey: key)
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
    }

    func didResignVisible() {
        // Observation is push-based with no timers, so it stays on — that is
        // how track changes can pop the notch while we are off screen.
    }
}
