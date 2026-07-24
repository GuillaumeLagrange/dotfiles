# Media player widget — feature contract

The eww "now playing" / MPRIS widget. This file is the source-of-truth spec for **behavior**.
Implementation details live in the clearly-marked section at the end (and may drift as the
code evolves — the behavior above it should not).

## Behavior goals

1. **Cheap at idle.** Nothing playing + panel closed → no busy work.
2. **Reacts to real changes on its own.** Track / play-pause / a player appearing or
   disappearing reflect within ~1s, including changes from media keys or other apps.
3. **Reasonably responsive to your own clicks.** Play/pause reflects on the next `state`
   emit (~200ms D-Bus echo), which reads as near-instant.
4. **No flicker.** Nothing visually rebuilds (album art, rows) just because the progress bar
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
  title (**click = jump to that player's window**), artist, a **read-only** progress bar
  with mm:ss on both sides, and inline transport (prev / play-pause / next).
- **Full title on hover** (tooltip is gone from the pill — that's the panel's job); when a
  title overflows its column it **marquee-scrolls**: a single copy scrolls to the last
  character, holds, then snaps back to the start (not a seamless dual-copy loop). Scroll
  runs at a **constant pace**, so each row's cycle length ∝ its own title length and rows
  never wait for one another (short titles cycle fast, long ones slow).
- Empty state: "Nothing playing".
- Progress bar advances smoothly while a track plays and the panel is open. It is a
  display only — no click-to-seek (was buggy across players).
- **Length-less media** (live streams, some web media with no `mpris:length`): no progress
  bar or end time — a red **LIVE** badge shows next to the elapsed time instead
  (`has_length` flag gates it).

### Jump to window (title click)

Clicking a title raises the player's window via the **MPRIS `Raise` method** and **closes
the panel**. `Raise` is compositor-agnostic, crosses workspaces, and — crucially — is
tab-accurate: the MPRIS session is bound to the exact browser tab, so Firefox/Chromium
raise the window AND switch to the playing tab. No compositor IPC or window-title matching
needed. (Players advertising `CanRaise: false` do nothing — rare.)

## Active player

The pill shows the **active player** — defined as *whatever your media keys will control*.
This is synced to `playerctld` (the MPRIS proxy media keys route through): the active player
is the one whose trackid matches what `playerctld` currently forwards. Falls back to a
Playing player, then the first present, if `playerctld` isn't running.

- The active player changes on play/pause/status changes (following `playerctld`) and updates
  the pill live.
- The active notion **never reorders the panel** — panel rows are sorted stably by player and
  only change when a player is created/destroyed.

## Per-player conventions

- Colors: spotify = green, firefox = orange, chrome = blue, other = aqua.
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
| `focus <player>` | one-shot | — | MPRIS `Raise` (jump to window/tab) |
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
- [x] Flicker FIXED. Root cause was NOT position updates — it was the panel's own
      onhover/onhoverlost re-running open/close on GTK hover churn over internal widgets,
      re-`eww open`ing the window every event. Fix: panel hover only touches a keepalive
      flag (`mpris-keep`, no eww calls); the debounced close checks the flag. No window
      churn → no flicker.

## Port to Nix (after behavior settled)

- `default.nix`: `python3.withPackages (ps: [ ps.pygobject3 ])`; wrapper execs `mpris.py`
  with `MPRIS_ICON_*` + runtime PATH (eww user unit already inherits
  `DBUS_SESSION_BUS_ADDRESS` — verified).
- yuck via `_eww-yuck.nix`: `state`/`pos` deflistens, `mpris_open` defvar, open/close helpers.
- Delete old `scripts/mpris.sh`; restart systemd `eww`.
