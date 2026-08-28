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
        if let playing = module.nowPlaying, playing.hasContent {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ArtworkThumb(data: playing.artworkData, side: 52, corner: 10)
                        // Soft outer glow, expanded state only (the tiny wing
                        // thumb stays flat). Two shadows: a tight warm halo
                        // plus a wide faint bloom.
                        .shadow(color: .mediaAccent.opacity(0.5), radius: 4)
                        .shadow(color: .mediaAccent.opacity(0.25), radius: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playing.title ?? "—")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(playing.artist ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    // Bounded: the panel sizes itself to measured content;
                    // an unbounded one-line title would balloon it.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                MediaProgressBar(module: module)
                controls(isPlaying: playing.isPlaying)
            }
            .frame(width: 296)
            .foregroundStyle(.white)
        } else if module.permissionDenied {
            // The tested denied path: one line, no re-prompt loop.
            Text("Allow PopNotch in System Settings → Privacy → Automation")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: 26) {
            transportButton("backward.fill", size: 13) { module.send(.previousTrack) }
            transportButton(isPlaying ? "pause.fill" : "play.fill", size: 18) {
                module.send(.togglePlayPause)
            }
            transportButton("forward.fill", size: 13) { module.send(.nextTrack) }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 26)
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
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 34)
    }

    private func track(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(Color.mediaAccent)
                    .frame(width: max(4, geo.size.width * fraction))
                    .shadow(color: .mediaAccent.opacity(0.6), radius: 4)
            }
            .frame(height: 4)
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
        HStack(spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                WaveBar(index: index, playing: playing)
            }
        }
        // Fixed height so bars grow around their center instead of pushing
        // the row's layout; intrinsic width so wing alignment places it.
        .frame(height: 14)
        // User-tuned on hardware: centered still read as sitting too far
        // right (screenshot-measured ~3-4pt), which also made the right
        // wing look wider than the left. Visual nudge only; no layout.
        .offset(x: -3)
    }
}

private struct WaveBar: View {
    let index: Int
    let playing: Bool

    @State private var lifted = false

    var body: some View {
        Capsule()
            .fill(Color.mediaAccent.opacity(0.95))
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
