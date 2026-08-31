# References

Required by the clean-room policy in `PROJECT-CONTEXT.md`. Every technique learned from an outside implementation gets an entry here, whether or not it felt significant at the time.

## Why this file exists

Several macOS notch and overlay apps are AGPL-3.0 licensed. AGPL is strong copyleft: if PopNotch source is ever found to be derived from theirs, the entire app must be published under AGPL. That is permanent and cannot be undone by deleting the code later.

This file is the evidence that PopNotch was written independently. An empty log is not proof of nothing borrowed — it is an absence of records, which is worse than an honest entry.

## The rule

1. Read the reference to understand the **technique**.
2. **Close it.** Close the tab, close the file, close the repo.
3. Write PopNotch's implementation from the concept, not from recall of the source.
4. Log it below.

Never have a reference implementation open in one window and PopNotch open in another. This applies to the assistant too — see the reference-implementations section in `CLAUDE.md`.

Reading Apple documentation, Apple sample code, Stack Overflow answers, and WWDC sessions does not require an entry. Those are reference material for the platform, not another product's source.

## Log

| Date | Technique learned | Source | License | How PopNotch implements it |
|---|---|---|---|---|
| | | | | |

<!--
Example of a good entry:

| 2026-08-27 | Notch rect can be derived from auxiliaryTopLeftArea / auxiliaryTopRightArea rather than hardcoded per model | general knowledge of NSScreen API, confirmed in Apple docs | n/a | NotchGeometry.notchRect(for:) computes the gap between the two auxiliary areas, with a fallback strip when safeAreaInsets.top is zero |

An entry names a *concept*. If an entry is specific enough that someone could
reconstruct the original source from it, the line was already crossed.
-->

## Sapphire (observed 2026-08-27)
UI observation only — screenshots of its onboarding/permissions screen and
its collapsed "wings" (artwork + waveform flanking the housing). No source
code read. Notables: permissions listed plainly with per-row Request
buttons; wings shown only while a session is active; "private API login"
for Spotify free-tier features (deliberately not copied — official Web API
only, if ever).

## Sapphire feature analysis (reviewed 2026-08-28)

A written analysis of Sapphire's advertised feature set was reviewed —
compiled from its public marketing site, FAQ, changelog, and README.
**No source code was read**, by the user or by the assistant.

The analysis included a listing of top-level directory names in their
repository. Directory names are not source, but reading them is the
closest this project has come to the line, and it is recorded here for
that reason rather than because anything was taken from it. Nothing in
PopNotch was written or changed on the strength of it.

What it changed: nothing in the code. It produced a ranked candidate
list in `ROADMAP.md` and a competitive-position section in
`PROJECT-CONTEXT.md`, both of which are statements about PopNotch's
priorities. The analysis file itself is deliberately kept outside this
repository.

One technique was named and **not adopted**: reading MediaRemote by
spawning an Apple-signed interpreter, to get around the caller-identity
gate. It was already independently discovered and documented as "path 2"
in `PopNotch/Modules/Media/FINDINGS.md` on 2026-08-27, from PopNotch's
own measurements, before this analysis was read. It remains unchosen.

## Shelf UI layout (2026-08-30)

The drag-in chooser (Add to Shelf | AirDrop zones) and the "File Drops"
resting-shelf layout were replicated from full-screen captures Joshua
supplied of a third-party notch shelf UI (app unidentified). Dimensions
were measured off the captures at this display's 0.735 px-to-point scale:
540pt panel with 230x125 zones mid-drag, ~687pt panel at rest — the
latter is why NotchPanel's expanded width ceiling rose 540 -> 690.
Appearance only; no source was consulted, and the compact "1 File" state
visible in the captures was deliberately not adopted.
