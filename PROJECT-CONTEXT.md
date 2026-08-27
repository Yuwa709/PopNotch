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

**It is currently wrong in the project file.** See the drift table below. Fix it now, while "destroys user settings" is hypothetical.

---

## Configuration drift

The Xcode project was scaffolded from the iOS multiplatform template and never converted to a Mac-only app. Everything in this repo's docs describes the intended state; the project file describes something else.

| Setting | Intended | Actual in `project.pbxproj` |
|---|---|---|
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.techie.PopNotch` | `Techie.PopNotch` |
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | `26.5` |
| `SWIFT_VERSION` | `5.9` | `5.0` |
| `SUPPORTED_PLATFORMS` | `macosx` | `iphoneos iphonesimulator macosx xros xrsimulator` |
| `TARGETED_DEVICE_FAMILY` | unset (macOS) | `1,2,7` |
| `ARCHS` | `arm64` | unset |
| `LSUIElement` | `YES` | absent — no Info.plist exists |
| Info.plist | present, with four usage strings | `GENERATE_INFOPLIST_FILE = YES`, no file |

`ENABLE_HARDENED_RUNTIME = YES` is already correct.

**The assistant cannot fix any of this.** Hard rule 1 forbids hand-editing `project.pbxproj`. The assistant's job is to detect the drift, report it, and hand over an exact Xcode checklist. Until this table is empty, treat every doc claim about build configuration as a claim to verify, not a fact.

The `26.5` deployment target is the most quietly dangerous entry: it silently makes every "does this API exist on macOS 14?" question moot, so availability bugs will not surface until the target is corrected.

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

Do not design around MediaRemote until someone has verified it on the actual target OS. That verification is a Phase 4 task, not an assumption.

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
- When a mistake gets corrected twice, that correction belongs in CLAUDE.md
- Model guidance: Fable for notch geometry, window management, architecture, and the media adapter. Sonnet for routine edits and straightforward API plumbing

---

## Open questions

Each needs an owner and a trigger, or it is not a question, it is a wish.

| Question | Resolve by | Why it matters |
|---|---|---|
| Is MediaRemote reachable on the current macOS version? | Before Phase 4 design is finalized | Determines whether Pandora and YouTube Music are ever possible |
| Which stock data provider, and does its license permit redistribution? | Start of Phase 6 | A provider that forbids redistribution blocks public release, not just the feature |
| Does PopNotch ever become a paid product? | Before Phase 5 licensing is chosen | Affects license file only. Clean-room discipline keeps both options open either way |
| What license ships with the public release? | Phase 5 | No `LICENSE` file exists yet. Shipping without one is its own problem |
| Is a privacy policy needed? | Phase 5 | Clipboard history, location, and calendar access all read as invasive without one, even though nothing leaves the machine |
