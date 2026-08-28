# PopNotch

A native macOS utility that turns the camera notch into something useful. Hover the notch and it expands into a panel showing what's playing — artwork, transport controls, a scrubbable progress bar, time-synced lyrics — plus system stats. Move the cursor away and it disappears back into the bezel.

<!-- TODO(user): screenshot of the expanded notch over the bezel goes here.
     docs/screenshot.png — needs a human with eyes on the real display. -->

Built with Swift and SwiftUI, no web runtime, no Electron. The whole app idles under 1% CPU, because an overlay that costs you battery is worse than no overlay.

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

Right now, PopNotch is built from source (binary releases will be attached to GitHub Releases once they exist):

```bash
git clone <this repo>
cd PopNotch
./scripts/install.sh
open /Applications/PopNotch.app
```

`install.sh` builds the app, replaces any running copy, and installs to `/Applications`. Launch it yourself afterwards — that way macOS attributes the permission prompts to you.

### "Nothing happened when I opened it"

PopNotch is signed ad-hoc, not notarized (notarization needs a $99/year Apple Developer account, which this project doesn't have yet). If you downloaded a build rather than compiling it, macOS will block the first launch — and because PopNotch has **no Dock icon and no window**, a blocked launch looks like *nothing happening at all*. It's not broken:

1. Open **System Settings → Privacy & Security**.
2. Scroll down: you'll see *"PopNotch" was blocked to protect your Mac*.
3. Click **Open Anyway**, then confirm.

This is a one-time step per download. On macOS 15 and later the old right-click → Open trick no longer works; the System Settings route is the only one. Builds you compile yourself with `install.sh` don't hit this at all.

## Permissions it asks for, and why

| Permission | When | Why |
|---|---|---|
| **Automation** (Apple Events) for Spotify and/or Music | First time the notch opens with that player running | Reading the current track and controlling playback works over AppleScript. One system prompt per player. |

That's the complete list today. If you decline, the notch keeps working — the media widget hides or shows a one-line hint, and you can re-grant later in System Settings → Privacy & Security → Automation (the in-app **Permissions** settings pane shows current status and takes you there).

Nothing leaves your machine except the feature-essential requests: album artwork from the URL Spotify itself provides, lyrics lookups to LRCLIB (song title, artist, duration — nothing about you), and, only if you connect a Spotify account, calls to Spotify's official Web API. **No analytics, no telemetry, ever.** The source is public so you can check.

## Optional: connecting Spotify

Playback control needs no account. Connecting one adds Up Next, like/unlike from the notch, and artist info, via Spotify's **official** Web API with OAuth (PKCE).

You register your own (free) Spotify developer app for this: create one at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), add the redirect URI `http://127.0.0.1:7391/callback` exactly, and paste its Client ID into PopNotch's Spotify settings tab.

**Why your own app registration?** Spotify caps apps in development mode at **25 users**, so shipping one shared Client ID would stop working almost immediately. Registering your own means your usage counts only against you. The token stays in your Keychain; there is no server side.

## Known limitations

- **Spotify artwork requires the Automation permission.** Track metadata arrives without it (Spotify broadcasts it), but artwork is fetched via AppleScript.
- **Spotify's Web API extras cap at 25 users per registered app** (their development-mode limit) — which is why you bring your own Client ID, see above.
- **Pandora and YouTube Music are not supported.** They have no scriptable Mac app, and Apple gated the private framework that once made universal now-playing possible (macOS 15.4+). If Apple relents, the adapter slot is already there.
- **Lyrics coverage is whatever LRCLIB has.** Instrumentals and obscure tracks may show none; plain-text-only lyrics are treated as none, since the notch can't scroll untimed text.
- **Un-notarized.** See the Gatekeeper section above. Auto-updates (Sparkle) are planned but not wired yet, so updating means pulling and re-running `install.sh`.
- **The notch is the product.** External displays get a plain fallback strip, not the full experience.

## License

MIT. See [LICENSE](LICENSE).
