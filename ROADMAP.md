# PopNotch Roadmap

Phased build plan. Each phase ends with something installable and usable. If a phase ends with "the code compiles," the phase was scoped wrong.

Read this when starting a new phase. Do not read it for routine tasks.

---

## Current status

- **Phase 0:** complete (project created, git initialized, CLAUDE.md in place)
- **Phase 0.5:** not started — **blocking.** The Xcode project is still configured as an iOS multiplatform template
- **Phase 1:** in progress
  - `NotchPanel` class created, geometry computed, logging in place, builds clean
  - Not yet instantiated or displayed
- **Phases 2 and beyond:** not started

Update this section at the end of each phase.

---

## Phase 0.5: Make the project a Mac app

**Goal:** The build settings match what every doc in this repo claims they are.

**Risk: low effort, high consequence.** This is 20 minutes of clicking in Xcode that gets 10x more expensive after v0.1 ships.

**Owner: the user.** The assistant cannot edit `project.pbxproj` (hard rule 1). Its job here is to produce the checklist and verify the result by reading the file back.

### Tasks

1. **Bundle identifier** to `com.techie.PopNotch`. Currently `Techie.PopNotch`. Do this first and do it now — after release it destroys user settings and Keychain access.
2. **Deployment target** to macOS 14.0. Currently 26.5, which makes every availability check silently pass and hides bugs until you lower it.
3. **Supported platforms** to `macosx` only. Currently includes iOS, iOS Simulator, visionOS, and visionOS Simulator. Clear `TARGETED_DEVICE_FAMILY`.
4. **Architectures** to `arm64`. No notch Mac is Intel.
5. **Swift version** to 5.9.
6. **Add an Info.plist** to the target, with `LSUIElement = YES` and the four permission usage strings from the CLAUDE.md table. Without this the app shows a Dock icon and gets killed by the system the first time it requests Calendar access.
7. **Delete `ContentView.swift`** if it is still the template placeholder. It is not part of the architecture.

### Done when

`grep` over `project.pbxproj` matches the intended column of the drift table in `PROJECT-CONTEXT.md`, the app launches with no Dock icon, and the drift table is deleted from that file.

---

## Phase 1: Notch shell

**Goal:** An empty overlay that expands on hover, collapses on exit, survives display changes and fullscreen apps, and launches at login.

**Risk: high.** This is the make-or-break phase. Everything else plugs into it.

### Tasks

1. **NotchPanel class.** `NSPanel` subclass. `isOpaque = false`, clear background, no shadow, `styleMask = [.borderless, .nonactivatingPanel]`, `canBecomeKey` returns false, `hidesOnDeactivate = false`. Level one above `CGWindowLevelForKey(.mainMenuWindow)`. **Done.**
2. **Geometry.** Notch rect is the gap between `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX`, height `safeAreaInsets.top`, anchored to `screen.frame.maxY`. Fallback strip for screens without a notch. **Done.**
3. **Instantiate and display.** Create one panel at launch, `orderFront`. Set `collectionBehavior` to include `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`. Without these it vanishes on space switch and in fullscreen.
4. **Screen ownership policy.** Decide *before* writing the code: the notch panel lives on the built-in display, always, even when an external monitor is primary. Only if the lid is closed does it move or hide. Write the rule down in code as a single function, `targetScreen()`, so it is one place to change.
5. **Screen change resilience.** Subscribe to `NSApplication.didChangeScreenParametersNotification`, recompute and reposition on every fire. Test: plug in external monitor, unplug, change resolution, close and open lid, hot-plug while the panel is expanded. This is where most notch apps break.
6. **Hover detection.** `NSTrackingArea` with `.mouseEnteredAndExited` and `.activeAlways`. Debounce 150 to 250ms before expanding, or dragging the cursor across the top of the screen fires it constantly. Rebuild the tracking area on every geometry change — a stale one is the classic "hover stopped working after I unplugged my monitor" bug.
7. **Expand and collapse animation.** Resize the panel, not the inner view. Spring curve, not linear. Inverse-rounded corners where the shape meets the notch, as a custom SwiftUI `Shape` with Bezier curves. **Honor Reduce Motion** — check `accessibilityDisplayShouldReduceMotion` and snap instead of spring.
8. **Bezel black matching.** The expanded panel must read as an extension of the physical bezel. This is not `Color.black`. On an XDR display the panel's black and the bezel's black are different blacks, and the mismatch is visible at the seam. Expect to tune this by eye against a real machine, and expect it to differ between the built-in display and any external one. **User-verified only — the assistant cannot see this.**
9. **Menu bar item and settings window.** `NSStatusItem` so the user can reach settings and quit. Basic SwiftUI settings window, empty tabs are fine.
10. **Launch at login.** `SMAppService.mainApp.register()`, wired to a settings toggle, with the unregister path and error handling.

### Done when

Reboot the Mac, the app comes up silently with no Dock icon, the notch expands smoothly on hover, the seam against the bezel is invisible, and nothing breaks when an external monitor is plugged in.

### Known traps

- **AppKit's coordinate origin is bottom-left.** Reasoning about a top-anchored rect in top-left terms produces an offset roughly equal to the notch height.
- **`safeAreaInsets.top` is zero on external displays.** The fallback path is not an edge case, it is the common case the moment a monitor is plugged in.
- **Tracking areas do not follow a resized window.** Remove and re-add.

---

## Phase 2: Architecture before features

**Goal:** A module system so features plug in without touching each other.

**Risk: low, but skipping it is how the project dies at feature six.**

### Tasks

1. **`NotchModule` protocol.** Each feature declares `id`, `priority`, `isEnabled`, whether it wants compact display, whether it wants live activity, and provides a compact view and an expanded view.
2. **Arbiter.** One object owns the panel and decides what displays. Features never touch `NotchPanel` directly and never reference each other.
3. **`AppSettings`.** One `Codable` struct in UserDefaults as JSON, with `schemaVersion`. Any shape change needs a migration path.
4. **Create the test target.** First code worth testing. Cover arbitration logic and settings migration. See the testing section in CLAUDE.md.
5. **Prove it with two dummy modules** that fight for the notch. Verify arbitration before building anything real.

### Arbitration rules

- Live activities (music change, notification, file drop) temporarily take the notch
- Higher priority interrupts lower priority
- Equal priority queues
- A live activity yields after timeout and the notch returns to default
- Default state shows compact views of enabled always-on modules
- **A module that is not currently displayed suspends its timers.** The arbiter tells modules when they go on and off screen; polling while invisible is the main way this app would burn battery

### Done when

Adding a feature means creating one file and registering it in one place. Nothing else changes. Arbitration has tests that pass.

---

## Phase 3: System stats

**Goal:** Ship v0.1 to yourself. Use it daily for two weeks.

**Risk: low for the stats, medium for the rest.** The five core stats are public API and permission-free. Weather, calendar, and clipboard are not — each needs an authorization prompt or a polling loop, and each has a denied path to handle. They are grouped separately for that reason.

### The five core stats

All five live behind one `SystemStatsService` publishing a struct on a timer. Do not scatter IOKit calls through views. The service suspends its timer when no stats module is on screen.

1. **CPU.** `host_processor_info` from Mach. Sample on a timer, diff tick counts between samples. Absolute values are meaningless.
2. **Memory.** `host_statistics64` with `HOST_VM_INFO64`. Report pressure, not raw used. macOS caching makes raw numbers alarming and useless.
3. **Disk.** `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`. Will not match Finder exactly because of APFS snapshots and purgeable space. Expected, not a bug.
4. **GPU.** IOKit accelerator service, `PerformanceStatistics` then `Device Utilization %`. Key names are undocumented and differ across silicon. Guard against nil and degrade to hiding the stat, never to showing zero.
5. **Battery.** IOKit `AppleSmartBattery`, or `IOPSCopyPowerSourcesInfo` for the simple version.

### Permission-gated extras

Each ships only after its denied path is tested by actually denying it.

6. **Caffeinate.** `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep`. Release to stop. No permission needed, but the assertion must be released on quit or the Mac never sleeps again.
7. **Weather.** Open-Meteo (free, no key) or WeatherKit (needs paid account, has quota). Needs Location permission. Cache aggressively; this is not a stat that changes every 5 seconds.
8. **Calendar.** EventKit. Needs `NSCalendarsUsageDescription` or the app is killed on request. Test the denied path.
9. **Clipboard history.** Poll `NSPasteboard.general.changeCount`; there is no notification. Exclude items marked `org.nspasteboard.ConcealedType`, which is what password managers set. **This feature stores everything the user copies.** It is off by default, its storage is capped and in-memory only, and it is the single most likely thing to make a reviewer distrust the app. Consider cutting it.

### Done when

Used daily for two weeks and the annoyances that surfaced are fixed. Idle CPU is under 1%. Tag v0.1.

---

## Phase 4: Media

**Goal:** Now-playing display, transport controls, scrubbing, artwork. This is the app's primary feature.

**Risk: medium-high**, entirely from Apple platform changes.

### The core problem

The traditional route was the private MediaRemote framework, giving now-playing info and transport control for every app. Apple restricted it in macOS 15.4 behind a private entitlement, breaking most third-party now-playing apps.

**Task zero: verify the current state on the actual target OS before designing anything.** Write down what you find. This area has moved repeatedly and every plan below branches on the answer.

### What ships in v1

**Apple Music and Spotify, via AppleScript.** Both ship a scripting dictionary. This is the reliable path and it is the whole of v1.

**Pandora and YouTube Music do not ship a scriptable Mac app.** They are web properties. There is nothing to send an Apple Event to. They are blocked pending either MediaRemote access or a per-service web API with OAuth — both of which are their own project. Do not promise them in release notes.

### Tasks

1. **`MediaSource` protocol.** `isAvailable`, `currentTrack()`, `play`/`pause`/`next`/`previous`, `seek(to:)`. The adapter means an Apple policy change costs one file, not the app.
2. **Source selection.** More than one player can be running. Decide the rule and write it down: prefer the source that is actively playing; if several are, prefer the most recently started; never silently switch mid-track. This is the media equivalent of Phase 2's arbiter and it needs the same explicitness.
3. **`AppleScriptMediaSource`** for Music.app and Spotify.app. Needs Automation permission, and the first Apple Event triggers a system prompt. Denied means the module hides itself, not that the app breaks. Apple Events are slow — do not call them on every frame.
4. **`MediaRemoteSource`** for the universal case, only if task zero says it is available.
5. **Artwork and accent color.** Extract album art, derive a tint. `CIAreaAverage` is faster than manual averaging. Cache by track identifier — re-deriving a tint on every poll is wasteful and causes visible flicker.
6. **Scrubbing.** Draggable progress bar that seeks. Interpolate position locally between polls or it stutters.
7. **Lyrics (optional).** LRCLIB offers free time-synced lyrics with no key. Do not scrape Genius or Musixmatch.

### Done when

Music plays, the notch shows the right artwork and title, transport buttons work in both apps, and switching between Spotify and Music does not confuse the display.

---

## Phase 5: Shipping

Do this once Phase 4 is stable, even if later phases are unfinished.

1. Apple Developer Program, $99/year
2. Developer ID Application certificate (Xcode, Settings then Accounts)
3. Notarize: `xcrun notarytool submit`, then `xcrun stapler staple`
4. `scripts/release.sh` doing archive, export, notarize, staple, DMG in one command
5. **Choose and add a `LICENSE` file.** None exists. This is a decision, not a formality — see the open questions in `PROJECT-CONTEXT.md`
6. Sparkle for auto-updates, configured **before** the first public release. Note that Sparkle ships XPC services and needs specific Hardened Runtime entitlements; budget time for the notarization round-trip
7. Crash reporting — local only, or an explicit opt-in. Hard rule 6 forbids silent telemetry
8. Privacy note covering clipboard, location, and calendar, even though nothing leaves the machine. Especially because nothing leaves the machine; say so plainly
9. Landing page and support channel

---

## Phase 6: Stocks

**Goal:** Sparkline graphs for a user-chosen ticker watchlist, in the notch.

**Risk: low technically, medium on licensing.** The chart is easy. The data terms are not.

### Decide before writing code

1. **Provider and license.** Free tiers are heavily rate-limited and most prohibit redistribution of quotes. For a public release that is a blocker, not a footnote. Read the terms before writing the client.
2. **Refresh policy.** Market hours only, with a hard backoff when closed. Respect the rate limit as a design constraint, not an error case.
3. **Stale display.** Data older than the refresh interval must visibly read as stale. A three-hour-old price rendered as current is worse than showing nothing.

### Tasks

4. **`StocksService`.** One service, one cache, one timer that suspends with the module. Same shape as `SystemStatsService`.
5. **Watchlist in `AppSettings`.** New field, so `schemaVersion` bumps and a migration test comes with it.
6. **Compact view.** One ticker, price, percent change. Whatever fits beside a notch.
7. **Expanded view.** Sparkline per ticker. SwiftUI `Path`, no charting dependency.
8. **Offline and error states.** No network, bad symbol, rate-limited — all three need a display, and none of them are a crash.

### Non-goals

No trading, no portfolio tracking, no alerts. This is a glanceable display. Anything that touches an account is a different app with a different threat model.

---

## Deliberately out of scope

These were considered and cut. Do not add them without an explicit decision to reverse this.

- **Per-app volume and EQ.** Requires a CoreAudio HAL plugin shipped as a system extension with a driver entitlement. Two to four months, and bugs break audio system-wide. Not worth it.
- **Battery charge limiting.** Requires a privileged helper via `SMAppService.daemon`, XPC, and undocumented SMC writes. Hardware risk.
- **Face ID unlock.** Three hard problems: recognition, anti-spoofing, and the authorization plugin system. A bug can lock the user out of their own machine.
- **Android file sharing.** Requires implementing an undocumented protocol. Three to six months.
- **AI agent.** Open-ended. The hard part is a safe action layer, not the model call.
- **Trading or portfolio management.** See Phase 6 non-goals.
- **Browser-tab media control via extension.** The only realistic route to YouTube Music and Pandora, and it means shipping and maintaining browser extensions for every browser. That is a second product.

---

## Checkpoints

Decision points, not motivational milestones. There are no dates in this project — it is a solo build with no deadline, and inventing one would be theater. What these do instead is name the moment to reconsider scope, so that a stall gets noticed rather than absorbed.

| Checkpoint | If you are stuck here | Then |
|---|---|---|
| Panel visible over the notch | more than a week | Reassess whether AppKit is the right first native project |
| Phase 1 complete | more than a month | Cut scope to a menu bar app instead of a notch app. Everything from Phase 2 on still works |
| v0.1 in daily use | you keep adding features instead | Stop. You are building for a hypothetical user |
| Media working | task zero says MediaRemote is dead and AppleScript is not enough | Ship without it. Painful, but it is the most replaceable feature |
| Public release | you have not used v0.1 daily for two weeks | Not ready. Shipping an app you do not use yourself is how you find out in public |
