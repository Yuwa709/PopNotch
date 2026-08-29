# Deferred: per-app audio mixer

**Status: deferred, not started.** Nothing is built. No decision here is final except the deferral itself.

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

- **DAWs, VoIP, and low-level routing apps break under process taps.** They already manage their own audio path, and interposing on it causes glitching, dropouts, or silence. **Logic Pro is the example** — and it is precisely the app named in the original motivating use case ("turn Spotify down while Logic Pro is up"), so the feature's headline scenario is also its worst failure mode. A **per-app ignore/bypass list is not a polish item; it is a v1 requirement**, and it should ship with sensible defaults already populated rather than waiting for users to discover the problem.
- **The tapped process may not be the app.** Some apps play audio through helper processes, so the PID producing sound does not match the application the user recognises. Naive enumeration will show a helper's name, or attribute audio to the wrong app, or miss it entirely. Mapping helper processes back to their parent application is real work.
- **Only show apps that actually produce audio.** A list built from "running applications" will include Terminal, Finder, and everything else the user has open. The list must be driven by what is actually producing audio, or the UI is a junk drawer.

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
