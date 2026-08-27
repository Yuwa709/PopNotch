# PopNotch Roadmap

Phased build plan. Each phase ends with something installable and usable. If a phase ends with "the code compiles," the phase was scoped wrong.

Read this when starting a new phase. Do not read it for routine tasks.

---

## Current status

- Phase 0: complete (project created, git initialized, CLAUDE.md in place)
- Phase 1: in progress
  - NotchPanel class created, geometry computed, logging in place, builds clean
  - Not yet instantiated or displayed
- Phases 2 and beyond: not started

Update this section at the end of each phase.

---

## Phase 1: Notch shell

**Goal:** An empty overlay that expands on hover, collapses on exit, survives display changes and fullscreen apps, and launches at login.

**Risk: high.** This is the make-or-break phase. Everything else plugs into it.

### Tasks

1. **NotchPanel class.** `NSPanel` subclass. `isOpaque = false`, clear background, no shadow, `styleMask = [.borderless, .nonactivatingPanel]`, `canBecomeKey` returns false, `hidesOnDeactivate = false`. Level one above `CGWindowLevelForKey(.mainMenuWindow)`. **Done.**
2. **Geometry.** Notch rect is the gap between `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX`, height `safeAreaInsets.top`, anchored to `screen.frame.maxY`. Fallback strip for screens without a notch. **Done.**
3. **Instantiate and display.** Create one panel at launch, `orderFront`. Set `collectionBehavior` to include `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`. Without these it vanishes on space switch and in fullscreen.
4. **Screen change resilience.** Subscribe to `NSApplication.didChangeScreenParametersNotification`, recompute and reposition on every fire. Test: plug in external monitor, unplug, change resolution, close and open lid. This is where most notch apps break.
5. **Hover detection.** `NSTrackingArea` with `.mouseEnteredAndExited` and `.activeAlways`. Debounce 150 to 250ms before expanding, or dragging the cursor across the top of the screen fires it constantly.
6. **Expand and collapse animation.** Resize the panel, not the inner view. Spring curve, not linear. Inverse-rounded corners where the shape meets the notch, as a custom SwiftUI `Shape` with Bezier curves.
7. **Menu bar item and settings window.** `NSStatusItem` so the user can reach settings and quit. Basic SwiftUI settings window, empty tabs are fine.
8. **Launch at login.** `SMAppService.mainApp.register()`, wired to a settings toggle, with the unregister path and error handling.

### Done when

Reboot the Mac, the app comes up silently, the notch expands smoothly on hover, and nothing breaks when an external monitor is plugged in.

### Known trap

AppKit's coordinate origin is bottom-left. Reasoning about a top-anchored rect in top-left terms produces an offset roughly equal to the notch height.

---

## Phase 2: Architecture before features

**Goal:** A module system so features plug in without touching each other.

**Risk: low, but skipping it is how the project dies at feature six.**

### Tasks

1. **`NotchModule` protocol.** Each feature declares `id`, `priority`, `isEnabled`, whether it wants compact display, whether it wants live activity, and provides a compact view and an expanded view.
2. **Arbiter.** One object owns the panel and decides what displays. Features never touch `NotchPanel` directly and never reference each other.
3. **`AppSettings`.** One `Codable` struct in UserDefaults as JSON, with `schemaVersion`. Any shape change needs a migration path.
4. **Prove it with two dummy modules** that fight for the notch. Verify arbitration before building anything real.

### Arbitration rules

- Live activities (music change, notification, file drop) temporarily take the notch
- Higher priority interrupts lower priority
- Equal priority queues
- A live activity yields after timeout and the notch returns to default
- Default state shows compact views of enabled always-on modules

### Done when

Adding a feature means creating one file and registering it in one place. Nothing else changes.

---

## Phase 3: System stats and easy wins

**Goal:** Ship v0.1 to yourself. Use it daily for two weeks.

**Risk: low.** Every API here is public and mostly permission-free.

### Tasks

1. **CPU.** `host_processor_info` from Mach. Sample on a timer, diff tick counts between samples. Absolute values are meaningless.
2. **Memory.** `host_statistics64` with `HOST_VM_INFO64`. Report pressure, not raw used. macOS caching makes raw numbers alarming and useless.
3. **Disk.** `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`. Will not match Finder exactly because of APFS snapshots and purgeable space. Expected, not a bug.
4. **GPU.** IOKit accelerator service, `PerformanceStatistics` then `Device Utilization %`. Key names differ between Intel and Apple Silicon. Guard against nil.
5. **Battery.** IOKit `AppleSmartBattery`, or `IOPSCopyPowerSourcesInfo` for the simple version.
6. **Caffeinate.** `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep`. Release to stop.
7. **Weather.** Open-Meteo (free, no key) or WeatherKit (needs paid account, has quota). Needs Location permission, handle denial.
8. **Calendar.** EventKit. Needs `NSCalendarsUsageDescription` in Info.plist or the app crashes on request. Test the denied path.
9. **Clipboard history.** Poll `NSPasteboard.general.changeCount`; there is no notification. Exclude items marked `org.nspasteboard.ConcealedType`, which is what password managers set.

All five stats live behind one `SystemStatsService` publishing a struct on a timer. Do not scatter IOKit calls through views.

### Done when

Used daily for two weeks and the annoyances that surfaced are fixed. Tag v0.1.

---

## Phase 4: Media

**Goal:** Now-playing display, transport controls, scrubbing, artwork.

**Risk: medium-high**, entirely from Apple platform changes.

### The core problem

The traditional route was the private MediaRemote framework, giving now-playing info and transport control for every app. Apple restricted it in macOS 15.4 behind a private entitlement, breaking most third-party now-playing apps. **Verify the current state before building.** This area has moved repeatedly.

### Tasks

1. **`MediaSource` protocol.** `isAvailable`, `currentTrack()`, `play`/`pause`/`next`/`previous`, `seek(to:)`. The adapter means an Apple policy change costs one file, not the app.
2. **`AppleScriptMediaSource`** for Music.app and Spotify.app. Reliable, but only those two apps, and needs Automation permission.
3. **`MediaRemoteSource`** for the universal case, if available on the target OS.
4. **Artwork and accent color.** Extract album art, derive a tint. `CIAreaAverage` is faster than manual averaging.
5. **Scrubbing.** Draggable progress bar that seeks. Interpolate position locally between polls or it stutters.
6. **Lyrics (optional).** LRCLIB offers free time-synced lyrics with no key. Do not scrape Genius or Musixmatch.

---

## Phase 5: Shipping

Do this once Phase 4 is stable, even if later phases are unfinished.

1. Apple Developer Program, $99/year
2. Developer ID Application certificate (Xcode, Settings then Accounts)
3. Notarize: `xcrun notarytool submit`, then `xcrun stapler staple`
4. `scripts/release.sh` doing archive, export, notarize, staple, DMG in one command
5. Sparkle for auto-updates, configured **before** the first public release
6. Crash reporting
7. Landing page and support channel

---

## Deliberately out of scope

These were considered and cut. Do not add them without an explicit decision to reverse this.

- **Per-app volume and EQ.** Requires a CoreAudio HAL plugin shipped as a system extension with a driver entitlement. Two to four months, and bugs break audio system-wide. Not worth it.
- **Battery charge limiting.** Requires a privileged helper via `SMAppService.daemon`, XPC, and undocumented SMC writes. Hardware risk.
- **Face ID unlock.** Three hard problems: recognition, anti-spoofing, and the authorization plugin system. A bug can lock the user out of their own machine.
- **Android file sharing.** Requires implementing an undocumented protocol. Three to six months.
- **AI agent.** Open-ended. The hard part is a safe action layer, not the model call.

---

## Checkpoints

Decision points, not motivational milestones. Missing one means adjusting scope, not extending the deadline.

| Checkpoint | If missed |
|---|---|
| Panel visible over the notch | Reassess whether AppKit is the right first native project |
| Phase 1 complete | Cut scope to a menu bar app instead of a notch app |
| v0.1 in daily use | You are building for a hypothetical user. Stop and use it |
| Media working | Ship without it. Most replaceable feature |
