# CLAUDE.md

## What this project is

PopNotch, by Techie. A native macOS menu bar utility that draws an interactive overlay around the MacBook camera notch. It expands on hover to show system stats and media controls.

**This is a native macOS app. It is not a web app.**

- Language: Swift 5.9+
- UI: SwiftUI, bridged to AppKit via `NSHostingView` where needed
- Windowing: AppKit (`NSPanel`, `NSScreen`, `NSTrackingArea`)
- Build system: Xcode project (`PopNotch.xcodeproj`)
- Bundle identifier: `com.techie.PopNotch`
- Logger subsystem: `com.techie.PopNotch`
- Minimum target: macOS 14.0
- Architecture: arm64 only. No Intel Mac has a notch, so `x86_64` is dead weight
- Platform: macOS only. Not iOS, not visionOS

Never scaffold a Node, React, Vite, Electron, Tauri, or Python project in this repo. Never start a dev server. Never suggest running anything on localhost. If a task seems to call for a web technology, stop and ask first.

### Build settings drift

The values above are the **intended** configuration. The Xcode project was scaffolded from the iOS multiplatform template and does not yet match. See the drift table in `PROJECT-CONTEXT.md`.

**Do not assume a setting is correct because this file says so.** When a setting matters to the task, read it out of `project.pbxproj` first:

```
grep -n "PRODUCT_BUNDLE_IDENTIFIER\|MACOSX_DEPLOYMENT_TARGET\|SUPPORTED_PLATFORMS\|SWIFT_VERSION\|ARCHS" PopNotch.xcodeproj/project.pbxproj
```

You cannot fix these yourself (hard rule 1). Report the mismatch and hand the user a precise Xcode checklist.

---

## Build and verify

Build:

```
xcodebuild -scheme PopNotch -configuration Debug -destination 'platform=macOS' build
```

List schemes if the above fails:

```
xcodebuild -list
```

Run the built app:

```
open ~/Library/Developer/Xcode/DerivedData/PopNotch-*/Build/Products/Debug/PopNotch.app
```

Read the app's logs (your main feedback channel beyond compiler errors):

```
log show --predicate 'subsystem == "com.techie.PopNotch"' --last 2m --info
```

**Always build after making changes.** Do not report a task complete without a clean build.

---

## What you cannot verify

You have no view of the screen. This app is defined by pixel positioning and animation feel, so you cannot confirm:

- Whether the panel sits correctly over the notch
- Whether an animation looks smooth or stutters
- Whether corner radii and spacing look right
- Whether hover feels responsive

For anything visual, make the change, build it, then explicitly ask the user what they see. Do not assume it worked.

To compensate, add `os.Logger` output at every state transition (panel expand, collapse, screen change, module activation). Then read it back with the `log show` command above. That gives you evidence instead of guesses.

**Log state transitions at `.notice`, never `.info`.** Learned the hard way: `.info` is memory-only — it lives in a ring buffer and is evicted within minutes, so by the time the user finishes a hardware test the evidence is gone. `.notice` persists to disk and survives. Use `.info`/`.debug` only for chatter that has no forensic value.

---

## Hard rules

1. **Never edit `PopNotch.xcodeproj/project.pbxproj` by hand.** If a file needs adding to the target, create the file and tell the user to add it in Xcode. Corrupting the project file costs a day.
2. **No third-party dependencies without asking.** No SPM packages, no CocoaPods, no Carthage. Apple frameworks only unless approved. One pre-approved exception: **Sparkle**, added in Phase 5 for auto-updates. Nothing else is pre-approved.
3. **Never change the notch panel's `level`, `collectionBehavior`, or `styleMask`** without explaining what you are changing and why. Those three properties are the entire reason the overlay works.
4. **Never add `NSApplication.shared.activate` or anything that steals focus.** Hovering the notch must never pull focus from the user's current app.
5. **No SwiftData, no Core Data.** Settings are a single `Codable` struct in UserDefaults. Notch data is live system state and is not persisted.
6. **No analytics, telemetry, or crash-phone-home, ever.** Network calls are allowed only in features that are inherently network-based, and only to the endpoint that feature needs: **weather** (Open-Meteo), **lyrics** (LRCLIB), **stocks** (Phase 6, provider TBD), **update checks** (Sparkle, Phase 5), and **Spotify album artwork** (the URL Spotify's scripting interface returns — decision recorded in `PROJECT-CONTEXT.md`). Adding a network call anywhere else requires an explicit decision recorded in `PROJECT-CONTEXT.md`.
7. **One feature per session.** If asked for something large, propose a breakdown first and wait for confirmation.
8. **Respect Reduce Motion.** Check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` before every spring or expand/collapse animation and fall back to an instant transition. The whole app is animation; ignoring this makes it unusable for the people who need the setting.
9. **Never poll on a fixed timer without a suspend path.** This app runs for days. Every timer must stop when the display sleeps, when the panel is collapsed and its module is not visible, or when the owning module is disabled.

---

## Architecture

```
PopNotch/
  App/                 entry point, AppDelegate, lifecycle
  Notch/               NotchPanel, geometry, hover, animation
  Core/                NotchModule protocol, arbiter, settings store
  Modules/             one folder per feature
    SystemStats/
    Media/
    Weather/
    Stocks/            Phase 6
  Settings/            SwiftUI settings window
  Utilities/
PopNotchTests/         unit tests (geometry, arbitration, settings migration)
```

### Module system

Every feature conforms to `NotchModule`. It declares a priority and provides a compact view and an expanded view. Features never reference each other directly and never touch `NotchPanel` directly. The arbiter owns the panel and decides what displays.

### Arbitration rules

- Live activities (music change, notification, file drop) temporarily take the notch
- Higher priority interrupts lower priority
- Equal priority queues
- A live activity yields after its timeout and the notch returns to default state
- Default state shows the compact views of enabled always-on modules

### Settings

One `Codable` `AppSettings` struct persisted to `UserDefaults` as JSON, with a `schemaVersion` field. Any change to its shape needs a migration path. Never wipe user settings silently.

---

## Code style

- Prefer `struct` over `class` unless reference semantics are required
- Use `@MainActor` on anything touching UI
- No force unwrapping (`!`) outside tests. Use `guard let`
- Every system API call that can fail must handle nil, including every IOKit call
- Keep views under 100 lines. Extract subviews
- Invalidate timers on deinit. This app runs for days at a time and leaks compound

---

## Testing

There is no test target yet. It is created in Phase 2 alongside the module system, because that is the first code worth testing.

Three things are testable without a screen, and are therefore the only things that get tests:

- **Geometry.** Given a mocked screen rect and safe-area insets, does the computed notch rect land where it should? Include the no-notch fallback and the external-display case.
- **Arbitration.** Given a sequence of module activations with priorities and timeouts, does the arbiter pick the right one? Pure logic, no AppKit.
- **Settings migration.** Every `schemaVersion` bump gets a test that loads the previous version's JSON and asserts nothing was dropped.

Do not write tests that assert on colors, animation curves, or pixel offsets. Those are user-verified, not machine-verified.

Run tests:

```
xcodebuild -scheme PopNotch -destination 'platform=macOS' test
```

---

## Performance budget

An always-running overlay that samples CPU and GPU is itself a CPU consumer. Targets, measured in Activity Monitor with the panel collapsed and idle:

- Under **1% CPU** at idle
- Under **80MB** resident memory
- Zero energy impact contribution when the display is asleep

If a change pushes past these, the sampling interval is wrong or a timer is not suspending. This is a correctness bug, not a nice-to-have.

---

## Permissions

Each needs an Info.plist usage string and a graceful denied path. Never crash when a permission is refused.

| Permission | Used for | Info.plist key |
|---|---|---|
| Calendar | upcoming events | `NSCalendarsUsageDescription` |
| Location | weather | `NSLocationUsageDescription` |
| Automation | music control via AppleScript | `NSAppleEventsUsageDescription` |
| Accessibility | window snapping (later phase) | requested at runtime |

**The project currently has no Info.plist.** It is built with `GENERATE_INFOPLIST_FILE = YES`, so none of these keys exist yet. Until an Info.plist is added to the target, a usage string must be supplied as an `INFOPLIST_KEY_*` build setting instead — which only the user can do, in Xcode.

Requesting a permission whose usage string is missing does not fail gracefully; the process is killed by the system. Before writing any code that triggers an authorization prompt, verify the key is present.

Every permission also needs a **denied** path that is tested, not assumed. The module hides itself or shows a one-line "permission needed" state. It never retries in a loop and never blocks the rest of the notch.

---

## Distribution configuration

Do not change these without asking.

- `LSUIElement` = `YES` in Info.plist (no Dock icon, background agent)
- Launch at login uses `SMAppService.mainApp.register()`. Do not use `SMLoginItemSetEnabled` or a LaunchAgent plist. Both are deprecated for this purpose
- Hardened Runtime enabled
- Add entitlements only when a feature requires one. Every unnecessary entitlement is a notarization risk

---

## Session protocol

1. Read this file
2. State which model is running and whether it fits the task (see below)
3. Confirm which single task you are doing
4. Make the change
5. Build and fix errors until clean
6. State plainly what the user needs to look at to verify it, since you cannot see it
7. Do not commit unless asked

### Never state a repo fact without checking it

Commit history, file presence, and build settings have been misreported in this project before. Run the command and quote the output. "The bundle ID is `com.techie.PopNotch`" is a claim about `project.pbxproj`, not about this file — go read it.

### Reference implementations

PopNotch is an original implementation. Several macOS overlay apps that solve the same problems are AGPL-3.0 licensed, and copying from them would force the entire app under AGPL permanently.

**Never open a reference implementation's source and write PopNotch code in the same session.** Read to understand a technique, close it, then write from the concept. Record what was learned and where in `REFERENCES.md`. This applies to you as much as to the user — do not paste source from another notch app into this repo, and do not reproduce it from memory.


## Model selection

At the start of each session, state which model is running and
whether it fits the task. Recommend Fable for notch geometry,
window management, architecture, and the media adapter. Recommend
Sonnet for routine edits, small fixes, and straightforward API
plumbing. Say so before starting work, then wait for confirmation.
