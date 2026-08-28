# PopNotch Project Context

Decisions already made, and why. Read this before proposing an alternative approach to anything listed here. These are settled unless explicitly reopened.

---

## Identity

- App name: PopNotch
- Organization: Techie
- Bundle identifier: `com.techie.PopNotch`
- Logger subsystem: `com.techie.PopNotch`
- Repository root: `~/PopNotch`

The bundle identifier is baked into code signing, the UserDefaults suite, Keychain access, and the future update feed. Changing it after release destroys user settings. Treat it as permanent.

Set correctly in the project file as of Phase 0.5.

---

## Build configuration

Resolved in Phase 0.5, commits `dbd88ec` and `0a06545`. The project had been scaffolded from the iOS multiplatform template and never converted.

| Setting | Value | Why |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.techie.PopNotch` | Permanent. See Identity above |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | The floor, not the ceiling. Every notch Mac runs it, and `@Observable` needs 14 |
| `SDKROOT` / `SUPPORTED_PLATFORMS` | `macosx` | Not iOS, not visionOS |
| `ARCHS` | `arm64` | No Intel Mac has a notch |
| `SWIFT_VERSION` | `5.0` | Language mode, not compiler version. Valid values are 4.0, 4.2, 5.0, 6.0 — there is no 5.9 |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Required if notarization is ever added |
| `ENABLE_APP_SANDBOX` | `NO` | Sandbox is App Store only, and would block Apple Events to Music and Spotify — the primary feature |
| `INFOPLIST_KEY_LSUIElement` | `YES` | Background agent, no Dock icon |

Usage strings for Calendar, Location, and Apple Events are set as `INFOPLIST_KEY_*` build settings. There is no Info.plist file; `GENERATE_INFOPLIST_FILE = YES` synthesizes one at build time.

**Verify, do not assume.** The table above is a claim about `project.pbxproj`, not a fact guaranteed by this document:

```
grep -n "PRODUCT_BUNDLE_IDENTIFIER\|MACOSX_DEPLOYMENT_TARGET\|SUPPORTED_PLATFORMS\|ARCHS\|ENABLE_APP_SANDBOX" PopNotch.xcodeproj/project.pbxproj
```

Hard rule 1 normally forbids editing `project.pbxproj`. It was waived once, explicitly, for the Phase 0.5 conversion. It is back in force.

---

## Distribution

Settled. These replace what used to be open questions.

| Decision | Detail |
|---|---|
| Channel | Public GitHub repository, compiled builds attached to GitHub Releases |
| Not the Mac App Store | Which is why App Sandbox is off |
| License | MIT. `LICENSE` is in the repo |
| Source | Public. For a background agent touching clipboard, location, and calendar, visible source is most of the trust story |
| Notarization | **No**, for now |
| Signing | Ad-hoc. Apple Silicon requires a signature to run at all, and a Development certificate is valid only on machines registered to the developer's account |
| Updates | Sparkle, appcast in the repo. Its EdDSA signing is independent of Apple code signing and works un-notarized |

**On not notarizing:** the $99/year Apple Developer Program is not worth paying before anyone has asked for the app. The cost is that every user hits a Gatekeeper block and must approve PopNotch in System Settings → Privacy & Security. Because `LSUIElement` means no Dock icon and no window, a blocked launch looks like nothing happening at all — the README has to say so explicitly, or every first-time user concludes the app is broken. Revisit when downloads justify the cost; no code changes when that day comes.

---

## Network endpoint decisions (hard rule 6)

Rule 6 requires every added network call to be an explicit decision recorded here.

| Endpoint | Feature | Decided | Rationale |
|---|---|---|---|
| Spotify's artwork CDN, via the exact URL `artwork url of current track` returns | Media: album art for Spotify | 2026-08-27 | Spotify's scripting interface exposes artwork only as a URL (Apple Music hands over raw bytes; Spotify does not). Without the fetch, Spotify tracks have no thumbnail — the feature's centrepiece. Plain GET of an image Spotify itself designated; https enforced; fetched once per track and cached by URL. Nothing about the user is sent |

| accounts.spotify.com (`/authorize`, `/api/token`) + api.spotify.com (`/v1/tracks/{id}`, `/v1/artists/{id}`, `/v1/me/player`, `/v1/me/player/queue`, `/v1/me/tracks`, `/v1/me/tracks/contains`) | Media: Up Next, like/unlike, official artist metadata, playback context | 2026-08-28 | **Official** Web API only, authorized by the user via PKCE from Settings; refresh token in the Keychain. The private API Sapphire uses (Canvas, monthly listeners, play counts, free-tier ad skipping) is explicitly declined: it rides on reverse-engineered endpoints with the user's session and risks their account. Requests carry only Spotify's own OAuth tokens and track IDs. The redirect target is a loopback listener on `127.0.0.1:7391` — local, not a network call. `/v1/me/player` was added 2026-08-28 so tapping the artwork opens the playlist the user started from rather than the canonical album page; it needs `user-read-playback-state`, which the existing token already carries, so no re-authorization |
| lrclib.net (`/api/get`) | Media: time-synced lyrics | 2026-08-28 | Rule 6 pre-permits lyrics via LRCLIB but the decision was never recorded here; this row closes that gap retroactively. LRCLIB is free, keyless, and needs no account. The query carries artist, title, and track duration — song metadata, nothing identifying the user. Genius and Musixmatch are declined: both would mean scraping, and their lyrics are licensed |

MediaRemote would have avoided this call entirely (it delivers artwork bytes), but it is caller-gated — see `PopNotch/Modules/Media/FINDINGS.md`.

---

## What this app is

A native macOS background agent that draws an interactive overlay around the MacBook camera notch. It expands on hover to show media controls, system stats, and market data.

**Hardware requirement:** a Mac with a camera notch — MacBook Pro (2021 and later) or MacBook Air (2022 and later). All are Apple Silicon. A no-notch fallback strip exists so the app does not crash on other Macs, but they are not the target.

### Target user

- **v1:** the developer. Ship it, use it daily, then widen.
- **Eventually:** public release. This is a stated goal, not a maybe. It is why the clean-room discipline below is non-negotiable and why Phase 5 exists.

The order matters. Building for a hypothetical public user before using it yourself daily is the failure mode this roadmap is structured to prevent.

### What it is for, in priority order

1. **Media.** The primary feature. Now-playing artwork, title, artist, and transport controls.
2. **System stats.** CPU, memory, disk, GPU, battery at a glance.
3. **Stocks.** Sparkline graphs for a user-chosen watchlist.
4. **Everything else.** Weather, calendar, clipboard — nice, not load-bearing.

If a decision forces a tradeoff, media wins.

---

## Settled technical decisions

| Decision | Rationale |
|---|---|
| Native Swift, not Electron or Tauri | The app is a window-management problem. A web runtime cannot draw a non-activating panel above the menu bar, and shipping Chromium for an always-running overlay costs 150MB+ and 100-200MB RAM |
| SwiftUI with AppKit interop | SwiftUI for views, AppKit for everything about the window itself |
| No SwiftData, no Core Data | Settings are one `Codable` struct in UserDefaults. Notch data is live system state and is not persisted |
| No third-party dependencies | Apple frameworks only. Sparkle in Phase 5 is the single pre-approved exception |
| macOS 14.0 minimum | Modern SwiftUI without cutting off too many users. Every notch Mac can run it |
| arm64 only | No Intel Mac has a notch |
| Module system before features | A dozen things compete for one small window. Arbitration must exist before there is anything to arbitrate |
| `LSUIElement = YES` | Background agent, no Dock icon |
| `SMAppService.mainApp.register()` for login | `SMLoginItemSetEnabled` and LaunchAgent plists are deprecated for this |
| Media v1 is Apple Music + Spotify only | See below |
| Stocks are Phase 6, after media is stable | See below |

---

## Media: what is actually possible

The goal is every service — Spotify, Apple Music, Pandora, YouTube Music. The mechanisms do not currently exist to deliver that.

- **AppleScript** works for Music.app and Spotify.app. Both ship a scripting dictionary. Requires Automation permission. This is reliable and is what v1 ships.
- **Pandora and YouTube Music have no scriptable Mac app.** They are web properties. There is no AppleScript dictionary to talk to, and a browser tab is not an app you can send transport commands to.
- **MediaRemote**, the private framework, was the universal answer: now-playing state and transport control for anything producing audio, browsers included. Apple restricted it behind a private entitlement in macOS 15.4, breaking most third-party now-playing apps.

**Decision: v1 ships Apple Music and Spotify via AppleScript.** Pandora and YouTube Music are blocked, not cut. The `MediaSource` protocol exists precisely so that if MediaRemote becomes viable again — or a per-service API path is chosen — it costs one new file rather than a rewrite.

### One failing property kills the whole query

Recorded because it cost a debugging round and was invisible while it did.

`starred` appears in Spotify's dictionary as `access="r"`. It was verified there, added to the query script in `7667ad9`, and shipped. Against the live app it throws **-10000 (errAEEventFailed)** — Spotify declares the term but implements no handler.

The damage was disproportionate to the field. AppleScript evaluates the whole `return` expression as one unit, so a single failing property aborts it entirely: all nine fields were lost, not just `starred`. Album artwork is the only field whose sole producer is that script, so artwork silently stopped appearing while title, artist, album and position kept arriving over the permission-free distributed notification. The failure looked exactly like an Automation problem and was not one — `permissionDenied` stayed correctly false, so both the in-notch banner and the Permissions tab reported Spotify as healthy.

Three rules follow:

1. **Execute every new AppleScript property against the live app before it enters a query.** See the working agreement above.
2. **Keep query scripts minimal.** Every property added to a combined `return` is a new way to lose every other field in it. A field that is nice-to-have does not belong beside a load-bearing one.
3. **Never let an adapter failure be silent.** The `.failure` branch logged only `isPermissionDenied`, so a -10000 produced no adapter-level line at all. Every failure now logs with its code.

### MediaRemote: resolved, not open

Measured on hardware 2026-08-27 and written up in `PopNotch/Modules/Media/FINDINGS.md`. Summary: the framework loads and every symbol resolves inside PopNotch, but `MRMediaRemoteGetNowPlayingInfo` returns an **empty dictionary** to the signed app while the same call from an Apple-signed `swift` CLI returns full data for the same track at the same instant. The macOS 15.4 restriction is caller-identity gating and it is live on 26.5. The gating entitlement is private and not grantable.

This question is closed. Do not reopen it on the strength of another app appearing to have now-playing working — that observation is consistent with the Apple-signed-interpreter loophole (FINDINGS path 2), which is a different mechanism, not evidence that in-process MediaRemote works. Reopen only on a new **measurement** on a newer OS.

### What actually ships today

`SpotifyAdapter` is the only `MediaSource` in the target. **There is no Apple Music adapter yet**, so the sentence above describes the intent, not the build. Two things follow:

- Apple Music is the largest single gap between the plan and the app, and it is a Phase 4 completion task, not a new feature.
- Multi-source selection is unproven. `MediaModule.send(_:)` picks `sources.first { $0.isPlayerRunning }` and `handleUpdate` is last-writer-wins. With one adapter that is correct by accident. Adding Apple Music is what will expose it, so the rule from Phase 4 task 2 has to be written before the adapter, not after.

---

## Stocks

Not previously documented anywhere, now scheduled as **Phase 6**, after media is stable.

Open decisions, to be made when the phase starts:

- **Data provider.** Free tiers are heavily rate-limited and most prohibit redistribution, which matters for a public release. This is a licensing decision as much as a technical one.
- **Refresh policy.** Market hours only, backing off hard when closed. A ticker polling every 30 seconds at 2am is a bug.
- **Failure display.** Stale data must look stale. A price frozen from three hours ago rendered as current is worse than showing nothing.

Hard rule 6 in `CLAUDE.md` was amended to permit this network call. It is the only stocks-related permission granted so far.

---

## Independent development

PopNotch is an original implementation. Some techniques were understood by reading publicly available macOS overlay implementations, several of which are AGPL-3.0 licensed. No code was copied.

**This matters and must stay true.** AGPL is strong copyleft: copying code in means the entire app must be published under AGPL. That closes off any future commercial option permanently, and it is not reversible by deleting the code later.

The working rule: read a reference implementation to understand a technique, close the file, write the implementation from the concept. Never have a reference source open while writing. Record techniques and where they were learned in `REFERENCES.md`.

### On "it's basically a replica of Sapphire"

That framing is a liability and should be retired. Two different things get conflated:

- **Copying feature ideas is fine.** Nobody owns "show now-playing in the notch." Being inspired by what an app does is normal and legal.
- **Copying implementation is not.** Reproducing another app's source — including reproducing it from memory after reading it — is a derivative work regardless of how the variables get renamed.

Say "solves the same problems as Sapphire," never "replica of Sapphire." The word describes an intent that the clean-room rule exists to prevent, and written intent is exactly what matters if the question ever gets asked seriously.

This applies to the assistant too. If asked to "make it work like app X," the answer is to understand what X does and implement it independently — not to go read X's source.

### Competitive position (reviewed 2026-08-28)

A feature-by-feature analysis of Sapphire was compiled from its public marketing site and README. **That file stays out of this repo** — a dossier on another product sitting in the source tree is a bad paper trail for a project that may become commercial. What follows is the conclusion, which is ours, not theirs.

Standing rules that came out of it:

- **Their feature list is not our backlog.** Roughly fifteen advertised features, several marked Beta, one developer. Matching a list is how a solo project stalls. Hard rule 7 (one feature per session) is the defence and it is not negotiable because a competitor shipped something.
- **Marketing copy is not evidence.** Everything in that analysis is what an app *claims* on its own site. "Sapphire doesn't do X" means X is absent from a landing page, not absent from the app. Never plan around a competitor's gap as though it were measured.
- **Where PopNotch is actually different, and it is deliberate:** system-resource monitoring (CPU, memory, disk, GPU, battery) is the app's second pillar and is shipped. It does not appear anywhere in Sapphire's public material. Treat that as a likely opening, not a proven one.
- **Price and licence are a different game, not a worse one.** Sapphire is a subscription. PopNotch is MIT and free. Do not import feature decisions that only make sense with subscription revenue behind them — anything needing paid data feeds or LLM inference is out until PopNotch has a business model, and it does not have one.
- **Intel support is theirs, not ours.** They run on any Mac; `ARCHS = arm64` is settled here and stays settled. No notch Mac is Intel.
- **The clean-room line moved closer, so hold it harder.** Studying behaviour is fine and this is how it is done: their demo videos, their UI, their settings screens. Their source is off limits, including the directory structure inspection that analysis contains. Anything learned gets an entry in `REFERENCES.md` the same day.

---

## Constraints the assistant cannot work around

- **No visual verification.** This app is defined by pixel positioning and animation feel. Compiler success proves nothing about whether the panel is in the right place, whether the animation stutters, or whether hover feels responsive. For anything visual, build it and ask the user what they see.
- **`os.Logger` is the substitute.** Log every state transition (expand, collapse, screen change, module activation, computed geometry). Read it back with `log show --predicate 'subsystem == "com.techie.PopNotch"' --last 2m --info`. That turns guesses into printed values.
- **Permissions require the user.** Accessibility, Calendar, Location, and Automation all need manual approval in System Settings.
- **Build settings require the user.** Hard rule 1 means the assistant can read `project.pbxproj` but never write it. Every configuration fix is a handoff.
- **Never state repo facts without checking.** Run the command. Commit history, file presence, and build settings have all been misreported here before.

---

## Working agreement

- One feature per session. Large asks get a proposed breakdown first, then wait for confirmation
- Commit before starting anything risky so `git reset --hard` is always available
- Verify a new file actually compiled into the target, not just that the build succeeded. A file that exists on disk but was never added in Xcode builds clean and does nothing
- **An `sdef` proves vocabulary, not implementation.** A property can be declared in a scripting dictionary, with a type and an access level, and still have no working handler behind it. Before any new AppleScript property goes into a query script, **execute it against the live app** and read the result. `osascript -e 'tell application "X" to get <property> of current track'` is the whole test and it takes seconds
- When a mistake gets corrected twice, that correction belongs in CLAUDE.md
- Model guidance: Fable for notch geometry, window management, architecture, and the media adapter. Sonnet for routine edits and straightforward API plumbing

---

## Open questions

Each needs an owner and a trigger, or it is not a question, it is a wish.

| Question | Resolve by | Why it matters |
|---|---|---|
| Does an Apple Music adapter ship in v1, or is PopNotch a Spotify-first app that adds Music later? | Before Phase 4 is called done | Every doc here promises both. Only Spotify is built. Either write the adapter or change the promise — leaving it is the drift that made Phase 0.5 necessary |
| Which stock data provider, and does its license permit redistribution? | Start of Phase 6 | A provider that forbids redistribution blocks public release, not just the feature |
| At what download count does notarization become worth $99/year? | Revisit after first public release | Pick a number now so the decision is a trigger rather than a mood |
| Does PopNotch ever become a paid product? | Open | MIT permits it. Anyone may also fork the free version, which is the tradeoff MIT was chosen with |

Resolved and moved into the sections above: license (MIT), source visibility (public), notarization (no, for now), the full Phase 0.5 configuration drift, and **whether MediaRemote is reachable** — measured, gated, closed. See the Media section and `PopNotch/Modules/Media/FINDINGS.md`.
