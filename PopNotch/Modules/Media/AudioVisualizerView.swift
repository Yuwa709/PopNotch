import SwiftUI
import AppKit

/// The 16-band spectrum, drawn where the four-dot wave indicator used to
/// sit: the expanded header's trailing edge, beside Up Next.
///
/// Center-line style: each bar grows symmetrically up and down from a
/// horizontal midline — the HStack's default center alignment does the
/// mirroring, so a bar's frame height is the whole effect. Tinted with the
/// artwork accent while one exists, neutral white otherwise.
struct AudioVisualizerBarsView: View {

    @Bindable var service: AudioVisualizerService
    /// Artwork accent; nil when nothing is playing or none was derived.
    let accent: Color?

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    /// Sized to the slot the wave indicator occupied (14pt tall) — this is
    /// an Up Next-corner accent, not a centrepiece.
    private static let maxHeight: CGFloat = 16
    /// Bars never vanish entirely: a 2pt tick keeps the midline legible as
    /// a visualiser during silence rather than an empty gap.
    private static let minHeight: CGFloat = 2

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        if service.isEnabled, service.lastError == nil {
            // Rendered whenever the feature is on and healthy. While the tap
            // is down — paused, stopped, nothing playing — the service has
            // already zeroed `bands`, so this rests at the silent baseline
            // instead of disappearing and re-flowing the header.
            bars
        } else if service.isEnabled, service.lastError != nil {
            // Enabled but not capturing: almost always the permission. A
            // hint beats sixteen dead bars pretending to listen.
            Text("Allow System Audio Recording")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
        }
    }

    private var bars: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<AudioVisualizerService.bandCount, id: \.self) { band in
                let magnitude = band < service.bands.count ? service.bands[band] : 0
                RoundedRectangle(cornerRadius: Self.barWidth / 2, style: .continuous)
                    .fill((accent ?? .white).opacity(0.42 + 0.58 * Double(magnitude)))
                    .frame(width: Self.barWidth,
                           height: Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(magnitude))
            }
        }
        // Fixed height so bars grow around their center instead of pushing
        // the row's layout — same trick the wave indicator used.
        .frame(height: Self.maxHeight)
        .shadow(color: (accent ?? .white).opacity(0.4), radius: 3)
        // Buffers arrive every ~22ms. A 60ms blend was interpolating across
        // nearly three of them, averaging away motion the data contained;
        // 30ms lets each buffer substantially arrive before the next, while
        // still avoiding visible stepping. Hard rule 8: instant under
        // Reduce Motion.
        .animation(reduceMotion ? nil : .linear(duration: 0.03), value: service.bands)
        .accessibilityLabel("Audio visualizer")
        .allowsHitTesting(false)
    }
}
