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
        // Intrinsic size only: the wing slot's alignment decides placement.
        ArtworkThumb(data: module.nowPlaying?.artworkData, side: 22, corner: 5)
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
    }
}

private struct WaveBar: View {
    let index: Int
    let playing: Bool

    @State private var lifted = false

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.85))
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
