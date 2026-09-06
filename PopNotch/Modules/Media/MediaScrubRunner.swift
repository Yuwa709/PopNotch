import SwiftUI

/// Geometry of the capybara-themed scrub bar, kept pure so the two things
/// the feature was specified with are tests rather than screenshots: the row
/// is exactly as tall as before when the theme is off, and the runner never
/// leaves the track.
enum MediaRunnerLayout {
    /// The track capsule.
    static let trackHeight: CGFloat = 6
    /// Space under the track: the untouched lower half of the original 14pt
    /// row, which centred the 6pt track with 4pt above and below.
    static let trackInset: CGFloat = 4
    /// The row as it has always been: 4 + 6 + 4.
    static let plainRowHeight: CGFloat = 14
    /// Drawn height of the walking capybara. Its feet land on the track top.
    static let runnerHeight: CGFloat = 20
    /// The asset is 25×16 at 1x; width follows from the height.
    static let runnerAspect: CGFloat = 25.0 / 16.0
    static var runnerWidth: CGFloat { runnerHeight * runnerAspect }

    /// Themed, the runner stands on the track and the row grows upward to
    /// hold it: runner + track + the 4pt that always sat under the track.
    static func rowHeight(themed: Bool) -> CGFloat {
        themed ? runnerHeight + trackHeight + trackInset : plainRowHeight
    }

    /// Leading edge of the runner for a playhead fraction. Centred on the
    /// playhead, clamped so it never overhangs either end of the track — at
    /// 0 its leading edge is at the start, at 1 its trailing edge is at the
    /// flag — and pinned to the start on a track narrower than itself.
    static func runnerOriginX(fraction: Double, trackWidth: CGFloat,
                              runnerWidth: CGFloat = runnerWidth) -> CGFloat {
        let travel = max(0, trackWidth - runnerWidth)
        let centred = CGFloat(fraction) * trackWidth - runnerWidth / 2
        return min(max(0, centred), travel)
    }
}

/// The walking capybara, static for now. Sized by height; width follows the
/// asset's aspect so nothing is stretched.
struct CapybaraRunnerView: View {
    var body: some View {
        Image(.capybaraWalk)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: MediaRunnerLayout.runnerHeight)
            .accessibilityHidden(true)
    }
}

/// A checkered finish flag at the end of the track, drawn from shapes: a
/// 1pt pole with a 4×3 grid of 2pt squares flying from its top back towards
/// the runner. White and translucent white rather than white and black —
/// the panel behind it is black, so black squares would simply vanish.
struct FinishFlagView: View {
    static let poleHeight: CGFloat = 12
    private static let square: CGFloat = 2
    private static let columns = 4
    private static let rows = 3

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<Self.rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            Rectangle()
                                .fill((row + column).isMultiple(of: 2)
                                      ? Color.white.opacity(0.95)
                                      : Color.white.opacity(0.3))
                                .frame(width: Self.square, height: Self.square)
                        }
                    }
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 1, height: Self.poleHeight)
        }
        .accessibilityHidden(true)
    }
}
