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
| `MACOSX_DEPLOYMENT_TARGET` | `14.2` | Raised from 14.0 on 2026-08-29. `@Observable` needs 14; **Core Audio process taps need 14.2**, and gating that one feature cost a type-erased `AnyObject` plus three casts for an OS that shipped in December 2023. Set at project level, so targets inherit rather than drifting apart — which is exactly what happened when only the app target was raised |
| `SDKROOT` / `SUPPORTED_PLATFORMS` | `macosx` | Not iOS, not visionOS |
| `ARCHS` | `arm64` | No Intel Mac has a notch |
| `SWIFT_VERSION` | `5.0` | Language mode, not compiler version. Valid values are 4.0, 4.2, 5.0, 6.0 — there is no 5.9 |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Required if notarization is ever added |
| `ENABLE_APP_SANDBOX` | `NO` | Sandbox is App Store only, and would block Apple Events to Music and Spotify — the primary feature |
| `INFOPLIST_KEY_LSUIElement` | `YES` | Background agent, no Dock icon |

Usage strings for Calendar, Location, and Apple Events are set as
`INFOPLIST_KEY_*` build settings, and `GENERATE_INFOPLIST_FILE = YES`
synthesizes the bundle's Info.plist at build time.

**There is also a real `PopNotch/Info.plist`, wired to the app target**, whose
contents are merged into the generated one. It was added for Sparkle and
currently holds `SUFeedURL`, `SUPublicEDKey`, and
`NSAudioCaptureUsageDescription`. This paragraph previously claimed no
Info.plist file existed, which is stale.

It exists because `INFOPLIST_KEY_*` **silently ignores keys Apple does not
know about**. Measured 2026-08-31: building with
`INFOPLIST_KEY_SUFeedURL=…` succeeded and the key was simply absent from the
built bundle. Sparkle's `SUPublicEDKey` has no programmatic override either —
`SUHost.publicEDKey` reads `objectForInfoDictionaryKey:` and no delegate hook
exists — so a real file is the only route for it. Custom, non-Apple keys go
in the file; Apple's own usage strings stay as build settings.

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

MediaRemote would have avoided this call entirely (it delivers artwork bytes), but it is caller-gated — see `docs/FINDINGS.md`.

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
| macOS 14.2 minimum | Modern SwiftUI without cutting off too many users. Every notch Mac can run it. Raised from 14.0 for Core Audio process taps |
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

### Verified property audit (executed 2026-08-28, macOS 26.5.2)

Every property in either adapter's query script, executed individually against the live app. **Verified** means the call returned a value that day; it is not a promise about future Spotify/Music builds. Re-run the audit when a query script changes or a player updates.

| App | Property | Result |
|---|---|---|
| Spotify | `player state` | ✅ `paused` |
| Spotify | `name of current track` | ✅ |
| Spotify | `artist of current track` | ✅ |
| Spotify | `album of current track` | ✅ |
| Spotify | `duration of current track` | ✅ milliseconds (`192933`) |
| Spotify | `player position` | ✅ seconds, fractional |
| Spotify | `artwork url of current track` | ✅ https URL |
| Spotify | `id of current track` | ✅ `spotify:track:…` URI |
| Spotify | `starred of current track` | ❌ **-10000**, unimplemented despite `access="r"` in the sdef. Removed in `83bd628`; must not return |
| Spotify | `popularity of current track` | ✅ (not in the query; verified during the starred bisect) |
| Spotify | `shuffling` | ✅ returned `false`, 2026-09-03. Read in its OWN script, never appended to the eight-field query — see `SpotifyAdapter.modesScript` |
| Spotify | `repeating` | ✅ returned `true`, 2026-09-03. **Boolean, not a three-state mode**: the dictionary exposes no off/all/one, so no third state can be rendered |
| Music | `player state` | ✅ `stopped` |
| Music | `shuffle enabled` | ✅ `false` |
| Music | `fixed indexing` | ✅ `false` |
| Music | `player position` (while stopped) | ✅ returns `missing value`, **not an error** — the parser must treat it as absent |
| Music | `current playlist` (while stopped) | -1728 while no track is targeted — a state error the adapter's `try` block already absorbs, not an implementation gap |
| Music | `name/artist/album/duration/persistent ID/favorited/index/artworks/lyrics of current track` | ⚠️ **UNVERIFIED.** Auditable only with a track playing or paused; at audit time Music was stopped and the library held zero tracks, and starting playback unattended was out of bounds. See `docs/BLOCKED.md` |

The unverified Music rows are exactly the class that produced the `starred` incident. Until they are executed live, treat the Music query as provisionally correct: it shipped, but its first real run against a playing track is the actual test.

### MediaRemote: resolved, not open

Measured on hardware 2026-08-27 and written up in `docs/FINDINGS.md`. Summary: the framework loads and every symbol resolves inside PopNotch, but `MRMediaRemoteGetNowPlayingInfo` returns an **empty dictionary** to the signed app while the same call from an Apple-signed `swift` CLI returns full data for the same track at the same instant. The macOS 15.4 restriction is caller-identity gating and it is live on 26.5. The gating entitlement is private and not grantable.

This question is closed. Do not reopen it on the strength of another app appearing to have now-playing working — that observation is consistent with the Apple-signed-interpreter loophole (FINDINGS path 2), which is a different mechanism, not evidence that in-process MediaRemote works. Reopen only on a new **measurement** on a newer OS.

### What actually ships today (updated 2026-08-28, after 7667ad9)

Both promised adapters are registered in `AppDelegate`: `SpotifyAdapter` and `MusicAdapter`. The single-adapter world this section used to describe is gone.

- **Source arbitration exists and is the routing rule.** `MediaModule.shouldTakeOver(_:from:)`: a source reporting *playing* audio always wins; otherwise the incumbent keeps the notch, so a paused background player cannot stomp the one the user is looking at; an owner going quiet hands off to another running source. Commands route to `activeSource`, not to "the first running player".
- **Capabilities are per source, forced by the dictionaries.** Music answers Up Next (playlist `index + 1`, refused under shuffle/fixed indexing/last-in-playlist) and a read-write `favorited` itself, with no network. Spotify answers neither over AppleScript — no queue class exists, and `starred` is unimplemented (see *One failing property kills the whole query* below) — so its Up Next and its editable like come from the optional Web API when an account is connected, and its favourite is absent otherwise.
- **Lyrics resolve player-first.** Music's own `lyrics` property when it parses as timed LRC, then LRCLIB `/api/get`, then `/api/search` disambiguated by duration (±2s). Cached to disk including misses.
- **New files join the target automatically.** The project uses Xcode's `PBXFileSystemSynchronizedRootGroup` — zero individual `.swift` references exist in `project.pbxproj` (verified by grep, 2026-08-28). Creating a file under `PopNotch/` or `PopNotchTests/` is sufficient; no Xcode add step, and hard rule 1's remedy never triggers for new files. The working-agreement item about verifying a file "was added in Xcode" predates this and survives only as: confirm a new test actually *ran* by name in the test output.

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

## Notch geometry baseline

Recorded 2026-09-06 at commit `2039c51` ("Add capybara assets, fix Assets.xcassets target membership"), plus the uncommitted capybara scrub-bar runner in the working tree. **Every number here is the shape as it stands *before* any capybara shape work** — the runner draws inside `MediaProgressBar` and does not touch `NotchShape`, `NotchPanel` or `NotchHoverView`. The one place the theme is visible below is the expanded height, recorded both ways so the delta is attributable.

This exists so a future change to `NotchShape` can be judged against a known-good state and reverted with confidence. Values are quoted from source and from the app's own `.notice` log on hardware; where a number is derived rather than observed, it says so.

### Reading the logged rects

`NotchPanel.setState` logs the **inflated** frame — the visible silhouette plus the hover halo. To recover the drawn rect: `x + 10`, `y + 10`, `width - 20`, `height - 10`. Both forms are given below; the halo is `NotchPanel.hoverMargin` (10pt, sides and bottom, never the top).

### 1. Shape constants

`NotchShape` (`PopNotch/Notch/NotchShape.swift`):

| Constant | Value | Line | Notes |
|---|---|---|---|
| `compactTopRadius` | 8 | 16 | Concave flare into the menu bar; matches the housing's own corner tightness |
| `compactBottomRadius` | 12 | 17 | Convex bottom corners |
| `expandedTopRadius` | 14 | 18 | Open card, measured against the Sapphire reference |
| `expandedBottomRadius` | 34 | 19 | Open card |
| `topRadius` (default) | `compactTopRadius` | 21 | Instance property |
| `bottomRadius` (default) | `compactBottomRadius` | 22 | Instance property |

Radii are clamped inside `path(in:)` (lines 25–26) so the collapsed exact-notch size stays drawable:
`topR = min(topRadius, rect.width / 4, rect.height / 2)`, and the same for `botR`. At the 176×32 housing this binds: `min(8, 44, 16) = 8` and `min(12, 44, 16) = 12`, so compact draws unclamped; a narrower rect would clamp on `width / 4` first.

Which pair applies is decided in `NotchOverlayView.body` (lines 137–142): `expanded = content != nil`, and the expanded radii are used only when `expanded && !chromeOnly`. Idle, compact and the chrome-only bar all draw with the compact pair — at neck height the 34pt bottom radius reads as a blob rather than a bar.

`NotchOverlayView` insets and bands:

| Constant | Value | Line | Notes |
|---|---|---|---|
| `neckHeight` (default) | 32 | 76 | The menu bar band the housing occupies. Supplied at runtime as `notchRect.height`, not the default |
| `contentSideInset` | 32 | 120 | The panel's visible side border. **Must stay in lockstep with `NotchCoordinator.measureExpandedContent`**, which hardcodes the same 32 |
| `accessorySideInset` | 24 | 130 | Chrome band, nearer the corners than the content column. Floored by the corner: `expandedTopRadius` is 14, so below ~20 a 24pt control lands in the curve and clips |
| `housingGutter` | 6 | 198 | Keep-out each side of the housing for the band clamp |

Content padding (lines 179–181): `.padding(.top, neckHeight + 20)`, `.padding(.horizontal, contentSideInset)`, `.padding(.bottom, 20)`. The hover halo is applied last (lines 188–189) as `.padding(.horizontal, hoverMargin)` and `.padding(.bottom, hoverMargin)` — the top stays flush with the screen edge.

`NotchPanel` placement constants (`PopNotch/Notch/NotchPanel.swift`):

| Constant | Value | Line | Notes |
|---|---|---|---|
| `leadingWingWidth` | 48 | 187 | Asymmetric on purpose — equal wings read right-heavy (user-confirmed twice) |
| `trailingWingWidth` | 44 | 188 | |
| `opticalCenterOffset` | −2 | 195 | The housing reads ~2pt left of geometric screen centre. Anything centring on the screen applies this to centre on the *housing* |
| `hoverMargin` | 10 | 202 | The halo. Sides and below only |
| `compactEdgeExtra` | 2 | 207 | Extra black beyond the wings per side; the wing slots are inset by the same amount, so widening it moves no content |
| `horizontalInset` (local) | 1.0 | 155 | Per-side undershoot inside `notchRect` |

### 2. Compact state, and how the housing is found

`NotchPanel.notchRect(on:)` (lines 126–166) derives the physical notch from the screen, never from a constant:

1. Requires `screen.safeAreaInsets.top > 0` **and** both `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`. Any of the three missing takes the notchless path.
2. The gap between the auxiliary areas is not guaranteed symmetric — on a 15" Air it measures 1pt wider on the right, visible as a 2px Retina overhang — so it symmetrises around `screen.frame.midX` using the **tighter** side: `halfWidth = min(center - leftArea.maxX, rightArea.minX - center) - 1.0`.
3. The 1.0 inset is a full point, not a half: AppKit snaps fractional window origins to integers, which silently shifts the panel off the computed rect. The rule is always undershoot — an edge inside the housing sits in the deadzone and is invisible; an edge outside paints live pixels.
4. `y = screen.frame.maxY - topInset`, `height = topInset`. The height *is* the safe-area inset, so it tracks display scale.

Measured on this machine, both scales this display has actually reported:

| Display scale | Auxiliary gap | `safeAreaInsets.top` | Notch rect (visible) |
|---|---|---|---|
| 1470 × 956 (default) | 646.0 … 825.0 | 32 | `{{647, 924}, {176, 32}}` |
| 1710 × 1112 (more space) | 751.0 … 960.0 | 38 | `{{752, 1074}, {206, 38}}` |

**Idle** is exactly the notch rect. Logged frame `{{637, 914}, {196, 42}}` → visible `{{647, 924}, {176, 32}}`.

**Compact** (`compactRect`, lines 209–217) hangs a wing off each side of the housing:
`x = notch.minX − 48 − 2`, `width = notch.width + 48 + 44 + 2×2`, y and height unchanged.
Logged frame `{{587, 914}, {292, 42}}` → visible `{{597, 924}, {272, 32}}`.

Relative to the physical notch: the compact panel starts 50pt to its left and ends 46pt to its right, at identical height — it never grows downward, so it costs menu bar coverage on both sides and nothing else. Relative to the screen: top edge flush with `screen.frame.maxY`, horizontally straddling `midX`.

**Notchless displays.** `notchRect` falls back to a 200 × 32 strip centred on `screen.frame.midX` and flush with the top, and logs `No notch on screen <name>; using fallback rect …` at `.notice`. Everything downstream keeps working because the fallback strip *is* the housing as far as the rest of the code is concerned — the coordinator derives `housingLocalRange` from it, so the chrome band still flanks a stand-in camera. Which screen is used at all is `ScreenPolicy.targetScreen()` (`PopNotch/Notch/ScreenPolicy.swift`): the built-in display always, even when an external monitor is primary; only in clamshell does it fall back to `NSScreen.main`, which is where the fallback strip actually shows up in practice.

### 3. Expanded state — measured

From `[NotchPanel] State expanded at …` on the 176×32 housing, 2026-09-06. Visible rects are the logged frames with the halo removed.

| What was showing | Logged frame | Visible rect | Visible size |
|---|---|---|---|
| Media playing, capybara theme **off** | `{{507, 681}, {452, 275}}` | `{{517, 691}, {432, 265}}` | **432 × 265** |
| Media playing, capybara theme **on** | `{{507, 665}, {452, 291}}` | `{{517, 675}, {432, 281}}` | **432 × 281** |

The theme costs exactly **+16pt of height and 0pt of width**, which is the runner (20) plus track (6) plus the 4pt that always sat under the track, less the 14pt row it replaced. Off reproduces the pre-capybara geometry exactly.

Same session, on the 206×38 housing (display at "more space", 13:56): frame `{{627, 831}, {452, 281}}` → visible `{{637, 841}, {432, 271}}`. Same 432 content width, 6pt taller neck, and the x differs purely because the housing centre moved — this is not a geometry drift.

Two further expanded sizes were observed on 2026-09-06 between 14:03 and 14:17 but are **not attributable from the logs alone**, because nothing logs which screen the panel is on:

| Logged frame | Visible rect | Visible size |
|---|---|---|
| `{{491, 659}, {484, 297}}` | `{{501, 669}, {464, 287}}` | 464 × 287 |
| `{{411, 513}, {644, 443}}` | `{{421, 523}, {624, 433}}` | 624 × 433 |

To attribute them, hover each destination and read `State expanded at` back — they are most likely a navigated screen and the full-lyrics takeover, but that is inference, not evidence, and it is not recorded here as fact.

**Not observed, and therefore not measured:**

- **Media idle / stats-only standby.** Never isolated in 24h of logs.
- **Chrome-only (no module has anything to show).** Never logged in 24h — `Expanded panel … chrome-only` fires only on a *change* of the flag, and the flag never flipped. Derived from the pure function with the group widths `ChromeOnlyRectTests` pins at 76/76: `bandMinWidth = 176 + 2 × (24 + 6 + max(76 − 2, 76 + 2)) = 392`, which beats `legacyMinWidth = 176 + (48 + 24) × 2 = 320`, so the bar is **392 × 32 visible at `{{537, 924}, {392, 32}}`** (frame `{{527, 914}, {412, 42}}`). Derived, not observed — confirm before relying on it.

One `.error` was logged during this window and is a real transient, not noise:

```
14:03:30  Overlay overflows the panel: fitting height 297.000000 > frame height 275.000000 in state expanded
```

The content grew to 297 while the frame was still the previous state's 275; the next `setState` one second later took the panel to 297. Worth knowing that this fires benignly during a reflow, so a future occurrence is not automatically the clipped-buttons bug returning.

### 4. The clamps, and where each is enforced

All in `NotchPanel.expandedRect(housing:contentSize:chromeOnly:chromeGroups:)` (lines 283–310), which is `nonisolated` and pure precisely so this is testable without hardware.

**Width** (line 292): `min(max(chromeOnly ? 0 : contentSize.width, minWidth), 690).rounded(.up)`

- Floor: `minWidth = max(legacyMinWidth, bandMinWidth(...))` (lines 286–288).
  - `legacyMinWidth = housing.width + (leadingWingWidth + 24) × 2` → 320 at a 176 housing.
  - `bandMinWidth` (lines 258–264) = `housing.width + 2 × (accessorySideInset + housingGutter + max(leading + opticalCenterOffset, trailing − opticalCenterOffset))` → 392 at 176 with 76/76 groups. Derived, not guessed: the optical offset pushes the housing off centre, so it *costs* clearance on one side and grants it on the other — the 4pt that a naive `housing + 2·max(group) + 2·inset` floor came up short by, silently clamping the leading group on the stats-only panel.
  - The floor covers **every** expanded state, not just chrome-only. Flooring only the bar put the shelf button back under the camera on the stats-only standby panel (photo-confirmed 2026-09-01).
- Ceiling: **690**, raised from 540 on 2026-08-30 for the shelf redesign — the reference layout puts the resting shelf at ~687pt at this display's 0.735 px-to-point scale.

**Height** (lines 293–303):

- Chrome-only: `height = housing.height` exactly — no downward growth. Width and placement are shared with every other expanded state, so bar↔card is a pure height change.
- Otherwise: `min(max(contentSize.height, housing.height + 56), 460).rounded(.up)`. Floor is 88 at a 32pt neck.
- Ceiling: **460**, raised from 300 — the lyrics takeover needs more, and clamping below the content's real height compressed it upward (badge slid under the bezel) and spilled it past the rounded silhouette, where the square window edge cut it into a hard box.

**Rounding** (lines 304–309): origin `x` is `.rounded()`, width and height `.rounded(.up)`. AppKit snaps fractional origins, which desyncs the computed and actual frames. `y = housing.maxY − height` keeps the top flush.

**Secondary clamps elsewhere:**

- `NotchShape.path` clamps both radii to `width / 4` and `height / 2` (lines 25–26).
- `NotchOverlayView.bandLayout` clamps each chrome group to `max(0, …)` (lines 234–242). The width floor above is derived so neither clamp can ever fire; `NotchCoordinator` logs at `.error` if one does, because that means the floor and `bandLayout` have drifted apart.
- `NotchPanel.setState` (lines 344–347) logs at `.error` if the overlay's `fittingSize.height` exceeds the frame it is being handed. SwiftUI does not complain on its own — `NSHostingView` centres an oversized root and shoves everything up under the screen edge silently, which is what let the chrome-only bar ship clipped.

### 5. Hover

**Tracking area** (`NotchHoverView.updateTrackingAreas`, lines 94–103): `rect: bounds`, `options: [.mouseEnteredAndExited, .activeAlways]`, rebuilt from scratch on every geometry change. Tracking areas do not follow a resized or moved window, and AppKit calls this on every change, so rebuilding here is what keeps it matched to the panel.

**How it differs from the drawn shape** — three ways, all deliberate:

1. It is the **inflated** frame, halo included: 10pt wider per side and 10pt lower than the silhouette, so the notch opens when the cursor gets near rather than dead-on. Transparent pixels do not capture clicks, so the halo steals nothing from the menu bar.
2. It is a **rectangle**; the silhouette is not. The concave top fillets and convex bottom corners are all inside the tracking rect, so the corners are hover-live but unpainted.
3. It is **inclusive at its edges**, where `NSRect.contains` is half-open on `maxY`. That disagreement is the subject of the top-edge guard below.

**Every guard, and the bug each prevents:**

| Guard | Line | Bug it exists to prevent |
|---|---|---|
| `enterDebounce = 0.35` | 28 | Passing traffic across the top of the screen opening the notch. 200ms let too much through; user-tuned |
| `exitGrace = 0.1` + verified exit | 29, 166–183 | The panel resizes under the cursor while animating, and AppKit fires spurious `mouseExited`. An exit only counts if the cursor is *really* outside 100ms later |
| `isInsideForExit` top-edge carve-out | 121–127 | `NSRect.contains` is half-open on `maxY` and this panel's top edge sits flush with the screen's. A cursor pinned to the top row read as outside in **every** state at **every** size — measured 2026-08-29: enter fired, panel expanded, verification agreed the cursor was outside, collapsed straight back, oscillating on a ~320ms cycle one pixel row from the top. The enter path uses the tracking area (inclusive); this test was exclusive. Closing that one-row disagreement is the whole fix — nothing is widened downward or sideways |
| Re-entry cancels a pending exit | 136–137 | A cursor that briefly clipped the edge collapsing the panel it never really left |
| Exit cancels a pending enter | 160–161 | A debounced enter firing after the cursor has already gone |
| `isDraggingOut` suppresses collapse | 64–69, 159 | A drag-out leaves the panel bounds *by design*; the normal exit rules would tear down the view that started the drag |
| `clearingShouldRearmCollapse` (true→false only) | 77–79 | The panel hanging open forever after a drag-out. Factored out and `nonisolated` so the re-arm is a test, not a reading of the `didSet` |
| `reevaluateHoverAfterFrameChange` | 204–212 | A resize stranding a stationary cursor outside with no `mouseExited` to say so — either the rebuilt tracking area never saw it enter, or its exit fired mid-animation and was judged spurious against the still-moving frame. The chrome-only bar makes this routine: media stopping under the cursor drops the panel from full card to neck |
| `registerForDraggedTypes([.fileURL])` | 85 | Registering for everything would open the notch on a text selection dragged across the menu bar |
| `draggingEntered` guard `!isDraggingOut` | 230 | A shelf-originated drag swapping the homepage for the chooser, destroying the AirDrop bar that was the drop target |
| `draggingExited` verified with the same carve-out | 251–260 | AppKit sends `draggingExited` to an outer destination the moment the drag descends into a nested one — measured **18ms** after `draggingEntered`, session still live. Believing it tore the chooser down exactly as the cursor reached a zone |
| `draggingEnded` belt-and-braces | 265–267 | A session that ends by dropping elsewhere, or is cancelled, may never send `draggingExited`; the notch would stay open until the pointer happened to leave |
| `isDragActive` one-shot | 270–271 | The exit path running twice when AppKit reports the ending both ways |
| `prepareForDragOperation` / `performDragOperation` → `false` | 281–283 | This view consuming a drop that belongs to the shelf's own zones, which sit above it once expanded |
| `deinit` cancels both work items | 214–217 | A timer firing into a deallocated view |

File drags open the notch through **the same** `beginEnter`/`beginExit` path as the pointer, not a parallel mechanism — that is what keeps the debounce, the exit verification and the top-edge fix applying identically to both. A tracking area sees only the pointer, and during a drag session AppKit delivers dragging messages instead of mouse-entered ones, so without this the panel stays shut and the shelf's drop zones are unreachable.

### 6. The expansion animation

Driven by `NSAnimationContext.runAnimationGroup` on `animator().setFrame` — the **window frame** animates, not the inner view. The hosting view and tracking area follow via autoresizing and `updateTrackingAreas`.

**Opening** is two explicit stages (`NotchPanel.setState`, lines 367–401):

| Stage | Duration | Curve | Target |
|---|---|---|---|
| 1 — overshoot | **0.21s** | `controlPoints(0.25, 0.90, 0.45, 1.0)` | `x − 4`, `width + 8`, `y − 5`, `height + 5` |
| 2 — settle | **0.13s** | `.easeInEaseOut` | the true target |

Total **0.34s**. The stages are explicit because window-frame animation *clamps overshooting timing curves* — a control-point y > 1 was silently flattened and the user never felt the bounce it promised. The sideways component is what makes opening read as blooming outward rather than just dropping down; user-tuned to half the first attempt's travel.

Stage 2 is guarded by `currentState == .expanded`, so a collapse landing between stages abandons the settle instead of yanking the panel back open. Completions use `MainActor.assumeIsolated` rather than `Task` — AppKit already invokes them on the main thread, and deferring a runloop turn makes the settle read as a hitch.

**Closing, and every compact/idle transition** (lines 402–412): a single **0.22s** pass on `controlPoints(0.30, 0.90, 0.55, 1.0)`, no bounce, so they read as tidy.

**Reduce Motion** (lines 359–365, hard rule 8): `setFrame(target, display: true)` immediately, no animation at all, logged as `State <label> (reduced motion) at …`.

**Content entrance** is separate from the frame animation: `RevealFromNotch` (`NotchShape.swift`, lines 259–276) runs `.easeOut(duration: 0.17)` over `scaleEffect` 0.55 → 1 anchored `.top`, opacity 0 → 1, and blur 14 → 0 standing in for motion blur. Deliberately **faster than the 0.34s expand**, so content is locked in before the silhouette is. It plays only when `reveal: true` is passed — the transition into expanded, never a content update mid-display.

**Haptic** (lines 353–355): `NSHapticFeedbackManager.defaultPerformer.perform(.alignment)` fires only on the transition *into* expanded, and only when the hand is on the trackpad (the system's own rule).

**Early-out** (line 357): `guard target != frame else { return }` — an unchanged frame animates nothing and logs nothing.

---

## Performance findings

### Idle CPU floor from the wing waveform (found and fixed 2026-09-13)

**Symptom.** Collapsed and paused, PopNotch idled at ~1.4% of one core on a fresh launch, but at 6–8% after any playback, and never came back down. Measured on a Release build with Time Profiler (on-CPU samples attributed by thread and call stack) and cross-checked with `ps` CPU-time deltas. `sample` was misleading here: the work is a short burst per frame on an otherwise waiting main thread, so its stacks looked idle.

**Cause.** The four `WaveBar` animations in the collapsed right wing (`MediaViews.swift`). Every play started `withAnimation(.easeInOut(…).repeatForever(…).delay(…))`. Pausing ran a second `withAnimation` to bring the bars to rest, which does not stop a `repeatForever` — the paused bar height was a constant, so nothing replaced the running repeat. SwiftUI kept evaluating it every display refresh on the main thread (~98% of the process's CPU): `CA::Transaction::commit → NSHostingView.layout → ViewGraphRootValueUpdater.render → AnimatorState.update → AnimatableFrameAttribute.updateValue`.

It accumulated as well as persisted — four more repeat animations per play:

| Play/pause cycles | 0 | 1 | 3 | 10 | then one panel open/close |
|---|---|---|---|---|---|
| Idle CPU, % of one core | 1.35 | 6.35 | 6.75 | 8.05 | 1.30 |
| Repeat-animation boxes in the heap | 0 | 4 | 12 | 40 | 0 |

Combining-animation boxes were absent after one cycle and present by the third. Timers, notification observers, subprocesses, process taps and aggregate devices stayed flat throughout, and the live-sync tick measured 0.00% while paused.

Opening and collapsing the panel rebuilds the wing views, which destroys the animations. That is why a single hover cleared the floor, and why measurements that never hovered between pausing and sampling saw it "never return to baseline".

**The comment was wrong.** `MediaWingWaveform`'s doc comment said the bars were "repeating Core Animation animations" that "run in the render server … at effectively zero CPU", and that "when playback pauses the animations are removed entirely; nothing runs". Both claims were false: these are SwiftUI animations ticked in-process on the main thread, and nothing removed them. The comment has been replaced.

**Fix.** `MediaWingWaveform` builds the animated bars only while playing. Pausing swaps in stateless resting bars at the same 4pt height, so the views that own the animations are destroyed rather than asked to stop. The playing appearance is unchanged. Not re-profiled after the change (by decision); awaiting on-screen verification.

**Rule.** A non-terminating SwiftUI animation cannot be stopped by animating its state back to rest — remove the view that owns it. And never describe a SwiftUI animation as running in the render server at no cost without a profile that shows it.

### Measured at the same time, not fixed

- **Visibility never resigns.** `NotchArbiter` treats membership of the standby list as "visible", and media and system-stats are always in it, so `didResignVisible()` never runs — zero calls under lldb across launch, play, open, collapse, pause and quit. The live-sync timer and the 2s `SystemStatsService` sampler therefore run for the life of the process, against hard rule 9. The sampler alone is ~1.1–1.3% of a core, dominated by `readDisk()` reading `volumeAvailableCapacityForImportantUsageKey`, a CacheDelete round trip every 2 seconds.
- **Release builds are coverage-instrumented.** The Release configuration resolves `CLANG_COVERAGE_MAPPING = YES`, and the shipped 1.0.6 binary carries `__llvm_prf_cnts` sections and 1,435 profile counters. It is not set in `project.pbxproj`; most likely it comes from the auto-generated scheme, since no `.xcscheme` is committed. A build-settings change, so the user's to make (hard rule 1).

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
| Which stock data provider, and does its license permit redistribution? | Start of Phase 6 | A provider that forbids redistribution blocks public release, not just the feature |
| At what download count does notarization become worth $99/year? | Revisit after first public release | Pick a number now so the decision is a trigger rather than a mood |
| Does PopNotch ever become a paid product? | Open | MIT permits it. Anyone may also fork the free version, which is the tradeoff MIT was chosen with |

Resolved and moved into the sections above: license (MIT), source visibility (public), notarization (no, for now), the full Phase 0.5 configuration drift, **whether MediaRemote is reachable** — measured, gated, closed — and **whether Apple Music ships in v1**: it shipped, in commit `7667ad9`, alongside the source-arbitration rule it forced. See the Media section and `docs/FINDINGS.md`.
