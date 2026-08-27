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
