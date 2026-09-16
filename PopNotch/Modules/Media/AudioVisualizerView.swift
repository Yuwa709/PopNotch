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
        let reduceMotion = reduceMotion
        content
            // Hard rule 8. The bars do not animate themselves (see `bars`),
            // but a transaction inherited from an ancestor could still fade
            // the bars-to-hint swap or tween the shadow tint. Under Reduce
            // Motion, nothing in this view animates.
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
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
        // No implicit animation: each publish lands as it is. The bands
        // arrive already smoothed — attack instant, release shaped by
        // `AudioVisualizerService.barRelease` — so a view animation was a
        // second smoother on top. It was `.animation(.linear(duration: 0.03),
        // value: bands)`, and with ~47 publishes a second every update started
        // a new animation over one still running, on all 16 heights and 16
        // fill opacities. Removing it saved 7.6 points of a core by Time
        // Profiler (2026-09-16; PROJECT-CONTEXT.md, *Performance findings*).
        // Drawing the bars in one Canvas instead was also tried and measured
        // no cheaper by CPU time (8.5 points against 8.6), so they stay shapes.
        .accessibilityLabel("Audio visualizer")
        .allowsHitTesting(false)
    }
}
