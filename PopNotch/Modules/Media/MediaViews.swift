import SwiftUI

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
                        ArtworkThumb(data: playing.artworkData, side: 52, corner: 10)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playing.title ?? "—")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        Text(playing.artist ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    // Bounded: the panel sizes itself to measured content;
                    // an unbounded one-line title would balloon it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Trailing column, per the reference: up-next above the
                    // wave (their card sits in the same corner).
                    VStack(alignment: .trailing, spacing: 5) {
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
            // Like sits bottom-leading, where the reference keeps its
            // secondary actions. Only shown with a connected account.
            if module.accountConnected {
                HStack {
                    Button {
                        module.toggleLike()
                    } label: {
                        Image(systemName: module.likedCurrent == true ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(module.likedCurrent == true
                                ? (module.artworkAccent ?? .mediaAccent)
                                : .white.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
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
private struct MediaLyricsView: View {
    let module: MediaModule

    var body: some View {
        if let lines = module.lyrics, !lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
                let current = LyricsParser.currentLine(at: elapsed, in: lines)
                // Tapping the line opens the full-lyrics takeover.
                Button { module.toggleFullLyrics() } label: {
                    Text(current?.text ?? "♪")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(module.artworkAccent ?? Color.mediaAccent)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.25), value: current?.time)
            }
            .frame(height: 14)
        }
    }
}

/// The lyrics takeover: the whole notch becomes scrolling synced lyrics —
/// current line large in the accent, neighbours dimmed, auto-centered as
/// the song advances. A compact header keeps track identity and the way
/// back; the panel stays pinned open while this shows.
struct MediaFullLyricsView: View {
    let module: MediaModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { module.toggleFullLyrics() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                ArtworkThumb(data: module.nowPlaying?.artworkData, side: 26, corner: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(module.nowPlaying?.title ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(module.nowPlaying?.artist ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
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
                            VStack(spacing: 12) {
                                ForEach(lines.indices, id: \.self) { index in
                                    Text(lines[index].text)
                                        .font(.system(size: index == currentIndex ? 17 : 13,
                                                      weight: index == currentIndex ? .bold : .medium))
                                        .foregroundStyle(index == currentIndex
                                            ? (module.artworkAccent ?? .mediaAccent)
                                            : .white.opacity(0.35))
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .id(index)
                                }
                            }
                            .padding(.vertical, 60)
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
                .frame(height: 190)
                .mask(
                    // Fade the edges so lines melt in and out, per the
                    // reference screenshot.
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0),
                                .init(color: .black, location: 0.18),
                                .init(color: .black, location: 0.82),
                                .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .frame(width: 368)
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
