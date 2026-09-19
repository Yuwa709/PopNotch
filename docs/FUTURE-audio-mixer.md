# Per-app audio mixer

**Status: v1 in progress (2026-09-18). Phases 2, 3 and 4 are committed, Phase 1 is built, and Phase 0 has run.**

- **Phase 1** is settings schema v9, plus a fake-engine seam so the visualiser's lifecycle tests never open a real tap (2026-09-18). See *Accepted defaults* and *Carried from the plan*.
- **Phase 2** is the Spotify and Music volume slider on the player screen (`c532afb`, restyled in `3dfc3c7`, `a10f088` and `72d060e`).
- **Phase 3** is process enumeration and naming with the corrected change trigger (`606af7d`).
- **Phase 4** is the mixer page (`72d060e`, `ba43611`). It sits behind an App Volume toggle, off by default, which replaced Phase 3's Debug-only gate. Its Spotify and Music rows work; every other row is inert until Phase 5.
- **Phase 0:** F, the gate, passed, but the CPU budget is exceeded, and several items are open (see *Phase 0*).
- **Not started:** Phases 5 to 7.

v1's decisions and phasing are in *v1 plan*. A throwaway spike measured the mechanism itself, outside the app; see *Spike results*.

Recorded 2026-08-29 so the research is not re-done from scratch, and so the correction below does not get lost.

---

## What the feature is

A per-app audio mixer, in rough order of value:

1. **Per-app volume.** Turn Spotify down without touching Logic Pro. This is the whole idea; everything else is optional.
2. **Per-app or per-device EQ.** Multi-band curves applied to one app's output, or to an output device.
3. **Routing.** Send one app's audio to a chosen output.
4. **Multi-device output.** The same stream to several devices at once.

Reference implementations, both of which do more than this list:

- **FineTune** — `github.com/ronitsingh10/FineTune`
- **Sapphire** — its "Multi Audio" feature, marked **Beta** in its own README

Studying what they do is fine. Reading their source is not: see *Clean room* at the bottom.

---

## The correction: process taps, not a driver

**This project previously recorded that per-app audio requires a CoreAudio HAL plugin shipped as a system extension with a driver entitlement, at two to four months of work.** That was the basis for cutting the feature, and it is **wrong**.

The current mechanism is **Core Audio process taps**: `AudioHardwareCreateProcessTap` plus the aggregate-device APIs, available from **macOS 14.2**. A regular app can tap another process's audio, adjust it, and route it. There is no virtual driver, no system extension, no driver entitlement, and no kernel-adjacent failure mode where a bug breaks audio system-wide.

That changes the cost estimate substantially and is the reason this is *deferred* rather than *cut*.

**Deployment target: resolved.** PopNotch's deployment target is **macOS 14.2**, which is what process taps need. It was raised from 14.0 on 2026-08-29 in `6bc8952`, for the audio visualiser, which uses the same taps. Verified in `project.pbxproj` on 2026-09-17: all six build configurations say 14.2. No availability gate is needed.

---

## Permissions — verify before building

**Answered by measurement (2026-09-16): one audio-recording prompt, no Screen Recording, no entitlement.** See *Spike results*, *Permissions*. The reasoning below is kept for the record.

The tap path requires an **audio-capture** permission. That much is expected: tapping another process's audio is a capture operation and macOS gates it.

**Observation, not conclusion:** FineTune was seen requesting **Screen Recording** as well. That may be because Screen Recording is the umbrella permission some capture paths fall under, or because FineTune does something else that needs it. It is not established that a pure process-tap mixer needs Screen Recording.

**Confirm which permission the tap path actually requires before writing any of this.** Two reasons this matters more than usual here:

- The project rule from the `starred` incident applies: presence in documentation proves vocabulary, not behaviour. Execute a minimal tap and observe which prompt appears.
- Asking a background menu-bar utility for Screen Recording is a serious trust cost. PopNotch's README currently lists **Automation as the only permission it ever requests**, and that is a selling point. Adding Screen Recording would need to be a deliberate, explained decision — and if it turns out to be unnecessary, avoiding it is worth real effort.

Whatever the answer, it needs a graceful denied path like every other permission (`CLAUDE.md`, Permissions).

---

## Battery cost, from observation

- **Light per-app volume: no noticeable battery cost.** Applying a gain to a tapped stream is cheap.
- **Continuous multi-band EQ is the expensive part.** That is where the energy goes, and it runs constantly while audio plays.

This maps directly onto the scoping rule below: the cheap half is also the valuable half.

PopNotch's performance budget (under 1% CPU idle, under 80MB resident) was written for an overlay that samples stats. A mixer processing audio continuously is a different kind of load and would need its own measured budget, not an assumption that the existing one still holds.

**Budget set 2026-09-17,** before any measurement: at most **2 points of one core per tapped app** while it plays, PopNotch and coreaudiod combined, measured by CPU time. The idle budget is unchanged. Recorded in `CLAUDE.md`, *Performance budget*; see *v1 plan*.

---

## Why it is deferred until PopNotch ships

Three reasons, none of them technical:

1. **It is the size of a second app.** Even without the driver, this is a mixer: process enumeration, tap lifecycle, per-app state, a UI, and a long tail of apps that misbehave under it. It is not a feature you add to a notch utility in a session.
2. **It is not a notch feature.** In every reference implementation it lives in a **menu-bar popup**, not in the notch — because a mixer wants a list of apps with sliders, which is a panel, not a strip above the bezel. Building it would mean building a second surface with its own design language.
3. **It would bury the differentiator.** System-resource monitoring is the thing PopNotch has that the references do not, and it is already shipped. Adding a large, noisy feature that the competition already has — one of them still in Beta — trades a real advantage for a contested one.

Revisit **after** PopNotch has shipped and been used daily, per the roadmap's own checkpoint about building for a hypothetical user.

**Lifted 2026-09-17.** PopNotch has shipped. The reasons above are kept for the record, but two of them no longer hold:

- **Reason 2 is overridden by decision.** The mixer lives in the notch: a screen the coordinator composes, plus a volume button on the player. That reuses the stats page's pattern rather than building a second surface.
- **Reason 3 is answered by a user.** v1 exists to replace FineTune for its owner, who uses only its volume sliders. The advantage is being in the notch and one less app at login. See *v1 plan*.

---

## Known traps, for whoever builds it

Recorded now because these are the parts that are discovered late and expensively.

- **DAWs, VoIP, and low-level routing apps break under process taps.** They already manage their own audio path, and interposing on it causes glitching, dropouts, or silence. **Logic Pro is the example** — and it is precisely the app named in the original motivating use case ("turn Spotify down while Logic Pro is up"), so the feature's headline scenario is also its worst failure mode. A **per-app ignore/bypass list is not a polish item; it is a v1 requirement**, and it should ship with sensible defaults already populated rather than waiting for users to discover the problem. **Revised 2026-09-17:** v1 uses a fixed never-tap set instead of an editable list; *v1 plan* says why. **Still unverified:** Logic Pro was not installed on the spike machine, so this was neither confirmed nor refuted.
- **The tapped process may not be the app.** Some apps play audio through helper processes, so the PID producing sound does not match the application the user recognises. Naive enumeration will show a helper's name, or attribute audio to the wrong app, or miss it entirely. Mapping helper processes back to their parent application is real work. **Confirmed for both browsers.** Chrome and Electron apps map back with public information; Safari only through a private API. See *Spike results*, *Mapping an audio process to its owning app*.
- **Only show apps that actually produce audio.** A list built from "running applications" will include Terminal, Finder, and everything else the user has open. The list must be driven by what is actually producing audio, or the UI is a junk drawer.

---

## Spike results (2026-09-16 and 2026-09-17)

**Setup.** A throwaway SwiftPM spike, kept outside the repo at `~/PopNotch-spikes/tapspike`; its README has the run commands. It uses Apple's public API only, and no reference implementation was opened. It ran as its own signed app bundle, launched with `open`, under hardened runtime with **no entitlements**.

**The audio under test** was a tone from a separate spike process standing in for an app, usually 19 kHz so it was near-inaudible. A tap reads samples digitally, so audibility doesn't matter.

**Proof that the device was silent** came from the built-in microphone listening to the built-in speakers, reduced to a 19 kHz level every 0.5 s. That is the only way to prove output silence: a second tap would see the pre-mute stream.

**Confounds.** FineTune was quit for every measurement, because it holds its own taps and would skew them.

**Evidence.** Logs for B, C and D are in `~/PopNotch-spikes/tapspike/evidence/2026-09-17/`. A's raw logs were lost when a reboot wiped the temp directory the spike first lived in, so the A results below come from the session notes.

### Permissions

- **One prompt, for audio recording** (reported by the user; the exact wording wasn't captured). **No Screen Recording prompt appeared at any point.** The open question in *Permissions* above is answered: the tap path does not need Screen Recording.
- **The prompt shows up as `AudioDeviceStart` blocking until it's answered**, 17 s on the first run. `AudioHardwareCreateProcessTap` and aggregate creation succeed immediately beforehand. A denied path therefore has to handle a start that blocks, then fails.
- **No entitlement needed.** The tap bundle ran under hardened runtime with zero entitlements, so nothing beyond PopNotch's existing `com.apple.security.automation.apple-events` is required. The mic probe needed `com.apple.security.device.audio-input`, but it is measurement equipment, not part of any feature.
- **Grants survived rebuilds** while the signing identity and bundle ID stayed the same.

### A. Which process to tap

| App | Process emitting the audio | Tap result |
|---|---|---|
| Safari | `com.apple.WebKit.GPU` helper, **parent launchd** | Test tone received, matching an independent global tap. **Safari's own process has no Core Audio process object**, so it can't be tapped at all |
| Chrome | `Google Chrome Helper --utility-sub-type=audio.mojom.AudioService`, parent Chrome, bundle `com.google.Chrome.helper` | Test tone received, matching the global tap. The main process has a process object, but its tap gets zero callbacks |
| Spotify | **The app process itself** (`com.spotify.client`) | Music received, 100% non-zero samples. Its helpers have no process objects |
| Logic Pro | Not installed | **Unmeasured** |
| Music | No subscription on the test machine | **Unmeasured** |

- **Enumeration has to follow what is actually playing**, `kAudioProcessPropertyIsRunningOutput`, not the app list. Tapping the app a user recognises gets nothing for either browser.
- **Chrome maps back to its app with public information; Safari does not.** `com.apple.WebKit.GPU` has launchd as its parent and a bundle ID naming WebKit, not Safari. Every WebKit-based app will present the same way. See *Mapping an audio process to its owning app* below.
- **Logic Pro remains the open question.** The DAW trap in *Known traps* is neither confirmed nor refuted.

### B. Mute: passes, with a negative control

All three processes (tone, taps, mic) logged against one wall clock, so the rows below are simultaneous.

| Phase | Mic at 19 kHz (speaker output) | Tap on the tone process |
|---|---|---|
| Before the tone | −112 to −128 dB (noise floor) | — |
| Tone, no tap | **−48.8 dB** | — |
| `.muted` tap live, 10 s | **−113 to −128 dB**: noise floor, reached within the first 0.5 s | **−12.1 dB, 100% non-zero**, every callback |
| Tap destroyed | back to −47 dB within 0.5 s | — |
| **Unmuted** tap, the control | stays at **−49 dB** | −12.1 dB |
| `.mutedWhenTapped` tap | noise floor | −12.1 dB |

- **Both mute behaviours silence the device completely**, to the mic's noise floor and more than 64 dB down, while the tap keeps receiving every sample.
- **The unmuted control proves the silence comes from the mute**, not from tapping.
- **A clean destroy restores audio within 0.5 s.** Recovery after SIGKILL (F) is **untested**.

### C. Reroute: works, but on one shared clock

- **The setup:** a muted tap on the tone playing on the built-in speakers (48 kHz). The aggregate was the tap plus the EarPods (USB, 44.1 kHz) as main subdevice, with tap drift compensation on, and an IOProc copying tap to output.
- **Over 44 s:** 0 glitches, 0 timestamp jumps, 0 overloads.
- **Proven acoustically, with the EarPods lying by the mic.** Reroute gain of 0, −20 and −60 dB gave a mic level of −48.2, −69.0 and about −107 dB (the noise floor). The mic tracked the gain, so the sound came from the EarPods, and the speakers stayed muted throughout. It also shows a gain applied in the IOProc lands exactly, which is the operation per-app volume needs.
- **The tap's own stream is 48 kHz whatever the source device's rate** (seen with 44.1 kHz sources too), and the aggregate resamples to the render device. At 19 kHz, going into 44.1 kHz, that path cost 3.4 dB: the resampler's passband edge near Nyquist. Normal audio frequencies were not tested.

### The shared-clock measurement

The reroute was meant to cross into an **independent** clock. It didn't, because none of the wired devices has one. Each device's sample rate was measured from its IO timestamps against host time:

| Device | Transport | Measured rate vs nominal |
|---|---|---|
| MacBook Air Speakers | built-in | +6.7 ppm (41 s) |
| EarPods | USB | +6.8 to +6.9 ppm (several 8–20 s runs) |
| "Headphones", the dock's USB audio | USB | +6.7 ppm (40 s) |

- **The three agree within about 0.2 ppm.** Independent crystals typically disagree by tens of ppm.
- **The +6.7 ppm is the host clock's offset from the Mac's audio reference**, and both USB devices follow that reference. That's typical of USB audio devices that take their clock from the host's USB frames instead of their own crystal.
- **`kAudioDevicePropertyClockDomain` can't detect independence.** It reported the same value for every device.

**So D, the 30-minute drift soak, could not run on these devices: it would have been a false pass.** With every device on one clock, there is no drift to compensate, and the soak would count zero drift glitches whether or not tap drift compensation works. D ran on AirPods instead; see *D* below.

### D. Drift soak into AirPods: 0 glitches over 30 minutes

- **The setup:** a muted tap on the tone playing on the built-in speakers, rerouted to AirPods (Bluetooth, 48 kHz) as the aggregate's main subdevice, with tap drift compensation on. The mute happens on one device and the rendering on another, which is the real cross-device case.
- **Render gain was −60 dB** to keep the tone out of the wearer's ears. Glitches are counted on the tapped stream before the gain, so the gain doesn't affect the count.
- **Discord was moved off the AirPods first.** A call puts them in a different Bluetooth mode, and a mode switch mid-run would count as glitches that have nothing to do with drift.

**The AirPods' clock was measured first**, the same way as the table above:

| Device | Measured rate vs host clock |
|---|---|
| AirPods | exactly 48000.000 Hz, **+0.00 ppm** (150 s, and again over the full 1800 s soak) |
| MacBook Air Speakers | **+6.1 ppm** (the same 150 s), **+6.3 ppm** over the soak |

- **The Mac times Bluetooth output from its host clock.** A rate that is exactly nominal, to 0.01 ppm, comes from host time, not from a crystal. Core Audio never sees the AirPods' own clock. Whatever matches it to the Mac happens below the HAL, in the Bluetooth stack or in the AirPods. So no Bluetooth device will read tens of ppm here; only a USB DAC with its own clock could.
- **This confirms the reading of the table above.** A device timed straight from host time reads exactly 0, so the +6 to +7 ppm on the wired devices is the audio reference's offset from host time.
- **So the drift was real: 6.3 ppm.** Speakers to AirPods crosses from the audio reference to the host clock. That is about 0.3 samples a second, or roughly 545 samples over the 30 minutes.

**The result, over 1800 s in 180 ten-second intervals:**

- **0 glitches**, 0 dropout runs, 0 input or output timestamp jumps, 0 overloads.
- Every interval received a full set of callbacks (937 or 938), and the tapped stream stayed 100% non-zero.

**The aggregate resampled the drift away, and the tone level shows it.**

- **On the AirPods, the tapped 19 kHz tone read −27 to −30 dB,** though its peak and RMS were at the full −12 dBFS.
- **A 1-minute control read a flat −12.1 dB.** It used the same reroute and the same 10 s windows, into the dock's "Headphones", which share the speakers' clock.
- **The gap is what a frequency shift does to a 10 s level measurement.** A tone about 0.12 Hz off loses that much over 10 s, and 0.12 Hz at 19 kHz is 6.1 to 6.3 ppm. So the tap stream was resampled continuously from the speakers' clock to the AirPods', not passed through sample for sample with slips.

**Limits:**

- **The count stops at the Mac's output.** It covers the tapped stream after drift compensation, and the HAL's output timing. Bluetooth encoding, the link, and the AirPods matching their own crystal all happen after that, where no tap can see. A dropout there would be heard, not counted.
- **The drift-compensation-off control wasn't run.** So it is unproven that the harness would count glitches at a drift this small when compensation is missing. The tone shift shows the drift was in the stream and was resampled, but the uncorrected case is unmeasured. At 6.3 ppm the drift builds slowly, so that control needs the full 30 minutes, not 5.
- **Only one crossing was tested:** the audio reference to the host clock, at 6.3 ppm. A USB DAC with its own crystal, at tens of ppm, is untested, and so is the 44.1 kHz-source case.

**Evidence:** `D0-clock-*.log` (the rate check), `D-soak-airpods-*.log` (the soak) and `D-control-headphones-*.log` (the same-clock control). `scripts/soak.sh` now takes the render gain as an optional fifth argument.

**Also not run:** E (latency), the SIGKILL half of F, and G (conflict with the visualiser's global tap).

### Mapping an audio process to its owning app (2026-09-17)

**Method.** A read-only probe: process, bundle, code-signing and Core Audio property reads only, with no taps and no audio. It covered every Core Audio process object on the machine and 152 running XPC services.

**Gaps.** Safari and Chrome weren't running and weren't launched, since restoring old tabs could have played audio. Their live parent-PID facts come from *A* (2026-09-16). Discord stood in for Chrome's live checks: it has the same Chromium architecture, including a live `audio.mojom.AudioService` helper.

#### What each signal says

| Signal | Safari: `com.apple.WebKit.GPU` | Chrome: audio-service helper | Spotify |
|---|---|---|---|
| **Parent PID** | launchd ✗ | Chrome ✓ (Discord's identical helper: Discord) | launchd, but it *is* the app ✓ |
| **Executable path** | `/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU`: inside WebKit, **not Safari.app** ✗ | `…/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/<ver>/Helpers/Google Chrome Helper.app/…`: inside Chrome.app ✓ | `/Applications/Spotify.app/Contents/MacOS/Spotify` ✓ |
| **Signing ID and team** | Apple platform binary, **no team ID**. So is Safari, and so is every Apple app ✗ | `com.google.Chrome.helper`, team `EQHXZ8M8AV`, the same as Chrome ✓ | `com.spotify.client`, team `2FNC3A47ZF` ✓ |
| **`NSRunningApplication`** | Not observed | Never the parent app: nil, or the helper's own bundle ✗ | ✓ |
| **Responsible process** (private) | **Safari, expected but not observed**; see below | The parent app (observed on Discord) ✓ | Itself ✓ |
| **Core Audio bundle ID** | `com.apple.WebKit.GPU` ✗ | `com.google.Chrome.helper`: a prefix guess at best | `com.spotify.client` ✓ |

#### What resolves each app

- **Spotify resolves by its Core Audio bundle ID alone.** It plays from its own process.
- **Chrome and Electron apps resolve with public information.** The parent PID names the app, confirmed by the helper's path sitting inside the parent's bundle and a matching team ID. Observed on Discord and on Claude; Chrome from *A*.
- **Safari resolves only via the private responsible-process API.** Path, parent, signing and bundle ID all say "WebKit" or "Apple". The same process identity appears for Mail or any app with a web view.
  - **The API:** macOS tracks a *responsible* process for permission attribution. It can be read only through `responsibility_get_pid_responsible_for_pid`, which is exported but has no header in the SDK, or through `launchctl procinfo`, which needs root. For WebKit this is **inferred, not observed**, because no WebKit process was running.
  - **The inference:** 131 of 149 running system-framework XPC services have launchd as their parent but report their client as responsible. For example, `CredentialProviderExtensionHelper` reports Discord. `com.apple.WebKit.GPU` is the same kind of service: `ServiceType` Application, with `_MultipleInstances` so each client gets its own instance.
  - **Coalition IDs:** these agreed with the responsible process in every case checked, but they come from an undocumented `proc_pidinfo` query, so they are private too.

#### Signals that don't help

- **`NSRunningApplication`** has no parent or responsible property. For helpers it returns nil or the helper itself; two identical Discord helpers returned one of each.
- **An audit token** carries no responsible pid, and there's no public way to get another process's token.
- **Core Audio** exposes only PID, bundle ID, devices and three is-running flags, plus a fixed owner and creator (`com.apple.audio.CoreAudio`). The bundle ID is always the process's own, and for daemons it can be unexpected: `audioaccessoryd` reports `com.apple.cloudpaird`, `callservicesd` reports `com.apple.TelephonyUtilities`, and some report none.

#### An app nobody anticipated

| How it plays audio | What resolves it |
|---|---|
| From its own process | Bundle ID. Public, reliable |
| From a helper inside its bundle (Chromium, Electron) | Parent PID, path containment, team ID. Public |
| From an XPC service inside its own bundle | The parent is launchd, but path containment and team ID still work (seen with `DockHelper`) |
| From a system-framework XPC service (WebKit, possibly others) | Only the private responsible pid. Every public signal says "Apple" |
| From a separately installed agent or daemon | The parent is launchd and it is responsible for itself. Only the team ID links it, and that names the vendor, not the app |
| Through a system daemon (`avconferenced` for calls, `systemsoundserverd`, `callservicesd`) | Nothing. Even the responsible pid stops at the daemon, and root-owned daemons won't show a user process their parent PID |

**Consequence for a build.** A public-only mapping covers apps that play from their own process and helpers inside an app's bundle. Audio from WebKit can only be labelled generically, such as "web content", unless the private API is adopted. That is a decision to record, not a default: the API is undocumented and can change in any macOS update. Audio played through system daemons can't be attributed to an app by any method.

### What this settles

- **The driver correction stands, now measured.** A regular app with no entitlements can mute one process's audio and re-render it, with only one audio-recording prompt.
- **The pieces v1 needs work:** muting at the source, re-rendering, and a gain step. v1 is per-app volume on the device the app already uses. Cross-device routing stays out of scope. Its drift handling has been measured for one crossing: 0 glitches over 30 minutes at 6.3 ppm, within the limits listed in *D*.
- **Answered since, in *v1 plan*, *Phase 0*:** SIGKILL recovery, v1's gate, passed. The visualiser's global tap does double-count a re-rendered app, and excluding PopNotch's own process fixes it.
- **Still open:** Logic Pro's behaviour (the headline case). No DAW was tested, so it is recorded as unverified. The WebKit question is decided: no private API, and WebKit audio is labelled generically.

---

## Scoping rule

**Version one is per-app volume sliders. Nothing else.**

No EQ. No routing. No multi-device output. Those are the expensive half — in battery, in complexity, and in the number of apps they can break.

Before any of them is considered:

1. Per-app volume is **used daily for a week**.
2. Its **battery cost is measured**, not assumed, against a stated budget.

Only then does EQ or routing get discussed. This is the same discipline the roadmap applies elsewhere: ship the small thing, live with it, then decide.

---

## v1 plan (decided 2026-09-17)

A plan was proposed, then an interview challenged it question by question. The decisions below are its outcome. They implement the scoping rule above: volume sliders only. Every assumed default was accepted as written.

### Settled decisions

1. **Purpose and success.** v1 replaces FineTune for its owner, who uses only its volume sliders. **v1 succeeds if FineTune is uninstalled after the week of daily use.** Routing and EQ stay out on usage grounds, not only on cost.
2. **Where the controls live.**
   - **A mixer page in the notch.** A navigated screen composed by the coordinator, the way the stats page is. It is needed because the controls must reach any app that plays audio, not just the current player: Discord never appears on the player screen, because it publishes no now-playing session (PopNotch's logs across a full call showed only Firefox and Chrome sessions).
   - **A volume button on the player.** At the trailing edge of the controls row, opposite the heart. It is a speaker glyph (`speaker.wave.3`, slashed at zero), sized and tinted like the shuffle and repeat buttons rather than the heart. It shows no level; the slider it opens does. Clicking it swaps the transport cluster for a full-width slider until the pointer leaves, and under Reduce Motion the swap is instant (hard rule 8). The player layout is otherwise unchanged. This button is the shortcut for the most frequent moment: music too loud against Discord, several times a day.
     - **Revised after building (2026-09-17):** the plan first called for a speaker glyph mirroring the heart. At the heart's size it read too big, so it now matches the mode buttons.
     - **Revised again (2026-09-18):** it was `slider.horizontal.3` for a day. The mixer door took that glyph in Phase 4, and the same glyph in both places read as a duplicate control, so the button is a speaker again, still at the mode buttons' size and tint.
   - **The mixer page's Spotify and Music rows are the same control as this button's slider** (2026-09-18). Both go through the media module to the player's own `sound volume`, sharing one value, one write throttle and one read-back correction, so moving either moves the other. They work before the tap engine, because they need none; every other row is inert until Phase 5.
3. **Two mechanisms, one per kind of app.**
   - **Spotify and Music use their own AppleScript `sound volume`,** which both scripting dictionaries declare read-write, 0 to 100. No tap and no new permission (the existing Automation grant covers it), so it is **on by default**. The volume lives in the app, so it survives PopNotch quitting or crashing, and it's never re-rendered.
   - **Everything else uses process taps,** **opt-in** behind a Settings toggle that is off by default. The audio-recording prompt appears when the toggle is turned on, because the prompt blocks until it is answered.
   - **Why not taps for everything:** stacking a tap gain on top of Spotify's own volume would give two numbers that multiply, and the most-adjusted app would pay re-render cost and latency the whole time it plays.
4. **Engine ownership.** The tap engine is a service owned by AppDelegate, not a NotchModule.
5. **No private API.** WebKit audio is one row labelled "Web content", covering Safari, Mail and every app with a web view. See *Mapping an audio process to its owning app*.
6. **Discord stays adjustable during calls.** The plan's proposed pause while an app captures the mic is dropped. The risk is to the *other* people in the call: re-render timing and level could confuse Discord's echo cancellation, which only matters when output goes to speakers the mic can hear.
   - **Gate:** a real Discord call on the laptop speakers in *Phase 0*, with a second participant listening for echo while the slider moves.
   - **If echo appears:** restrict call-time adjustment to non-built-in outputs, with the slider saying why.
7. **Crash safety is a hard exit.** If *Phase 0* shows a SIGKILL leaves tapped apps muted, **v1 stops.** No recovery machinery: no public taps recorded on disk, no relaunch agent.
8. **Budget.** Idle is unchanged. Active is **at most 2 points of one core per tapped app**, PopNotch and coreaudiod combined, measured by CPU time with 1 and 3 tapped apps.
   - **Over budget means v1 doesn't ship until the cost is fixed.** The first fix to try is one shared aggregate per output device.
   - **Measured over budget (2026-09-18):** about 2.2 points per tapped app, linear in the number of apps. Whether a shared aggregate helps is unmeasured. See *Phase 0*.
   - Recorded in `CLAUDE.md`, *Performance budget*.
9. **A fixed never-tap set replaces the editable bypass list.** The set covers DAWs, routing and mixer tools, PopNotch itself, and system daemons that can't be traced to an app. It has no editor and no settings fields. Each bundle ID is verified against a real install before it ships, never guessed. Why not an editable list:
   - **An app at 100% is never tapped,** so dragging a misbehaving app back to 100% already removes its tap.
   - **The headline case, "Spotify down while Logic is up", taps nothing,** because Spotify uses AppleScript.
   - **The remaining DAW risk can't be solved by a list:** a tap on *another* app disturbing a DAW on the same output device. *Phase 0* tests it with GarageBand, and the result decides whether all taps pause while a DAW is running. **Not run (2026-09-18):** GarageBand won't be installed, so this stays unverified and undecided.

### Accepted defaults

- **Mute behaviour: `.mutedWhenTapped`.** It fails open: if PopNotch's audio thread stops or the process dies, the app returns to full volume rather than silence. This is the behaviour the SIGKILL test in *Phase 0* measures. **It passed (2026-09-18):** audio was back within 0.2 s of the kill.
- **One private aggregate per tapped app,** so one app's helper restarting can't glitch another. One aggregate per output device only if the budget is exceeded.
- **The visualiser's global tap excludes PopNotch's own process,** so a re-rendered app isn't counted twice. *Phase 0* test G confirms both the problem and this fix. **Both confirmed (2026-09-18).**
- **What the mixer page lists:**
  - apps playing now, plus apps played this session that are still running
  - apps in the never-tap set, shown greyed with the reason
  - audio that can't be traced to an app, not shown
- **The player's volume button is hidden** when the current player is a system-source app and taps are off.
- **Settings schema v9:** `appVolume { tapsEnabled, volumes[ownerKey] }`. Spotify's and Music's volumes are stored by the apps themselves, not here.
  - **Built in Phase 1 (2026-09-18).** Both fields are optional, and nil is the default: taps off, no saved volumes. `volumes` holds integer slider positions on `PlayerVolume`'s 0 to 100 scale, keyed by `AudioOwner.key`.
  - **Decoding is lenient at every level.** A malformed `appVolume` costs only itself, a malformed field decodes as nil, and a malformed volume loses only its own entry. No throw reaches `SettingsStore`'s catch, which would reset every setting.

### Carried from the plan, not re-decided

The mechanics the plan proposed and the interview did not revisit. They are recorded so they aren't rediscovered:

- **Apps at 100% are never tapped.** A tap exists only while the app is below 100%, playing, not in the never-tap set, on a single stereo device, and permission is granted. It comes down after a short one-shot grace period once the app stops outputting.
- **Everything is event-driven,** with no timers (hard rule 9): the process list, each process's is-running and output-devices notifications, device aliveness, and sample rate. The is-running-output flag is re-read on those notifications, because it sends none of its own (see *Phase 0*, *Answered so far*).
- **Tap, aggregate and IOProc work runs on one serial queue, never main.** `AudioDeviceStart` blocks during the permission prompt. The visualiser currently starts its capture on the main actor, so it has the same exposure.
- **The IOProc allocates nothing and takes no locks.** Gain is ramped across each buffer. On engaging, the gain ramps from 1.0 down to the target; on disengaging it ramps back to 1.0 before the tap is destroyed.
- **App identity follows the public resolution chain** in *Mapping an audio process to its owning app*. It's keyed by the owning app's bundle ID, a synthetic key for web content, or the executable path for unbundled tools. PopNotch's own process is always excluded.
- **Device changes are make-before-break:** the new aggregate is built before the old one is torn down. Devices are keyed by UID, because the dock reconnect in the spike renumbered every device's object ID. Processes on several devices, or on a non-stereo device, are left untouched.
- **A zero-input watchdog catches revoked permission.** Sustained all-zero input while the app reports output triggers one rebuild. If `AudioDeviceStart` then fails, the app falls back to direct playback and the page shows "permission needed".
- **Settings:** 100% is stored as absence. Slider positions are stored, not gains, so the taper can be retuned without a migration. Slider drags write settings only on release.
- **Clean quit tears down in reverse order,** synchronously on the engine queue, from `applicationWillTerminate`. SIGTERM already routes there.
- **Tests never open a real tap.** The engine and the process source sit behind protocols with fakes. The resolver and reconciler are pure functions, tested with fixtures taken from the spike. **Fixed in Phase 1:** `testPauseAfterPlayingLeavesNothingRunning` used to open a real tap. The visualiser now makes its capture engine through an injected factory (`AudioCaptureEngine`), and every test that builds a visualiser passes a fake.

### Phase 0: measure before building

In the spike, not the app. It needs audio, a second participant for the call test, and a GarageBand install. **Run on 2026-09-18:** F passed and v1 proceeds, but the CPU budget is exceeded. The call test and the read-back test are pending, E needs a re-run, whether the engage blip is audible is open, and the DAW test won't run (see *Still open after this run*, below).

| Measurement | Decides |
|---|---|
| **F:** SIGKILL recovery with `.mutedWhenTapped`. **Passed; see below** | **Whether v1 exists** (decision 7) |
| **G:** the visualiser's global tap alongside a re-rendered app, with and without excluding PopNotch's own process. **Answered; see below** | The visualiser default |
| **E:** re-render latency, from the tap callback to audible output. **Provisional; needs a re-run** | Lip-sync risk for browser video |
| **CPU time** with 1 and 3 tapped apps, PopNotch and coreaudiod. **Over budget; see below** | The budget (decision 8) |
| **A Discord call on the laptop speakers,** second participant listening, slider moving. **Pending** | Call-time adjustment (decision 6) |
| **GarageBand running** while another app is tapped on the same device. **Not run; unverified** | Whether taps pause while a DAW runs (decision 9) |
| **Firefox's emitting process,** the owner's main browser, untested in the spike. **Answered; see below** | Its resolution path |
| **Spotify Connect:** what AppleScript `sound volume` does during remote playback. **Answered; see below** | Whether the slider disables during remote playback |
| **Read-back** of a volume changed outside PopNotch (Spotify's own slider, a phone). **Pending** | When to re-read |
| **Level blip when a tap engages or disengages.** **Answered for disengage; engage open** | The ramp design |
| **Whether the is-running-output and devices listeners fire;** tap behaviour when its target exits; in-place tap description update. **All three answered; see below** | The event handling |
| **Frequency response** through the 48 kHz tap into a 44.1 kHz device, at 1, 10 and 16 kHz. **Answered; see below** | Whether the resampling is audible |

**Answered so far:**

- **Spotify Connect (2026-09-17).** With playback on a Connect device, moving the slider **does nothing**: no effect on the remote device, and none locally. Observed by the owner on hardware, with the Phase 2 build. So Spotify's AppleScript `sound volume` doesn't reach a Connect device.
  - **Nothing distinguishes Connect playback before an interaction, so the button stays visible** (decided 2026-09-17). The evidence:
    - **The dictionary has no vocabulary for it.** Spotify 1.3.0.277 exposes eight application properties (`current track`, `sound volume`, `player state`, `player position`, `shuffling`, `shuffling enabled`, `repeating`, `repeating enabled`), and none refers to a device or output. `player state` has only stopped, playing and paused.
    - **Position and state look the same as local playback.** The owner watched the player's scrub bar keep moving during Connect playback. It re-anchors from Spotify's `player position` every 2 s, and only advances while the snapshot says playing, so `player state` read as playing too.
    - **The one difference is in `sound volume` itself, and it only shows after a write.** In the logs, across roughly when the owner switched to Connect and back (times not noted), reads returned 100, and a write of 7 was followed by a read of 100. Locally, writes stick. But a read of 100 before any write proves nothing: the first local read that session was also 100.
  - **Rejected:** Spotify's Web API reports the active device, but it is capped at 25 users and the project stepped away from it deliberately. A hiding rule built on it would work for almost nobody.
- **Spotify reads a written volume back one lower (2026-09-17).** A write of N reads back as N−1, and keeps reading N−1 on every later read: set 52, 65 and 70 read back 51, 64 and 69. Corrected in Phase 2: after a write of N, reads of N−1 or N show as N until any other value is read.
- **Which process listeners fire (2026-09-18).** Measured with a read-only probe while the owner played and paused Spotify, Safari and Chrome, and joined and left a Discord voice channel. The probe checked every flag directly as ground truth. It created no taps and played no audio.
  - **`kAudioProcessPropertyIsRunningOutput` (`'piro'`) never notifies.** A listener on it registers with `noErr` and is never called: 0 callbacks across 31 changes to the flag. A wildcard listener on the same process objects never received it in any scope or element either.
  - **`kAudioProcessPropertyIsRunning` (`'pir?'`) fired for everything except Discord's voice renderer:** 27 of 31 changes, across Spotify, Safari's WebKit helper, Chrome's audio helper, Discord's other helper, system sounds and Control Center. The renderer's 4 changes sent nothing.
  - **`kAudioProcessPropertyDevices` in output scope (`'pdv#'`) fired for all of them,** 31 of 31, the renderer's included.
  - **The flag is already updated when the callback runs.** In a separate run, each callback read the flag as its first action. All 28 callbacks read the new value, matching reads 50 ms, 250 ms and 1 s later, and each of the 16 flag changes got a callback that read it.
  - **So the app listens on both `'pir?'` and `'pdv#'` in output scope, and re-reads the flag in either callback.** Phase 3 shipped this in `606af7d`, with registration failures logged.
  - **PopNotch's own process got no notification of any kind** while its visualiser tap ran: 4 flag changes, 0 callbacks. It is always excluded from the rows, so this doesn't affect them. Its tap runs through a private aggregate device, and the guess is that such I/O isn't announced, which may also explain Discord's renderer. Unverified.
  - **Chrome's audio helper keeps its output open after a pause, so a Chrome row lags a pause.** It stayed on through a pause and a resume, and stopped 64 s after it started, some time after the final pause. So the lag is up to about a minute; its exact length after a pause wasn't timed. The flag is accurate: the helper really is still running I/O.
  - **Evidence:** the probe and its three logs are in `~/PopNotch-spikes/tapspike/evidence/2026-09-18/`.
- **The Phase 0 run (2026-09-18).** In the spike, with FineTune quit. A spike tone process stood in for an app; the built-in microphone was the acoustic probe, on a 19 kHz tone so the owner's music didn't interfere (the microphone's 19 kHz floor stayed between −102 and −111 dB with music playing). Evidence is in `~/PopNotch-spikes/tapspike/evidence/2026-09-18/`.
  - **F, the gate: passed. v1 proceeds.** A `.mutedWhenTapped` tap was muting the tone and re-rendering it, and its process was killed with SIGKILL. The tone was back at its pre-tap level at the microphone (about −58 dB) in the first 0.2 s window after the kill, and the tapped process kept playing.
    - **Not checked:** whether coreaudiod freed the dead process's tap and aggregate. Private taps never appear in the system tap list, even live ones (seen in the target-exit test below), so an empty list after the kill proves nothing.
  - **G: the visualiser does count a re-rendered app twice, and excluding the re-rendering process fixes it.** A global tap read the 19 kHz tone at −12.3 dB with no re-render, −16.9 dB with a muted tap re-rendering it at unity gain, and −12.3 dB again with the re-rendering process excluded.
    - **Why:** a global tap sees both the muted app's original stream and the re-render, and at 19 kHz the two copies partly cancelled. At other frequencies a delayed sum of two copies ranges from nearly +6 dB to a null (arithmetic, not measured).
    - **For PopNotch:** in the spike the re-render and the global tap ran in separate processes. In PopNotch they are one process, so excluding PopNotch's own process is the same exclusion. This confirms the accepted default.
  - **CPU: about 2.2 points of one core per tapped app, over the 2-point budget.** Tones stood in for apps already playing, measured with and without a muted tap re-rendering each one to the same speakers, as v1 does. CPU time over one 60 s window per cell:

    | Tones | Taps | coreaudiod | Tap processes |
    |---|---|---|---|
    | 1 | no | 6.64 s | — |
    | 1 | yes | 7.79 s | 0.19 s |
    | 3 | no | 7.83 s | — |
    | 3 | yes | 11.37 s | 0.54 s |

    - **Per tapped app,** coreaudiod's increase plus the tap processes: 1.34 s in 60 s with one app (2.2 points) and 4.08 s with three (2.3 points each). Linear in the number of apps, and coreaudiod is most of it.
    - **So decision 8 applies:** v1 doesn't ship until the cost is fixed.
    - **Limits:** one run per cell, so run-to-run noise isn't known. The owner's music may have been playing. The spike's IOProc also meters every buffer, so its share is an upper bound for PopNotch's gain-only one. And the runs don't separate a tap's cost from its aggregate's, so whether one shared aggregate per device (decision 8's first fix) helps is unmeasured.
    - **A first attempt was discarded:** BSD `seq 1 0` counts down, so its zero-tap baseline actually ran two taps.
  - **E: provisional, about 100 ms. Needs a re-run.** The tone played 10 ms bursts at 2.5 kHz once a second, re-rendered at unity gain. The tap logged the IOProc entry time of each burst, and the microphone logged each arrival's capture time less its input latency.
    - **Result:** 19 of the tap's 27 bursts paired with a microphone event within 200 ms. 9 of those 19 fell between 96 and 114 ms, 6 within 5 ms of the 100 ms median (mean 100.7 ms).
    - **Why provisional:** the room wasn't quiet. The other pairs, at 0–13 ms and 195–198 ms, were noise tripping the microphone's adaptive detector, and choosing the 100 ms cluster is a judgement. It also measures only the IOProc to the speaker, not the app to the tap before it.
    - **So the lip-sync question isn't answered.** Re-run in a quiet room before Phase 5 relies on it.
  - **Level blip: nothing at disengage; possibly a short gap at engage.** A muted tap re-rendered the 19 kHz tone at unity gain on the same speakers, so the level at the microphone shouldn't move. It was read in 50 ms windows.
    - **Disengage:** every window within 0.7 dB.
    - **Engage:** one window 1.6 dB low. That fits up to about 15 ms of missing audio, or the two paths briefly overlapping out of phase. Whether it's audible on music isn't established, so whether engage needs a crossfade stays open.
  - **Frequency response: flat.** Tones at −70 dBFS read −70.0 dB in the tapped stream at 1, 10 and 16 kHz after resampling into a 44.1 kHz aggregate (the EarPods), and at 1 and 16 kHz into a 48 kHz one (the dock). The 3.4 dB loss in *C* is specific to 19 kHz, near 44.1 kHz's 22.05 kHz Nyquist limit. Measured on the tapped stream, not acoustically.
  - **A tap whose target exits keeps running, silently.** Killing the tapped process turned the tap's stream to all zeros within 0.5 s. Callbacks continued at full rate for the remaining 22 s, and teardown returned no error. So the engine can tear down on the process-list change, with nothing breaking in between.
  - **An in-place description update changes the mute, but only adds processes.** The live tap's `kAudioTapPropertyDescription` was read, changed and set back with the same UUID. Every set returned no error; the readbacks differed.
    - **Mute, `.muted` to `.unmuted`:** read back as unmuted, and the app was audible at the microphone within 0.1 s. The tapped stream hiccupped once at the change: 8 glitch samples, and callback counts of 97 then 90 against a steady 94.
    - **Process list, `[old]` to `[new]`:** read back as `[new, old]`, and the stream then carried both tones. So a process can be added in place. Removing one this way doesn't work; other ways of removing one weren't tried.
  - **Firefox plays from its own process,** `org.mozilla.firefox`, resolved as "the app itself". Taken from PopNotch's Phase 3 log of the owner's real Firefox playback (2026-09-18, 00:09 and 11:57), not a spike run. No helper mapping is needed.
  - **Still open after this run:**
    - **E, re-render latency.** Provisional at about 100 ms; needs a re-run in a quiet room (see *E* above).
    - **Whether the engage blip is audible** on music, which decides whether engage needs a crossfade (see *Level blip* above).
    - **The Discord call echo test.** Pending: no second participant was available.
    - **Read-back of a volume changed outside PopNotch.** Pending: it needs the owner to move Spotify's own slider while a probe watches.
    - **DAW behaviour under taps: unverified.** GarageBand won't be installed (the owner's decision, 2026-09-18). The never-tap set stops a DAW from being tapped, but the risk decision 9 names, a tap on another app disturbing a DAW on the same device, is untested. Whether taps pause while a DAW runs stays undecided.

**D is already done,** on AirPods (see *D* above). Cross-device routing is out of v1 anyway.

### Phases

One session per phase (hard rule 7). Each ends with a clean build, green tests, and a check on hardware.

| Phase | Content | Depends on |
|---|---|---|
| **0. Measure** | The table above | The soak finishing; a second participant; GarageBand |
| **1. Schema** | Settings v9 and its migration test; fix the visualiser test that opens a real tap | — |
| **2. Spotify and Music volume** | AppleScript volume and the player's volume button. **Shippable on its own:** it covers the most frequent moment with no new permission and no tap | Phase 0's Spotify Connect check only (answered 2026-09-17: no effect during Connect playback; see *Phase 0*) |
| **3. Enumerate and name** | Read-only process source and resolver; rows logged, no taps | — |
| **4. Mixer page** | The screen, its door and its row states, behind the Settings toggle | 3 |
| **5. Tap engine** | Taps, aggregates, the IOProc, device changes, quit teardown, the watchdog | **Phase 0's F, E and CPU results** |
| **6. Coexistence** | The visualiser exclusion; a warning when FineTune or Sapphire is running | Phase 0's G result |
| **7. Live with it** | CPU time measured against the budget; a week of daily use; the FineTune decision | 5 |

---

## Clean room

Both reference implementations are named above so the research trail is honest. The rule in `CLAUDE.md` still holds, and holds harder here because this is a bigger and less familiar subsystem than anything PopNotch has built:

- Study **behaviour** — what the apps do, which permissions they prompt for, how they present the UI.
- Do **not** read their source and write PopNotch code in the same session.
- **Check FineTune's licence before opening any of it.** Sapphire is AGPL-3.0, and AGPL contamination is permanent and would close off every commercial option. FineTune's licence has not been checked; assume the worst until it has been.
- Anything learned from an outside implementation gets an entry in `REFERENCES.md`.
