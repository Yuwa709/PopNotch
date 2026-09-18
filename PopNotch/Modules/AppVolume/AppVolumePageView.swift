import AppKit
import SwiftUI

/// The mixer page: one row per app that has played audio this session, with
/// a volume slider each. Composed by the coordinator, the way the stats
/// page is (v1 plan, decision 2).
///
/// **Spotify's and Music's rows work now; every other slider is inert.**
/// Those two use the player's own AppleScript `sound volume` (decision 3),
/// which needs no tap engine, and their rows share state with the player
/// screen's slider through `ScriptedPlayerVolumes` — moving one moves the
/// other. Every other row's slider is dimmed and disabled until the tap
/// engine (Phase 5). Never-tap apps show greyed with the reason instead of
/// a working slider (decision 9).
///
/// Fixed 420pt content width, the clipboard page's, so the two doors read
/// as one family. Height follows the row count up to eight rows, then the
/// list scrolls: the panel's 460pt ceiling minus the neck and padding
/// leaves ~388pt of content, and eight 40pt rows plus the header fill it.
struct AppVolumePageView: View {

    var service: AppVolumeService

    static let contentWidth: CGFloat = 420
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 6
    /// Past this many rows the list stops growing and scrolls instead.
    static let maxVisibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("APP VOLUME")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            let playing = service.mixerRows.filter(\.isPlaying).count
            if playing > 0 {
                Text("\(playing) playing")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = service.mixerRows
        if rows.isEmpty {
            Text("Nothing has played audio yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 88)
        } else {
            ScrollView(.vertical, showsIndicators: rows.count > Self.maxVisibleRows) {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(rows, id: \.owner.key) { row in
                        MixerRowView(row: row, players: service.playerVolumes)
                    }
                }
            }
            .frame(height: Self.listHeight(rowCount: rows.count))
        }
    }

    /// The list's height for a row count: exact up to `maxVisibleRows`,
    /// pinned there beyond. Pure so the eight-row cap is a test, not a
    /// hardware session.
    nonisolated static func listHeight(rowCount: Int) -> CGFloat {
        let visible = min(rowCount, maxVisibleRows)
        return CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * rowSpacing
    }
}

/// One app's row: icon, name and state caption, and the slider. A never-tap
/// row is greyed with its reason and a disabled slider — explained, not
/// broken-looking.
private struct MixerRowView: View {
    let row: MixerRow
    let players: ScriptedPlayerVolumes?

    /// Close to a never-tap row's whole-row 0.4, so every slider that does
    /// nothing reads the same.
    static let inertSliderOpacity: Double = 0.45

    /// The player that owns this row's volume, when it is Spotify or Music
    /// and the media module is on. Nil means the tap-engine path, inert
    /// until Phase 5.
    private var scriptedPlayer: ScriptedPlayerVolumes? {
        guard let players, row.neverTapReason == nil,
              players.handlesVolume(for: row.owner.key) else { return nil }
        return players
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(owner: row.owner)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.owner.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            if let scriptedPlayer {
                ScriptedVolumeSlider(bundleID: row.owner.key, players: scriptedPlayer)
            } else {
                // Inert until Phase 5, and drawn that way: disabled and
                // dimmed, so it does not look like the working Spotify and
                // Music sliders beside it. A never-tap row is already
                // dimmed whole, so its slider takes no second dimming.
                Slider(value: .constant(1.0))
                    .controlSize(.small)
                    .disabled(true)
                    .opacity(row.neverTapReason == nil ? Self.inertSliderOpacity : 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: AppVolumePageView.rowHeight)
        .opacity(row.neverTapReason == nil ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.owner.name), \(caption)")
    }

    private var caption: String {
        if let reason = row.neverTapReason { return "Not adjustable — \(reason)" }
        return row.isPlaying ? "Playing" : "Not playing"
    }
}

/// A working slider for Spotify or Music: their own `sound volume`, read
/// and written through the media module so it is the same value as the
/// player screen's slider. A drag is one edit — the module thins the
/// writes (each is a ~17ms Apple Event) and sends the release unthrottled.
/// Disabled while the volume is unknown (never read, or the read failed):
/// a thumb at a guessed position would claim a level nobody read.
private struct ScriptedVolumeSlider: View {
    let bundleID: String
    let players: ScriptedPlayerVolumes

    var body: some View {
        let known = players.volume(for: bundleID)
        Slider(value: Binding(
                   get: { Double(known ?? 100) / 100 },
                   set: { players.setVolume(PlayerVolume.value(atFraction: $0), for: bundleID) }),
               onEditingChanged: { editing in
                   if editing {
                       players.beginVolumeEdit(for: bundleID)
                   } else {
                       players.endVolumeEdit(for: bundleID)
                   }
               })
            .controlSize(.small)
            .disabled(known == nil)
            .accessibilityLabel("Volume")
            .accessibilityValue(known.map { "\($0) percent" } ?? "Unknown")
    }
}

/// The row's 20pt icon: the app's own icon where the owner is an app, a
/// globe for web content, a generic glyph for unbundled tools.
private struct AppIconView: View {
    let owner: AudioOwner

    var body: some View {
        Group {
            if let icon = AppIconStore.icon(for: owner) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: owner.kind == .webContent ? "globe" : "app.dashed")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// Icon lookups, cached per owner key: `urlForApplication` is a Launch
/// Services query and the rows re-render on every audio event.
@MainActor
enum AppIconStore {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for owner: AudioOwner) -> NSImage? {
        guard owner.kind == .app else { return nil }
        if let cached = cache[owner.key] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner.key)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[owner.key] = icon
        return icon
    }
}
