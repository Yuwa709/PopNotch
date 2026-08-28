# Blocked items

Unattended session, 2026-08-28. Each entry: what was attempted, what stopped it, what is needed.

## Item 3 (partial): Music track-level property audit

**Done:** Spotify's eight query properties all verified callable against the live app (plus `starred` re-confirmed broken, and `popularity` confirmed working). Music's application-level properties (`player state`, `shuffle enabled`, `fixed indexing`) verified callable; `player position` while stopped returns `missing value` rather than erroring, which is worth knowing.

**Blocked:** the nine Music *track-level* properties in `MusicAdapter.queryScript` (`name`, `artist`, `album`, `duration`, `persistent ID`, `favorited`, `index`, `count of artworks`/`data of artwork 1`, `lyrics`).

**Why:** they can only be executed against a real track. At audit time Music was running but `player state` was `stopped`, `current track` threw -1728, and the library-track proxy failed because `count of tracks of library playlist 1` is **0** — the Music library on this machine is empty. The two ways to unblock both change your state (start playback in Music, or add tracks to the library), which this session's rules forbid.

**What I need from you:** play or pause any track in Music, then run:

```bash
for prop in 'name of t' 'artist of t' 'album of t' '(duration of t as text)' '(persistent ID of t as text)' '(favorited of t as text)' '(index of t as text)' '(count of artworks of t as text)'; do
  printf '%-34s -> ' "$prop"
  osascript -e "tell application \"Music\"
    set t to current track
    return $prop
  end tell" 2>&1 | head -1
done
```

Paste the output into the audit table in `PROJECT-CONTEXT.md`, replacing the UNVERIFIED row. Thirty seconds, and it is the same check that would have caught `starred` before it shipped.

## Item 5 (partial): README screenshot

The README is written, but ROADMAP's Phase 5 spec calls for a screenshot and that needs a human with eyes on the physical display — the expanded notch against the real bezel is exactly the thing I cannot see or verify. A `TODO(user)` placeholder marks the spot in `README.md`; drop the image in as `docs/screenshot.png`.

One editorial call to check: the README says binary releases don't exist yet and points people at `scripts/install.sh`. If you publish a Release, update the Install section.
