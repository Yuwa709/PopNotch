import SwiftUI
import AppKit

extension Color {
    /// The media accent: a warm peach, user-chosen against the Sapphire
    /// reference. A future nicety could derive it from the artwork; for now
    /// it is deliberately fixed.
    static let mediaAccent = Color(red: 1.0, green: 0.72, blue: 0.52)
}

/// Shown beside other modules in the collapsed/standby row.
struct MediaCompactView: View {
    let module: MediaModule

    var body: some View {
        if let playing = module.nowPlaying, playing.hasContent {
            HStack(spacing: 5) {
                ArtworkThumb(data: playing.artworkData, side: 14, corner: 3)
                Text(playing.title ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
        }
    }
}

/// The open-notch player: artwork and titles up top, a scrubbable progress
/// bar with elapsed/remaining times, transport controls beneath.
struct MediaExpandedView: View {
    let module: MediaModule

    var body: some View {
        if module.showFullLyrics {
            MediaFullLyricsView(module: module)
        } else if let playing = module.nowPlaying, playing.hasContent {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    // Tapping the artwork opens the track in Spotify.
                    Button { module.openInSpotify() } label: {
                        if let image = module.artworkImage {
                            // Ken Burns drift, palette glow, and parallax
                            // tilt. Slightly larger than the old flat thumb
                            // so the effects have room to read.
                            ArtworkVisualizerView(
                                image: image,
                                isPlaying: playing.isPlaying,
                                cornerRadius: 10
                            )
                            .frame(width: 60, height: 60)
                        } else {
                            ArtworkThumb(data: nil, side: 60, corner: 10)
                        }
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playing.title ?? "—")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            // Official artist avatar, when the account is
                            // connected and Spotify has one.
                            if let data = module.artistImageData, let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 15, height: 15)
                                    .clipShape(Circle())
                            }
                            Text(playing.artist ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        // Followers, labelled for what it is: the official
                        // API does not expose monthly listeners.
                        if let followers = module.artistInfo?.followers, followers > 0 {
                            Text("\(CountFormatter.short(followers)) followers")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.42))
                                .lineLimit(1)
                        }
                    }
                    // Bounded: the panel sizes itself to measured content;
                    // an unbounded one-line title would balloon it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Trailing column, per the reference: up-next above the
                    // wave (their card sits in the same corner).
                    VStack(alignment: .trailing, spacing: 5) {
                        // Popularity pill, where the reference puts its play
                        // count. Spotify's official 0-100 score, not plays.
                        if let popularity = module.trackPopularity {
                            HStack(spacing: 3) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 7, weight: .bold))
                                Text("\(popularity)")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.green.opacity(0.16)))
                        }
                        if let next = module.upNext {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("UP NEXT")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle((module.artworkAccent ?? .mediaAccent).opacity(0.9))
                                Text(next.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                Text(next.artist)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: 110, alignment: .trailing)
                        }
                        MediaWingWaveform(module: module)
                    }
                }
                MediaProgressBar(module: module)
                MediaLyricsView(module: module)
                controls(isPlaying: playing.isPlaying)
            }
            .frame(width: 368)
            .foregroundStyle(.white)
        } else if module.permissionDenied {
            // The tested denied path: one line, no re-prompt loop.
            Text("Allow PopNotch in System Settings → Privacy → Automation")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func controls(isPlaying: Bool) -> some View {
        ZStack {
            // Spacing and glyph sizes measured 1:1 off the reference.
            HStack(spacing: 56) {
                transportButton("backward.fill", size: 20) { module.send(.previousTrack) }
                transportButton(isPlaying ? "pause.fill" : "play.fill", size: 26) {
                    module.send(.togglePlayPause)
                }
                transportButton("forward.fill", size: 20) { module.send(.nextTrack) }
            }
            // Favourite sits bottom-leading, where the reference keeps its
            // secondary actions.
            HStack {
                MediaFavoriteControl(module: module)
                Spacer()
            }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Elapsed — track — remaining. The fill advances once a second while the
/// panel is open; dragging scrubs and releases into a seek. The 1s tick
/// exists only while this view does, i.e. only while the notch is expanded.
/// The favourite heart, in one of two modes decided by the *source*, not by
/// this view.
///
/// Apple Music's `favorited` is read-write, and Spotify's Web API can save a
/// track, so both of those are real toggles. Spotify's AppleScript `starred`
/// is read-only — with no connected account the value is knowable but not
/// changeable, so the heart renders as state rather than as a control and
/// takes no clicks at all. Offering a toggle there would be offering
/// something the scripting interface cannot do.
///
/// Hidden entirely when there is no value to show, which is what a denied
/// Automation prompt looks like. A greyed-out heart of unknown truth is
/// worse than no heart.
private struct MediaFavoriteControl: View {
    let module: MediaModule

    private var isOn: Bool { module.likedCurrent == true }

    private var tint: Color {
        isOn ? (module.artworkAccent ?? .mediaAccent) : .white.opacity(0.7)
    }

    var body: some View {
        if module.likedCurrent != nil {
            if module.canToggleFavorite {
                Button { module.toggleLike() } label: { heart }
                    .buttonStyle(.plain)
            } else {
                // Display-only: no Button, and hit testing off so the click
                // falls through to the panel instead of landing on a dead
                // control. Dimmed so it does not read as pressable.
                heart
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .accessibilityLabel(isOn ? "Starred" : "Not starred")
            }
        }
    }

    private var heart: some View {
        Image(systemName: isOn ? "heart.fill" : "heart")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

private struct MediaProgressBar: View {
    let module: MediaModule

    /// Artwork-derived (never black by construction), peach fallback.
    private var accent: Color { module.artworkAccent ?? .mediaAccent }

    /// Non-nil while the user is dragging: their finger owns the bar and
    /// live updates keep off it until release.
    @State private var scrubFraction: Double?

    var body: some View {
        let snapshot = module.nowPlaying
        let duration = snapshot?.duration ?? 0
        if duration > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = scrubFraction.map { $0 * duration }
                    ?? min(snapshot?.elapsedNow(at: context.date) ?? 0, duration)
                HStack(spacing: 8) {
                    timeLabel(format(elapsed))
                    track(fraction: duration > 0 ? elapsed / duration : 0, duration: duration)
                    timeLabel("-" + format(max(0, duration - elapsed)))
                }
            }
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 38)
    }

    private func track(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(accent)
                    .frame(width: max(6, geo.size.width * fraction))
                    .shadow(color: accent.opacity(0.6), radius: 4)
                // No playhead dot (tried, user-rejected); the whole track
                // drags, so the handle was decoration.
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubFraction = (value.location.x / geo.size.width).clamped01()
                    }
                    .onEnded { value in
                        let f = (value.location.x / geo.size.width).clamped01()
                        module.seek(to: f * duration)
                        // The adapter publishes the jump optimistically, so
                        // the bar holds position on release.
                        scrubFraction = nil
                    }
            )
        }
        .frame(height: 14)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension Double {
    func clamped01() -> Double { Swift.min(1, Swift.max(0, self)) }
}

/// The line being sung, under the progress bar in the accent — like the
/// reference design. Absent entirely (no reserved space) when the track has
/// no synced lyrics. The half-second tick exists only while this view does.
/// Lyrics as a three-line ticker: previous above, active centred, next below.
///
/// Why this is not three labels swapping text: every line is positioned by
/// its *distance* from the active index, so a single index change shifts
/// every line by exactly one step under one spring. Lines are only inserted
/// or removed two slots out, where opacity is already zero, so nothing
/// appears or vanishes on screen. That is what makes it read as one scroll
/// instead of three views changing content simultaneously.
private struct MediaLyricsView: View {
    let module: MediaModule

    /// One line height; the stack travels exactly this far per line change.
    private static let step: CGFloat = 15
    /// The area's full height, used both by the ticker and by the placeholder
    /// that holds the space while a lookup runs. One constant so the two can
    /// never disagree — a mismatch here would resize the panel by the
    /// difference and reintroduce the collapse this reservation prevents.
    static let reservedHeight: CGFloat = step * 3
    /// How many lines either side of the active one are rendered. Two, so a
    /// line has faded to nothing before it joins or leaves the ForEach.
    private let window = 2

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Soft enough to read as a scroll, tight enough to settle inside the
    /// 0.5s timeline tick — beyond that the words drift behind the audio,
    /// which is the one thing this view cannot afford. nil under Reduce
    /// Motion makes the change instant (hard rule 8).
    private var scroll: Animation? {
        reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.86, blendDuration: 0)
    }

    var body: some View {
        if module.lyrics?.isEmpty == false {
            ticker
        } else if module.lyricsReserved {
            // Holding the height, not showing anything: the outgoing track
            // had lyrics and the incoming track's lookup is still running.
            // Without this the panel shrinks and the notch collapses.
            Color.clear.frame(height: Self.reservedHeight)
        }
    }

    @ViewBuilder
    private var ticker: some View {
        if let lines = module.lyrics, !lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
                // -1 before the first timestamp, so the opening line sits one
                // slot below centre and scrolls up into it rather than
                // appearing already in place.
                let active = LyricsParser.currentIndex(at: elapsed, in: lines) ?? -1
                // Tapping anywhere in the ticker opens the full-lyrics takeover.
                Button { module.toggleFullLyrics() } label: {
                    ticker(lines: lines, active: active)
                }
                .buttonStyle(.plain)
                .animation(scroll, value: active)
            }
            .frame(height: Self.reservedHeight)
        }
    }

    private func ticker(lines: [LyricsLine], active: Int) -> some View {
        let lo = max(0, active - window)
        let hi = min(lines.count - 1, active + window)
        return ZStack {
            // Run-in before the first timestamp; fades out as the opening
            // line arrives at centre.
            Text("♪")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .opacity(active < 0 ? 1 : 0)

            if lo <= hi {
                ForEach(lo...hi, id: \.self) { i in
                    line(lines[i].text, distance: i - active)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// `distance` is signed: -1 is the line above, 0 the active one, +1 below.
    /// Offset, opacity and scale are all pure functions of it, so they move
    /// together off the same spring.
    private func line(_ text: String, distance: Int) -> some View {
        let magnitude = abs(distance)
        // One font size scaled, never two sizes swapped: a font-size change
        // does not interpolate between values, a scaleEffect does.
        return Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(accent)
            .lineLimit(1)
            .scaleEffect(magnitude == 0 ? 1 : 0.85)
            .opacity(magnitude == 0 ? 1 : (magnitude == 1 ? 0.35 : 0))
            .offset(y: CGFloat(distance) * Self.step)
    }

    private var accent: Color { module.artworkAccent ?? Color.mediaAccent }
}

struct MediaFullLyricsView: View {
    let module: MediaModule

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Song badge, top-left, matching the Sapphire reference: back
            // chevron, small artwork, then title / album / artist stacked.
            // Extra top clearance keeps it fully below the physical notch.
            HStack(alignment: .center, spacing: 9) {
                Button { module.toggleFullLyrics() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Button { module.openInSpotify() } label: {
                    ArtworkThumb(data: module.nowPlaying?.artworkData, side: 30, corner: 6)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.nowPlaying?.title ?? "")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    if let album = module.nowPlaying?.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Text(module.nowPlaying?.artist ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
            }

            if let lines = module.lyrics, !lines.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
                    let currentIndex = lines.lastIndex { $0.time <= elapsed + 0.2 }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            // Styled to the Sapphire reference: big bold
                            // wrapped lines, current in the accent, the rest
                            // dimmed, generous spacing.
                            VStack(spacing: 20) {
                                ForEach(lines.indices, id: \.self) { index in
                                    Text(lines[index].text)
                                        .font(.system(size: index == currentIndex ? 25 : 20,
                                                      weight: .bold))
                                        .foregroundStyle(index == currentIndex
                                            ? (module.artworkAccent ?? .mediaAccent)
                                            : .white.opacity(0.28))
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .id(index)
                                }
                            }
                            .padding(.vertical, 70)
                        }
                        .onChange(of: currentIndex) { _, newIndex in
                            guard let newIndex else { return }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                        .onAppear {
                            if let currentIndex {
                                proxy.scrollTo(currentIndex, anchor: .center)
                            }
                        }
                    }
                }
                // Measured off the reference: its lyrics region is roughly
                // 155pt, giving a ~280pt card rather than a 380pt slab.
                .frame(height: 160)
                .mask(
                    // Fade the edges so lines melt in and out, per the
                    // reference screenshot.
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0),
                                .init(color: .black, location: 0.16),
                                .init(color: .black, location: 0.84),
                                .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .frame(width: 400)
        .foregroundStyle(.white)
    }
}

/// Left wing: album art beside the housing.
struct MediaWingArtwork: View {
    let module: MediaModule

    var body: some View {
        // Intrinsic size only: the wing slot's alignment decides placement.
        // User-tuned: a minuscule up-and-right from center.
        ArtworkThumb(data: module.nowPlaying?.artworkData, side: 22, corner: 5)
            .offset(x: 2, y: -1)
    }
}

/// Right wing: a small animated waveform while playing, still while paused.
///
/// Decorative for now — bars move on time, not on real amplitude; the honest
/// upgrade is the audio-capture feature behind its permission.
///
/// Driven by repeating Core Animation animations, NOT per-frame SwiftUI
/// updates: this panel can never become key (hard rule 3), and SwiftUI
/// throttles TimelineView callbacks in non-key windows — two rounds of
/// user-visible stutter proved it. CA repeats run in the render server,
/// immune to that throttling, at effectively zero CPU. When playback
/// pauses the animations are removed entirely; nothing runs.
struct MediaWingWaveform: View {
    let module: MediaModule

    var body: some View {
        let playing = module.nowPlaying?.isPlaying == true
        let accent = module.artworkAccent ?? .mediaAccent
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                WaveBar(index: index, playing: playing, color: accent)
            }
        }
        // Fixed height so bars grow around their center instead of pushing
        // the row's layout; intrinsic width so alignment places it.
        .frame(height: 14)
        .shadow(color: accent.opacity(0.5), radius: 3)
    }
}

private struct WaveBar: View {
    let index: Int
    let playing: Bool
    let color: Color

    @State private var lifted = false

    var body: some View {
        Capsule()
            .fill(color.opacity(0.95))
            .frame(width: 2.5, height: playing ? (lifted ? 12 : 5) : 4)
            .onAppear { apply(playing) }
            .onChange(of: playing) { _, nowPlaying in apply(nowPlaying) }
    }

    /// Speed matches the user-approved tempo. Distinct duration and start
    /// delay per bar keep them from ever syncing up.
    private func apply(_ playing: Bool) {
        if playing {
            withAnimation(
                .easeInOut(duration: 0.45 + Double(index) * 0.08)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.13)
            ) {
                lifted = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                lifted = false
            }
        }
    }
}

/// Album art from raw bytes, or a placeholder note while it loads.
private struct ArtworkThumb: View {
    let data: Data?
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.45))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
