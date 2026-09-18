# Deferred: per-app audio mixer

**Status: deferred, not started.** Nothing is built. No decision here is final except the deferral itself. A throwaway spike has since measured the mechanism itself, outside the app; see *Spike results*.

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

**Unresolved consequence:** PopNotch's deployment target is **macOS 14.0** (verified in `project.pbxproj`, 2026-08-29). Process taps need **14.2**. Building this means either gating the whole feature behind an availability check or raising the floor to 14.2 — a decision, and one that only the user can act on since it is a build setting (hard rule 1).

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

---

## Why it is deferred until PopNotch ships

Three reasons, none of them technical:

1. **It is the size of a second app.** Even without the driver, this is a mixer: process enumeration, tap lifecycle, per-app state, a UI, and a long tail of apps that misbehave under it. It is not a feature you add to a notch utility in a session.
2. **It is not a notch feature.** In every reference implementation it lives in a **menu-bar popup**, not in the notch — because a mixer wants a list of apps with sliders, which is a panel, not a strip above the bezel. Building it would mean building a second surface with its own design language.
3. **It would bury the differentiator.** System-resource monitoring is the thing PopNotch has that the references do not, and it is already shipped. Adding a large, noisy feature that the competition already has — one of them still in Beta — trades a real advantage for a contested one.

Revisit **after** PopNotch has shipped and been used daily, per the roadmap's own checkpoint about building for a hypothetical user.

---

## Known traps, for whoever builds it

Recorded now because these are the parts that are discovered late and expensively.

- **DAWs, VoIP, and low-level routing apps break under process taps.** They already manage their own audio path, and interposing on it causes glitching, dropouts, or silence. **Logic Pro is the example** — and it is precisely the app named in the original motivating use case ("turn Spotify down while Logic Pro is up"), so the feature's headline scenario is also its worst failure mode. A **per-app ignore/bypass list is not a polish item; it is a v1 requirement**, and it should ship with sensible defaults already populated rather than waiting for users to discover the problem. **Still unverified:** Logic Pro was not installed on the spike machine, so this was neither confirmed nor refuted.
- **The tapped process may not be the app.** Some apps play audio through helper processes, so the PID producing sound does not match the application the user recognises. Naive enumeration will show a helper's name, or attribute audio to the wrong app, or miss it entirely. Mapping helper processes back to their parent application is real work. **Confirmed for both browsers**, and for Safari the mapping has no public-API answer: see *Spike results*, *A*.
- **Only show apps that actually produce audio.** A list built from "running applications" will include Terminal, Finder, and everything else the user has open. The list must be driven by what is actually producing audio, or the UI is a junk drawer.

---

## Spike results (2026-09-16 and 2026-09-17)

**Setup.** A throwaway SwiftPM spike, kept outside the repo at `~/PopNotch-spikes/tapspike`; its README has the run commands. It uses Apple's public API only, and no reference implementation was opened. It ran as its own signed app bundle, launched with `open`, under hardened runtime with **no entitlements**.

**The audio under test** was a tone from a separate spike process standing in for an app, usually 19 kHz so it was near-inaudible. A tap reads samples digitally, so audibility doesn't matter.

**Proof that the device was silent** came from the built-in microphone listening to the built-in speakers, reduced to a 19 kHz level every 0.5 s. That is the only way to prove output silence: a second tap would see the pre-mute stream.

**Confounds.** FineTune was quit for every measurement, because it holds its own taps and would skew them.

**Evidence.** Logs for B and C are in `~/PopNotch-spikes/tapspike/evidence/2026-09-17/`. A's raw logs were lost when a reboot wiped the temp directory the spike first lived in, so the A results below come from the session notes.

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
- **Chrome maps back to its app; Safari does not.** Chrome's helper can be traced by parent PID and bundle ID prefix. `com.apple.WebKit.GPU` has launchd as its parent and a bundle ID naming WebKit, not Safari, and no public API was found that maps it back. Expect every WebKit-based app to present the same way.
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

### The shared-clock measurement, and why D can't run here

The reroute was meant to cross into an **independent** clock. It didn't, because no device on the test machine has one. Each device's sample rate was measured from its IO timestamps against host time:

| Device | Transport | Measured rate vs nominal |
|---|---|---|
| MacBook Air Speakers | built-in | +6.7 ppm (41 s) |
| EarPods | USB | +6.8 to +6.9 ppm (several 8–20 s runs) |
| "Headphones", the dock's USB audio | USB | +6.7 ppm (40 s) |

- **The three agree within about 0.2 ppm.** Independent crystals typically disagree by tens of ppm.
- **The +6.7 ppm is the host clock's offset from the Mac's audio reference**, and both USB devices follow that reference. That's typical of USB audio devices that take their clock from the host's USB frames instead of their own crystal.
- **`kAudioDevicePropertyClockDomain` can't detect independence.** It reported the same value for every device.

**So D, the 30-minute drift soak, was not run: on this hardware it would be a false pass.** With every device on one clock, there is no drift to compensate, and the soak would count zero drift glitches whether or not tap drift compensation works.

D needs **AirPods (Bluetooth) or a USB DAC with its own clock**, and it should be confirmed independent first with the same rate measurement. The spike's `scripts/soak.sh` runs D, the drift-compensation-off control, and the 44.1 kHz-into-48 kHz case.

**Also not run:** E (latency), the SIGKILL half of F, and G (conflict with the visualiser's global tap).

### What this settles

- **The driver correction stands, now measured.** A regular app with no entitlements can mute one process's audio and re-render it, with only one audio-recording prompt.
- **The pieces v1 needs work:** muting at the source, re-rendering, and a gain step. v1 is per-app volume on the device the app already uses. Cross-device routing stays out of scope, and its drift behaviour is still unknown.
- **Still open before building:** Logic Pro's behaviour (the headline case), mapping WebKit helpers back to their app, SIGKILL recovery, and whether PopNotch's own global visualiser tap double-counts a re-rendered app.

---

## Scoping rule

**Version one is per-app volume sliders. Nothing else.**

No EQ. No routing. No multi-device output. Those are the expensive half — in battery, in complexity, and in the number of apps they can break.

Before any of them is considered:

1. Per-app volume is **used daily for a week**.
2. Its **battery cost is measured**, not assumed, against a stated budget.

Only then does EQ or routing get discussed. This is the same discipline the roadmap applies elsewhere: ship the small thing, live with it, then decide.

---

## Clean room

Both reference implementations are named above so the research trail is honest. The rule in `CLAUDE.md` still holds, and holds harder here because this is a bigger and less familiar subsystem than anything PopNotch has built:

- Study **behaviour** — what the apps do, which permissions they prompt for, how they present the UI.
- Do **not** read their source and write PopNotch code in the same session.
- **Check FineTune's licence before opening any of it.** Sapphire is AGPL-3.0, and AGPL contamination is permanent and would close off every commercial option. FineTune's licence has not been checked; assume the worst until it has been.
- Anything learned from an outside implementation gets an entry in `REFERENCES.md`.
