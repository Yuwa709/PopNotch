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
- Architectures: arm64 and x86_64

Never scaffold a Node, React, Vite, Electron, Tauri, or Python project in this repo. Never start a dev server. Never suggest running anything on localhost. If a task seems to call for a web technology, stop and ask first.

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

---

## Hard rules

1. **Never edit `PopNotch.xcodeproj/project.pbxproj` by hand.** If a file needs adding to the target, create the file and tell the user to add it in Xcode. Corrupting the project file costs a day.
2. **No third-party dependencies without asking.** No SPM packages, no CocoaPods, no Carthage. Apple frameworks only unless approved.
3. **Never change the notch panel's `level`, `collectionBehavior`, or `styleMask`** without explaining what you are changing and why. Those three properties are the entire reason the overlay works.
4. **Never add `NSApplication.shared.activate` or anything that steals focus.** Hovering the notch must never pull focus from the user's current app.
5. **No SwiftData, no Core Data.** Settings are a single `Codable` struct in UserDefaults. Notch data is live system state and is not persisted.
6. **No analytics, telemetry, or network calls** except in explicitly network-based features (weather, lyrics).
7. **One feature per session.** If asked for something large, propose a breakdown first and wait for confirmation.

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
  Settings/            SwiftUI settings window
  Utilities/
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

## Permissions

Each needs an Info.plist usage string and a graceful denied path. Never crash when a permission is refused.

| Permission | Used for | Info.plist key |
|---|---|---|
| Calendar | upcoming events | `NSCalendarsUsageDescription` |
| Location | weather | `NSLocationUsageDescription` |
| Automation | music control via AppleScript | `NSAppleEventsUsageDescription` |
| Accessibility | window snapping (later phase) | requested at runtime |

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
2. Confirm which single task you are doing
3. Make the change
4. Build and fix errors until clean
5. State plainly what the user needs to look at to verify it, since you cannot see it
6. Do not commit unless asked


## Model selection

At the start of each session, state which model is running and
whether it fits the task. Recommend Fable for notch geometry,
window management, architecture, and the media adapter. Recommend
Sonnet for routine edits, small fixes, and straightforward API
plumbing. Say so before starting work, then wait for confirmation.
