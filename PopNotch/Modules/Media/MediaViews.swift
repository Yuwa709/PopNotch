import SwiftUI
import AppKit

extension Color {
    /// The media accent: a warm peach, user-chosen against the Sapphire
    /// reference. A future nicety could derive it from the artwork; for now
    /// it is deliberately fixed.
    static let mediaAccent = Color(red: 1.0, green: 0.72, blue: 0.52)
}

/// Every tunable governing lyric motion, in one place so feel can be retuned
/// without hunting through the file. Shared by the three-line ticker, the
/// full-lyrics page, and the zoom transition between them.
private enum LyricsMotion {
    /// Governs a line's own movement when the active index changes. One
    /// spring for both the ticker and the full page, so a line carries the
    /// same weight wherever it is shown.
    static let lineSpringResponse: Double = 0.30
    static let lineSpringDamping: Double = 0.86
    static var lineSpring: Animation {
        .spring(response: lineSpringResponse, dampingFraction: lineSpringDamping, blendDuration: 0)
    }

    /// Opacity lost per line of distance from the active one, floored at 0 —
    /// distance 1 reads at `1 - fadePerLine`, distance 2 at `1 - 2*fadePerLine`.
    /// Used only by the full lyrics page, which renders every line unwindowed
    /// (see its own doc comment for why that makes a continuous curve safe).
    static let fadePerLine: Double = 0.42
    /// The ticker's one visible neighbor (distance 1); distance 2 is always
    /// exactly 0 — see `MediaLyricsView.fadeOpacity`.
    static let tickerNeighborOpacity: Double = 0.35

    /// Size of an inactive line relative to the active one. Applied with
    /// `scaleEffect`, never a swapped font size — a font size change does not
    /// interpolate between values, a scale does.
    static let neighborScale: CGFloat = 0.85
    /// How much larger the active line grows on the full lyrics page, where
    /// there is room for it. The ticker has no equivalent boost; its active
    /// line is neighborScale's reciprocal effect alone (scale 1.0 vs 0.85).
    static let fullPageActiveScale: CGFloat = 1.22

    /// Vertical travel per line of distance, for the ticker only. Its lines
    /// are `lineLimit(1)`, so every row is the same height and a flat step is
    /// exact. The full page cannot use one — its lines wrap — so it measures
    /// instead; see `LyricsLayout`.
    static let tickerLineStep: CGFloat = 15

    /// Full page type size. Shared by the rendered `Text` and by the
    /// measurement that positions it — they must agree or every offset is
    /// computed for a line of a different height than the one drawn.
    static let fullPageFontSize: CGFloat = 20
    /// Blank space between the bottom of one full-page line and the top of the
    /// next, on top of each line's own measured height.
    static let fullPageLineGap: CGFloat = 12
    /// Clear space at each side of the full page, after the active line's
    /// scale is accounted for.
    static let fullPageSidePadding: CGFloat = 22
    /// Stands in when a line's height cannot be measured — an index off the
    /// end of the array, including the phantom "before the first timestamp"
    /// active line at -1.
    static let fullPageFallbackLineHeight: CGFloat = 24

    /// The home <-> full-lyrics screen swap.
    static let zoomTransitionDuration: Double = 0.38
}

/// Unused while the cross-screen morph is impossible (see
/// `MediaExpandedView.lyricsNamespace`). Kept beside the namespace it pairs
/// with so the two are re-adopted together, if ever.
///
/// A note for whoever revives this: it must NOT be applied to every line with
/// `isSource: distance == 0`. A non-source view's geometry is *set from* the
/// source's, so sharing one id across every line would collapse them onto the
/// active line's frame. Matching line-to-line across screens wants a per-line
/// id, each its own source.
private let activeLyricLineID = "activeLyricLine"

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

    /// **Currently inert — threaded through, used by nothing.** Kept only as
    /// scaffolding for a cross-screen morph that this architecture cannot
    /// support today.
    ///
    /// Investigated 2026-08-31: a `matchedGeometryEffect` needs both screens
    /// alive in one view tree within one transaction, and they never are.
    /// `toggleFullLyrics` reaches `NotchCoordinator.renderContent`, which
    /// calls `NotchPanel.setContent` and reassigns `hostingView.rootView`
    /// wholesale, rebuilding this view from a fresh
    /// `AnyView(MediaExpandedView(...))` each time. So this `@Namespace` is
    /// itself recreated on every swap — being declared in the parent rather
    /// than inside either screen buys nothing while the parent is rebuilt
    /// too. (Commit `ca3de5c` is independent evidence of that teardown: it
    /// had to add the `reveal:` guard because content swaps re-fired
    /// `RevealFromNotch`'s `onAppear`, which a preserved tree would not do.)
    ///
    /// Making the morph real means letting the panel's SwiftUI content own
    /// the swap instead of receiving pre-erased `AnyView`s from outside —
    /// the coordinator/panel seam, deliberately untouched.
    @Namespace private var lyricsNamespace

    var body: some View {
        // Group, not a bare switch, so `.animation(value:)` below applies to
        // whichever branch is showing rather than needing to be attached
        // separately to each one. The branch comes from the module's
        // `expandedScreen`, the same value the coordinator reads to decide
        // whether the panel opens chrome-only — the condition is not repeated
        // here.
        //
        // The `.transition`/`.animation` pair below cannot currently fire:
        // the swap arrives as a wholesale `rootView` reassignment from the
        // coordinator (see `lyricsNamespace` above), so this subtree is born
        // already showing the new branch rather than observing a change. Left
        // in place because it is correct in itself and is what the seam fix
        // would activate; it is not what makes the screens change today.
        Group {
            switch module.expandedScreen {
            case .fullLyrics:
                MediaFullLyricsView(module: module, namespace: lyricsNamespace)
                    .transition(.opacity)
            case .player(let playing):
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
                        // The four-dot wave indicator lived here; the real
                        // spectrum replaces it. (The compact wing keeps the
                        // wave — it is the collapsed-state indicator.)
                        if let visualizer = module.visualizer {
                            AudioVisualizerBarsView(service: visualizer,
                                                    accent: module.artworkAccent)
                        }
                    }
                }
                MediaProgressBar(module: module)
                MediaLyricsView(module: module, namespace: lyricsNamespace)
                controls(isPlaying: playing.isPlaying)
            }
            .frame(width: 368)
            .foregroundStyle(.white)
            .transition(.opacity)
            case .permissionDenied:
                // The tested denied path: one line, no re-prompt loop.
                Text("Allow PopNotch in System Settings → Privacy → Automation")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            case nil:
                // Nothing to show. The coordinator reads the same nil and
                // opens the panel chrome-only, so this is never seen below
                // the neck band.
                EmptyView()
            }
        }
        // Scoped to this one value: a track changing, artwork loading, or
        // anything else read inside this subtree must not also animate under
        // this spring. Both directions — opening and closing — go through
        // this same modifier watching the same boolean, so neither can drift
        // out of sync with the other the way two separately-wrapped
        // `withAnimation` call sites could.
        .animation(.easeInOut(duration: LyricsMotion.zoomTransitionDuration),
                  value: module.showFullLyrics)
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
    let namespace: Namespace.ID

    /// The area's full height, used both by the ticker and by the placeholder
    /// that holds the space while a lookup runs. One constant so the two can
    /// never disagree — a mismatch here would resize the panel by the
    /// difference and reintroduce the collapse this reservation prevents.
    static let reservedHeight: CGFloat = LyricsMotion.tickerLineStep * 3
    /// How many lines either side of the active one are rendered. Two, so a
    /// line has faded to nothing before it joins or leaves the ForEach.
    private let window = 2

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// nil under Reduce Motion makes the change instant (hard rule 8).
    /// Soft enough to read as a scroll, tight enough to settle inside the
    /// 0.5s timeline tick — beyond that the words drift behind the audio,
    /// which is the one thing this view cannot afford.
    private var scroll: Animation? {
        reduceMotion ? nil : LyricsMotion.lineSpring
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
    ///
    /// **One unconditional chain, deliberately.** A `@ViewBuilder` `if/else`
    /// here — used briefly to put `matchedGeometryEffect` on only the active
    /// line — compiles to `_ConditionalContent`, whose branches are distinct
    /// view types. A line crossing into or out of `distance == 0` then
    /// switched branches, so SwiftUI destroyed it and inserted a different
    /// view rather than animating the one it had; the default transition for
    /// that is a fade, which is what turned this ticker's roll into a
    /// cross-dissolve. Every line must keep exactly one identity for its
    /// whole life on screen, and its appearance must come only from
    /// modifiers whose values change.
    private func line(_ text: String, distance: Int) -> some View {
        let magnitude = abs(distance)
        // One font size scaled, never two sizes swapped: a font-size change
        // does not interpolate between values, a scaleEffect does.
        return Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(accent)
            .lineLimit(1)
            .scaleEffect(magnitude == 0 ? 1 : LyricsMotion.neighborScale)
            .opacity(fadeOpacity(magnitude: magnitude))
            .offset(y: CGFloat(distance) * LyricsMotion.tickerLineStep)
    }

    /// Two-step, not a continuous falloff: the ticker only ever shows
    /// `window` (2) lines either side, and the outermost of those MUST land
    /// on exactly 0 opacity, or a line silently joining/leaving the `ForEach`
    /// at the edge of that window would visibly pop in rather than fade in
    /// from nothing. The full-lyrics page renders every line unwindowed, so
    /// it uses a genuinely continuous falloff instead — see
    /// `MediaFullLyricsView.fadeOpacity`.
    private func fadeOpacity(magnitude: Int) -> Double {
        switch magnitude {
        case 0: 1
        case 1: LyricsMotion.tickerNeighborOpacity
        default: 0
        }
    }

    private var accent: Color { module.artworkAccent ?? Color.mediaAccent }
}

struct MediaFullLyricsView: View {
    let module: MediaModule
    let namespace: Namespace.ID

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
                MediaFullLyricsLines(lines: lines, module: module, namespace: namespace)
                    // Measured off the reference: its lyrics region is
                    // roughly 155pt, giving a ~280pt card rather than a
                    // 380pt slab.
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

/// The full-lyrics page's line stack.
///
/// Was a `ScrollViewReader` + `proxy.scrollTo(_:anchor:)` inside
/// `withAnimation`: `scrollTo` snaps to an anchor rather than travelling
/// continuously, which is why line changes read as a series of small jumps
/// rather than one roll. Replaced with the same technique
/// `MediaLyricsView`'s three-line ticker already used successfully: every
/// line has a stable identity (`.id(index)` — the array itself does not
/// reorder or get rebuilt mid-track, so index is a valid identity for the
/// duration of a track), and each line's vertical position is an `.offset`
/// computed purely from its distance to the active line, moved by one shared
/// spring. A spring interpolates every displayed frame regardless of how
/// often the driving state changes, so the motion is continuous even though
/// `active` itself only updates on the underlying `TimelineView`'s 0.5s tick.
///
/// Renders every line, unwindowed — unlike the ticker, which only builds a
/// `window` of lines around the active one. The ticker's window exists to
/// bound a ribbon that re-renders continuously; the full page is a few dozen
/// lines shown occasionally, so there is no cost to keeping all of them
/// present and letting offset and opacity carry the ones far from centre out
/// of view. That also removes the ticker's constraint that the edge of the
/// window must land on exactly zero opacity — nothing here ever joins or
/// leaves the `ForEach`, so the fade can be a genuinely continuous function
/// of distance instead of a two-step one.
/// The full lyrics page's vertical geometry, pulled out of the view so it can
/// be tested — it is exactly the "given sizes, does the position land where it
/// should" question CLAUDE.md says to test rather than eyeball.
///
/// The page cannot use a flat step per line the way the ticker does. Ticker
/// lines are `lineLimit(1)` so every row is identically tall; page lines wrap,
/// so a two-line lyric needs two lines of room. Positions here are therefore
/// cumulative sums of real measured heights.
enum LyricsLayout {

    /// Height the text will occupy once wrapped at `width`, unscaled.
    ///
    /// Measured through AppKit rather than a SwiftUI `GeometryReader` +
    /// `PreferenceKey`: this is synchronous, so the very first frame is
    /// already positioned correctly. The preference route only learns each
    /// height a layout pass *after* it is needed, which would stack every
    /// line at centre on open and spring them apart once the measurements
    /// landed.
    static func renderedHeight(of text: String,
                               wrappingAt width: CGFloat,
                               fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        // An empty lyric line (instrumental break) still occupies a row.
        let measured = text.isEmpty ? " " : text
        let bounds = NSAttributedString(string: measured, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// Centre-to-centre distance from the active line to `index`, positive
    /// downward.
    ///
    /// Half of each end line plus everything whole in between, so the active
    /// line's scale genuinely **pushes neighbours apart**: it enters the sum
    /// as `height * activeScale`, which `scaleEffect` alone could never do
    /// because it does not participate in layout at all.
    static func offset(for index: Int,
                       active: Int,
                       heights: [CGFloat],
                       activeScale: CGFloat,
                       gap: CGFloat,
                       fallback: CGFloat) -> CGFloat {
        guard index != active else { return 0 }
        let lower = min(index, active)
        let upper = max(index, active)

        func displayed(_ i: Int) -> CGFloat {
            // `active` is -1 before the first timestamp; that phantom row is
            // off the end of the array and takes the fallback, which keeps
            // line 0 sitting one slot below centre exactly as before.
            guard heights.indices.contains(i) else { return fallback }
            return heights[i] * (i == active ? activeScale : 1)
        }

        var distance = displayed(lower) / 2
            + displayed(upper) / 2
            + gap * CGFloat(upper - lower)
        if upper - lower > 1 {
            for j in (lower + 1)..<upper { distance += displayed(j) }
        }
        return index > active ? distance : -distance
    }
}

private struct MediaFullLyricsLines: View {
    let lines: [LyricsLine]
    let module: MediaModule
    let namespace: Namespace.ID

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var lineSpring: Animation? {
        reduceMotion ? nil : LyricsMotion.lineSpring
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
            // Same lookup the ticker uses (LyricsParser.currentIndex), not a
            // second hand-rolled `lastIndex` search — the two screens must
            // agree on which line is active down to the same index, or the
            // matchedGeometryEffect they share tries to morph between two
            // different lines the instant the takeover opens.
            let active = LyricsParser.currentIndex(at: elapsed, in: lines) ?? -1
            GeometryReader { geo in
                // Divided by the active scale, so the ONE line that gets
                // scaled still lands inside the panel: it wraps at this
                // width, then `scaleEffect` multiplies it back up to exactly
                // `geo.width - 2 * padding`. Every line wraps at the same
                // width, active or not — a width that changed with active
                // state would reflow the text mid-transition and change its
                // height under the spring.
                let wrapWidth = max(40, (geo.size.width - LyricsMotion.fullPageSidePadding * 2)
                                    / LyricsMotion.fullPageActiveScale)
                let heights = lines.map {
                    LyricsLayout.renderedHeight(of: $0.text,
                                                wrappingAt: wrapWidth,
                                                fontSize: LyricsMotion.fullPageFontSize)
                }
                ZStack {
                    ForEach(lines.indices, id: \.self) { index in
                        line(lines[index].text,
                             distance: index - active,
                             wrapWidth: wrapWidth,
                             offsetY: LyricsLayout.offset(
                                for: index,
                                active: active,
                                heights: heights,
                                activeScale: LyricsMotion.fullPageActiveScale,
                                gap: LyricsMotion.fullPageLineGap,
                                fallback: LyricsMotion.fullPageFallbackLineHeight))
                    }
                }
                // Fills the reader so the stack stays centred; GeometryReader
                // is top-leading by default.
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(lineSpring, value: active)
            }
        }
    }

    /// One unconditional chain — see `MediaLyricsView.line` for why a
    /// `@ViewBuilder` `if/else` here destroys and reinserts a line instead of
    /// animating it.
    private func line(_ text: String, distance: Int,
                      wrapWidth: CGFloat, offsetY: CGFloat) -> some View {
        let magnitude = abs(distance)
        // One base size scaled, never two sizes swapped — see
        // MediaLyricsView.line for why a scaleEffect is required here rather
        // than the old code's direct `size: index == currentIndex ? 25 : 20`.
        //
        // `.frame(width:)`, not `maxWidth: .infinity`: the scale below is
        // applied AFTER layout, so a line laid out at full panel width was
        // then multiplied past the panel's edges and clipped on both sides.
        // Wrapping at the pre-scaled width is what keeps it inside.
        return Text(text)
            .font(.system(size: LyricsMotion.fullPageFontSize, weight: .bold))
            .foregroundStyle(magnitude == 0
                ? (module.artworkAccent ?? .mediaAccent)
                : .white.opacity(0.28))
            .multilineTextAlignment(.center)
            .frame(width: wrapWidth)
            .scaleEffect(magnitude == 0 ? LyricsMotion.fullPageActiveScale : 1)
            .opacity(fadeOpacity(magnitude: magnitude))
            // Same animated offset under the same spring as before; only the
            // value it is given changed, from a flat step to measured.
            .offset(y: offsetY)
    }

    /// Continuous, unlike the ticker's two-step fade — safe here because
    /// nothing is windowed; see this type's own doc comment.
    private func fadeOpacity(magnitude: Int) -> Double {
        magnitude == 0 ? 1 : max(0, 1 - Double(magnitude) * LyricsMotion.fadePerLine)
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
