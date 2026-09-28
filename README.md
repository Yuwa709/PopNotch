# PopNotch

A native macOS utility that turns the camera notch into something useful. Hover the notch and it expands into a panel showing what's playing — artwork, transport controls, a scrubbable progress bar, time-synced lyrics — plus system stats. Move the cursor away and it disappears back into the bezel.

<!-- TODO(user): screenshot of the expanded notch over the bezel goes here.
     docs/screenshot.png — needs a human with eyes on the real display. -->

Built with Swift and SwiftUI, no web runtime, no Electron. An overlay that costs you battery is worse than no overlay, so nothing samples in the background: system-stat polling stops entirely when the stats aren't on screen or the display is asleep, and playback updates arrive as notifications from the player rather than by polling it.

## What it does

- **Now playing** for **Spotify** and **Apple Music**: artwork, title, artist, play/pause/skip, scrubbing, and an artwork-derived accent color. Whichever player is actually playing owns the notch.
- **Time-synced lyrics**, resolved from the player itself when possible, then from [LRCLIB](https://lrclib.net). Tap for a full-screen lyrics view.
- **System stats**: CPU, memory, disk, GPU, battery.
- **Launch at login**, a hover-delay setting, and a Permissions pane that tells you honestly what's granted.

## Requirements

- A Mac with a camera notch: **MacBook Pro (2021 or later)** or **MacBook Air (2022 or later)**. It runs on any Apple Silicon Mac — on a notchless display you get a small fallback strip — but the notch is the point.
- **macOS 14.2 (Sonoma) or later.**
- Apple Silicon only. There is no Intel build; no Intel Mac has a notch.

## Install

Download the latest `PopNotch-<version>.dmg` from [Releases](https://github.com/Yuwa709/PopNotch/releases). PopNotch is signed ad-hoc and not notarized, so macOS blocks the first launch until you approve it:

1. Open the DMG and drag PopNotch to Applications.
2. Double-click PopNotch. macOS blocks it.
3. Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click **Open Anyway** next to the PopNotch notice.
4. Authenticate, then click **Open**. macOS only asks once.

This applies to the first install only. Updates through Sparkle (**Settings → About → Check for Updates**) don't repeat it, and PopNotch never checks for updates on its own.

If it doesn't go as above:

- **No Open Anyway notice?** It only appears after a launch attempt, and it isn't available indefinitely. Double-click PopNotch again, then reopen Privacy & Security.
- **"PopNotch is damaged" with no Open Anyway button?** On macOS 26 some unnotarized apps get this message instead. For that case only, run:

  ```bash
  xattr -cr /Applications/PopNotch.app
  ```

Because PopNotch has no Dock icon and no window, a blocked launch looks like nothing happening at all. It isn't broken; it's waiting for step 3.

### Building from source instead

```bash
git clone https://github.com/Yuwa709/PopNotch.git
cd PopNotch
./scripts/install.sh
open /Applications/PopNotch.app
```

`install.sh` builds the app, replaces any running copy, and installs to `/Applications`. Builds you compile yourself are never quarantined, so they skip the Open Anyway step entirely.

## Permissions it asks for, and why

| Permission | When | Why |
|---|---|---|
| **Automation** (Apple Events) for Spotify and/or Music | First time the notch opens with that player running | Reading the current track and controlling playback works over AppleScript. One system prompt per player. |

That's the complete list today. If you decline, the notch keeps working — the media widget hides or shows a one-line hint, and you can re-grant later in System Settings → Privacy & Security → Automation (the in-app **Permissions** settings pane shows current status and takes you there).

Nothing leaves your machine except the feature-essential requests: album artwork from the URL Spotify itself provides, and lyrics lookups to LRCLIB (song title, artist, duration — nothing about you). **No analytics, no telemetry, ever.** The source is public so you can check.

## Known limitations

- **Spotify artwork requires the Automation permission.** Track metadata arrives without it (Spotify broadcasts it), but artwork is fetched via AppleScript.
- **No Spotify account connection.** Earlier versions could connect a Spotify account for Up Next, likes and artist info, but Spotify caps that at 25 users, so it was removed. If you connected one, the old token may still sit in your login keychain; nothing reads it any more, and `security delete-generic-password -s com.techie.PopNotch -a spotify-refresh-token` removes it.
- **Pandora and YouTube Music are not supported.** They have no scriptable Mac app, and Apple gated the private framework that once made universal now-playing possible (macOS 15.4+). If Apple relents, the adapter slot is already there.
- **Lyrics coverage is whatever LRCLIB has.** Instrumentals and obscure tracks may show none; plain-text-only lyrics are treated as none, since the notch can't scroll untimed text.
- **Un-notarized.** See Install above; the first launch needs Open Anyway in Privacy & Security. Updates go through Sparkle and are **manual only** — PopNotch never checks on its own, so nothing phones home unless you press the button in Settings → About.
- **The notch is the product.** External displays get a plain fallback strip, not the full experience.

## License

MIT. See [LICENSE](LICENSE).
