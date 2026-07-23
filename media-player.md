# Media player widget — feature contract

The eww "now playing" / MPRIS widget. This file is the source-of-truth spec for **behavior**.
Implementation details live in the clearly-marked section at the end (and may drift as the
code evolves — the behavior above it should not).

## Behavior goals

1. **Cheap at idle.** Nothing playing + panel closed → no busy work.
2. **Reacts to real changes on its own.** Track / play-pause / a player appearing or
   disappearing reflect within ~1s, including changes from media keys or other apps.
3. **Instant on your own clicks.** Clicking play/pause (or seeking) updates the widget
   immediately — you never wait to see your own action take effect.
4. **No flicker.** Nothing visually rebuilds (album art, rows) just because the seek bar
   advances.

## Bar pill

Layout, left → right: `[ <source-icon>  <title> — <artist>  <play/pause button> ]`

- **Source icon** (left): per-player glyph (spotify / firefox / chrome / mpv-vlc / generic),
  tinted with the player color.
- **Title — artist** (middle): `title` always; ` — artist` only when an artist exists.
  Truncated with ellipsis.
- **Play/pause button** (right): a real button (not the whole pill).  playing /  paused.
- **No progress bar.**
- Whole pill tinted per player (left border in the player color); dimmed when paused.
- Only visible when a player is present.

Interactions:
- **Hover** the pill → opens the panel.
- **Play/pause button click** → toggles play/pause. Does NOT open the panel.
- Tooltip: `title — artist` (fallback for long titles).

## Panel

- **Opens on pill hover; closes on mouse leave** (pointer leaves both the pill and the panel).
- Sits above the bar.
- One row per player, each with: album art (fallback glyph when none), source icon,
  title (click = open the source URL), artist, a click-to-seek scale with mm:ss on both
  sides, and inline transport (prev / play-pause / next).
- Empty state: "Nothing playing".
- Seek bar advances smoothly while a track plays and the panel is open.

## Per-player conventions

- Colors: spotify = green, firefox = orange, chrome = blue, other = aqua.
- Spotify "open source" opens in the Spotify app (spotify: URI), not the browser.
- Two instances of the same app are disambiguated.

---

# Implementation (may drift; not part of the behavior contract)

## Architecture

**Backend — one long-lived Python process** (`scripts/mpris.py`, PyGObject/Gio). A GLib
main loop on the session bus watching `org.mpris.MediaPlayer2.*`:
- `NameOwnerChanged` → player add/remove
- `PropertiesChanged` → status / metadata change

Holds all players' state in memory. Modes:

| Mode | Kind | Emits | Cost |
| --- | --- | --- | --- |
| `state` | deflisten (event-driven) | full player list + active player JSON, **only on real change** | idle = 0 (blocked on D-Bus) |
| `pos` | deflisten (500ms timer) | per-player `{pos,prog,posText}` only — no metadata/art | runs **only while panel open + playing** |
| `playpause`/`next`/`previous` `<player>` | one-shot | — | control |
| `seek <player> <ratio>` | one-shot | — | control |
| `open-url <player>` | one-shot | — | opens source |
| `art <url>` | one-shot | resolved local path | art cache |

**eww vars:**
- `mpris` (deflisten `state`) — pill text/icon/button + panel rows + art.
- `mprispos` (deflisten `pos`) — seek bar / time labels only; merged into rows by `player`.
  Started on panel open, stopped on close.
- `mpris_open` (defvar bool) — panel visibility; set by hover, last-write-wins (no races).

**Separation of concerns** is what kills the flicker: heavy state updates on events only;
the light `pos` channel touches only the seek widgets, so ticking never rebuilds a row.

**Optimistic updates:** play/pause onclick runs the control command AND immediately
`eww update`s a local override so the glyph flips before the D-Bus round-trip; the signal
reconciles right after.

## Live-iteration setup

Writable copy at `scratchpad/eww-live/` (systemd `eww` service stopped; daemon run by hand).
Python backend runs via a compat wrapper simulating the Nix env (MPRIS_ICON_* + PATH +
DBUS_SESSION_BUS_ADDRESS). Reload: `bash scratchpad/eww-live/reload.sh`.

Status:
- [x] `mpris.py` PyGObject/Gio daemon (`state` + `pos` + controls). Verified event-driven.
- [x] Pill: icon + title—artist + play/pause button, no progress bar.
- [x] Panel: hover-open / leave-close via single `mpris_open` var.
- [x] `pos` stream gated on panel-open (eww starts/stops the deflisten with the window;
      `mprispos` passed into `mpris-row` as a param so eww tracks the dependency).
- [x] Data-layer flicker fix verified: `state` var byte-stable while `pos` ticks.
- [ ] Optimistic play/pause — DROPPED for now (D-Bus echo ~200ms feels instant; sticky-
      override bug not worth it). Revisit if 200ms bugs.
- [ ] Visual flicker: confirm rendering doesn't rebuild rows/art on pos tick (looks OK at
      data layer; needs live eyes).

## Port to Nix (after behavior settled)

- `default.nix`: `python3.withPackages (ps: [ ps.pygobject3 ])`; wrapper execs `mpris.py`
  with `MPRIS_ICON_*` + runtime PATH (eww user unit already inherits
  `DBUS_SESSION_BUS_ADDRESS` — verified).
- yuck via `_eww-yuck.nix`: `state`/`pos` deflistens, `mpris_open` defvar, open/close helpers.
- Delete old `scripts/mpris.sh`; restart systemd `eww`.
