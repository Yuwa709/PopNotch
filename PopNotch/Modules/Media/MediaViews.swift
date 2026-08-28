import SwiftUI

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

/// The open-notch view: artwork, title/artist, transport controls.
struct MediaExpandedView: View {
    let module: MediaModule

    var body: some View {
        if let playing = module.nowPlaying, playing.hasContent {
            HStack(spacing: 12) {
                ArtworkThumb(data: playing.artworkData, side: 48, corner: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playing.title ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(playing.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(minWidth: 70, alignment: .leading)
                controls(isPlaying: playing.isPlaying)
            }
            .foregroundStyle(.white)
        } else if module.permissionDenied {
            // The tested denied path: one line, no re-prompt loop.
            Text("Allow PopNotch in System Settings → Privacy → Automation")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func controls(isPlaying: Bool) -> some View {
        HStack(spacing: 10) {
            transportButton("backward.fill", size: 11) { module.send(.previousTrack) }
            transportButton(isPlaying ? "pause.fill" : "play.fill", size: 15) {
                module.send(.togglePlayPause)
            }
            transportButton("forward.fill", size: 11) { module.send(.nextTrack) }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Left wing: album art beside the housing.
struct MediaWingArtwork: View {
    let module: MediaModule

    var body: some View {
        ArtworkThumb(data: module.nowPlaying?.artworkData, side: 22, corner: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right wing: a small animated waveform while playing, still while paused.
///
/// Decorative for now — bars move on time, not on real amplitude; the honest
/// upgrade is Phase "real audio" behind its permission. The timeline pauses
/// itself whenever playback pauses, so nothing animates (and nothing ticks)
/// while music is stopped — and the view only exists while the wings do.
struct MediaWingWaveform: View {
    let module: MediaModule

    private static let barCount = 4

    var body: some View {
        let playing = module.nowPlaying?.isPlaying == true
        // No minimumInterval: the hint quantized updates to a visible stutter
        // (user-observed "5 to 10 FPS") in this borderless panel. Native
        // refresh is smooth, costs nothing measurable for four capsules, and
        // still pauses completely with playback.
        TimelineView(.animation(paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: 2.5, height: barHeight(time: t, index: index, playing: playing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barHeight(time: TimeInterval, index: Int, playing: Bool) -> CGFloat {
        guard playing else { return 4 }
        // User-tuned: slow and smooth. Two blended sines per bar — no
        // abs(), whose corner at zero reads as a harsh bounce — at gentle
        // frequencies, with a modest swing. 30fps so motion has no visible
        // stepping.
        let primary = sin(time * (3.1 + Double(index) * 0.6) + Double(index) * 2.1)
        let secondary = sin(time * 2.0 + Double(index) * 1.1)
        let level = 0.5 + 0.35 * primary + 0.15 * secondary   // 0...1, smooth
        return 5 + 7 * level                                   // 5...12pt
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
