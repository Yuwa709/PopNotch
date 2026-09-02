# Phase 4 experiment: MediaRemote on macOS 26.5.2

Ran 2026-08-27 on the target machine (15" MacBook Air, macOS 26.5.2),
Spotify playing throughout. Every claim below was measured, not assumed.

## What was tested

| Probe | Context | Result |
|---|---|---|
| `dlopen` + `MRMediaRemoteGetNowPlayingInfo` | `swift` CLI (Apple-signed toolchain) | **Full data**: 17 keys — title, artist, album, 600×600 JPEG artwork (70KB), duration, elapsed, media type |
| Same call | Inside signed, hardened-runtime PopNotch.app | **Empty dictionary.** Same instant, same track; CLI re-probe returned data simultaneously |
| Required symbols (`GetNowPlayingInfo`, `IsPlaying`, `Register/UnregisterForNowPlayingNotifications`, `SendCommand`, client identity, notification constants) | dlsym | All present and resolvable |

## Conclusion

The macOS 15.4 restriction is **caller-identity gating, live and enforced
on 26.5**: MediaRemote returns now-playing data only to processes it
trusts (Apple platform binaries / entitled callers). The framework loads
and every symbol resolves in-app — the data callback simply returns `{}`.
The gating entitlement is private and not grantable.

Not yet measured in-app: whether `MRMediaRemoteSendCommand` (transport
control) is also gated, or only the metadata read. Test before assuming
controls need the fallback too.

## Consequences for the module

- `MediaRemoteClient` (kept, working code) cannot be the data source while
  the app is signed normally. Its `isAvailable` guard and empty-callback
  path are the graceful degradation.
- The viable paths, in order of preference:
  1. **AppleScript per player** for Spotify and Apple Music: both expose
     rich scripting (track, artist, album, artwork URL / raw artwork,
     play/pause/skip). Needs the Automation permission per target app
     (`NSAppleEventsUsageDescription` is already configured). This covers
     the two players the product actually promises.
  2. **Helper spawning an Apple-signed interpreter** to read MediaRemote
     (the mediaremote-adapter technique used by some notch apps): system
     `perl` is a platform binary and passes the gate, but the approach
     leans on an undocumented loophole Apple may close. Recorded as a
     known option, not chosen — clean-room rules apply (no reading that
     project's source while writing ours).
  3. An always-running dedicated helper with alternate signing: rejected —
     complexity and fragility for no user-visible gain over 1.
- Pandora and YouTube Music have no scripting interface; without
  MediaRemote there is no system-wide fallback for them. Out of scope
  until the landscape changes.

## Decision

Chosen: **path 1 (AppleScript adapters)**, user-approved 2026-08-27,
with the module architected so a MediaRemote-based source can slot back
in if Apple relents or path 2 is later validated.
