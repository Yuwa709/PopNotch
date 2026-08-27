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

---

## What this app is

A native macOS background agent that draws an interactive overlay around the MacBook camera notch. It expands on hover to show system stats and media controls.

Target user for v1: the developer. Ship it, use it daily, then widen.

---

## Settled technical decisions

| Decision | Rationale |
|---|---|
| Native Swift, not Electron or Tauri | The app is a window-management problem. A web runtime cannot draw a non-activating panel above the menu bar, and shipping Chromium for an always-running overlay costs 150MB+ and 100-200MB RAM |
| SwiftUI with AppKit interop | SwiftUI for views, AppKit for everything about the window itself |
| No SwiftData, no Core Data | Settings are one `Codable` struct in UserDefaults. Notch data is live system state and is not persisted |
| No third-party dependencies | Apple frameworks only, unless explicitly approved. Sparkle at ship time is the expected exception |
| macOS 14.0 minimum | Modern SwiftUI without cutting off too many users |
| Module system before features | A dozen things compete for one small window. Arbitration must exist before there is anything to arbitrate |
| `LSUIElement = YES` | Background agent, no Dock icon |
| `SMAppService.mainApp.register()` for login | `SMLoginItemSetEnabled` and LaunchAgent plists are deprecated for this |

---

## Independent development

PopNotch is an original implementation. Some techniques were understood by reading publicly available macOS overlay implementations, several of which are AGPL-3.0 licensed. No code was copied.

**This matters and must stay true.** AGPL is strong copyleft: copying code in means the entire app must be published under AGPL. That closes off any future commercial option permanently.

The working rule: read reference implementations to understand a technique, close the file, write the implementation from the concept. Never have a reference source open while writing. Record techniques and where they were learned in `REFERENCES.md`.

---

## Constraints the assistant cannot work around

- **No visual verification.** This app is defined by pixel positioning and animation feel. Compiler success proves nothing about whether the panel is in the right place, whether the animation stutters, or whether hover feels responsive. For anything visual, build it and ask the user what they see.
- **`os.Logger` is the substitute.** Log every state transition (expand, collapse, screen change, module activation, computed geometry). Read it back with `log show --predicate 'subsystem == "com.techie.PopNotch"' --last 2m --info`. That turns guesses into printed values.
- **Permissions require the user.** Accessibility, Calendar, Location, and Automation all need manual approval in System Settings.
- **Never state repo facts without checking.** Run the command. Commit history and file presence have been misreported before.

---

## Working agreement

- One feature per session. Large asks get a proposed breakdown first, then wait for confirmation
- Commit before starting anything risky so `git reset --hard` is always available
- Verify a new file actually compiled into the target, not just that the build succeeded
- When a mistake gets corrected twice, that correction belongs in CLAUDE.md
- Model guidance: Fable for notch geometry, window management, architecture, and the media adapter. Sonnet for routine edits and straightforward API plumbing

---

## Open questions

- Whether MediaRemote access is currently viable on the target macOS version. Must be verified before Phase 4 design is finalized
- Whether PopNotch ever becomes a paid product. Affects licensing only. Clean-room discipline keeps the option open either way
