# PopNotch

A native macOS utility that turns the camera notch into something useful. Hover the notch and it expands into a panel showing what's playing — artwork, transport controls, a scrubbable progress bar, time-synced lyrics — plus system stats. Move the cursor away and it disappears back into the bezel.

<!-- TODO(user): screenshot of the expanded notch over the bezel goes here.
     docs/screenshot.png — needs a human with eyes on the real display. -->

Built with Swift and SwiftUI, no web runtime, no Electron. An overlay that costs you battery is worse than no overlay, so nothing samples in the background: system-stat polling stops entirely when the stats aren't on screen or the display is asleep, and playback updates arrive as notifications from the player rather than by polling it.

## What it does

- **Now playing** for **Spotify** and **Apple Music**: artwork, title, artist, play/pause/skip, scrubbing, and an artwork-derived accent color. Whichever player is actually playing owns the notch.
- **Time-synced lyrics**, resolved from the player itself when possible, then from [LRCLIB](https://lrclib.net). Tap for a full-screen lyrics view.
- **Up Next** from Apple Music's queue, or from Spotify with an optional account connection.
- **System stats**: CPU, memory, disk, GPU, battery.
- **Launch at login**, a hover-delay setting, and a Permissions pane that tells you honestly what's granted.

## Requirements

- A Mac with a camera notch: **MacBook Pro (2021 or later)** or **MacBook Air (2022 or later)**. It runs on any Apple Silicon Mac — on a notchless display you get a small fallback strip — but the notch is the point.
- **macOS 14.0 (Sonoma) or later.**
- Apple Silicon only. There is no Intel build; no Intel Mac has a notch.

## Install

Download the latest `PopNotch-<version>.dmg` from [Releases](https://github.com/Yuwa709/PopNotch/releases), drag PopNotch to Applications, then run this once:

```bash
xattr -cr /Applications/PopNotch.app
```

**That command is not optional.** PopNotch is signed ad-hoc and not notarized, so macOS quarantines the download and blocks the first launch. Because the app has no Dock icon and no window, a blocked launch looks exactly like nothing happening — see below if you skipped it. Clearing the quarantine attribute up front avoids the whole detour.

Then launch it yourself (`open /Applications/PopNotch.app`, or via Spotlight) — that way macOS attributes the permission prompts to you.

Updates after that are handled in-app: **Settings → About → Check for Updates**. PopNotch never checks on its own, and the update path clears quarantine for you, so `xattr` is a first-install step only.

### Building from source instead

```bash
git clone https://github.com/Yuwa709/PopNotch.git
cd PopNotch
./scripts/install.sh
open /Applications/PopNotch.app
```

`install.sh` builds the app, replaces any running copy, and installs to `/Applications`. Builds you compile yourself are never quarantined, so they skip the `xattr` step entirely.

### "Nothing happened when I opened it"

PopNotch is signed ad-hoc, not notarized (notarization needs a $99/year Apple Developer account, which this project doesn't have yet). If you downloaded a build rather than compiling it, macOS will block the first launch — and because PopNotch has **no Dock icon and no window**, a blocked launch looks like *nothing happening at all*. It's not broken:

```bash
xattr -cr /Applications/PopNotch.app
```

Then open it again. If you would rather not run a terminal command:

1. Open **System Settings → Privacy & Security**.
2. Scroll down: you'll see *"PopNotch" was blocked to protect your Mac*.
3. Click **Open Anyway**, then confirm.

Either way this is a one-time step per download. On macOS 15 and later the old right-click → Open trick no longer works. Builds you compile yourself with `install.sh` don't hit this at all, and neither do updates installed through Sparkle.

## Permissions it asks for, and why

| Permission | When | Why |
|---|---|---|
| **Automation** (Apple Events) for Spotify and/or Music | First time the notch opens with that player running | Reading the current track and controlling playback works over AppleScript. One system prompt per player. |

That's the complete list today. If you decline, the notch keeps working — the media widget hides or shows a one-line hint, and you can re-grant later in System Settings → Privacy & Security → Automation (the in-app **Permissions** settings pane shows current status and takes you there).

Nothing leaves your machine except the feature-essential requests: album artwork from the URL Spotify itself provides, lyrics lookups to LRCLIB (song title, artist, duration — nothing about you), and, only if you connect a Spotify account, calls to Spotify's official Web API. **No analytics, no telemetry, ever.** The source is public so you can check.

## Optional: connecting Spotify

Playback control needs no account. Connecting one adds Up Next, like/unlike from the notch, and artist info, via Spotify's **official** Web API with OAuth (PKCE).

There is nothing to configure: PopNotch ships its own Spotify Client ID, so connecting is one button in **Settings → Music**. (A Client ID is public information under PKCE — it identifies the app, not you, and there is no client secret anywhere in this app.)

Your token stays in your Keychain; there is no server side. **Note:** Spotify caps apps in development mode at **25 users**, so until PopNotch's registration is granted extended quota, connecting only works for accounts explicitly allowlisted on its Spotify dashboard. Everything else in the app works without connecting at all.

## Known limitations

- **Spotify artwork requires the Automation permission.** Track metadata arrives without it (Spotify broadcasts it), but artwork is fetched via AppleScript.
- **Spotify's Web API extras cap at 25 users** until the app's registration is granted extended quota (their development-mode limit), so Connect may fail for accounts that are not allowlisted. See above.
- **Pandora and YouTube Music are not supported.** They have no scriptable Mac app, and Apple gated the private framework that once made universal now-playing possible (macOS 15.4+). If Apple relents, the adapter slot is already there.
- **Lyrics coverage is whatever LRCLIB has.** Instrumentals and obscure tracks may show none; plain-text-only lyrics are treated as none, since the notch can't scroll untimed text.
- **Un-notarized.** See the Gatekeeper section above; first install needs `xattr -cr`. Updates go through Sparkle and are **manual only** — PopNotch never checks on its own, so nothing phones home unless you press the button in Settings → About.
- **The notch is the product.** External displays get a plain fallback strip, not the full experience.

## License

MIT. See [LICENSE](LICENSE).
