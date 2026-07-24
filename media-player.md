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
- When a title overflows its column it **marquee-scrolls**: scrolls one character at a
  time to the last character, holds ~1.5s, then resets to the start. Each row scrolls on
  its own length, independently. The panel width stays fixed regardless of content
  (emoji included). Reset happens only after the panel is hidden — no glimpse on reopen.
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
| `pos` | deflisten (500ms timer) | per-player `{pos,prog,posText}` only — no metadata/art | runs **only while panel open** |
| `scroll` | deflisten (180ms timer) | per-player current title FRAME (window slice) — backend string rotation | runs **only while panel open** |
| `playpause`/`next`/`previous` `<player>` | one-shot | — | control |
| `focus <player>` | one-shot | — | MPRIS `Raise` (jump to window/tab) |
| `art <url>` | one-shot | resolved local path | art cache |

**eww vars:**
- `mpris` (deflisten `state`) — pill text/icon/button + panel rows + art.
- `mprispos` (deflisten `pos`) — seek bar / time labels only; merged into rows by `player`.
- `mprisscroll` (deflisten `scroll`) — per-player scrolling title frame; merged into rows.
- `mpris_open` (defvar bool) — panel visibility; set by hover, last-write-wins (no races).

**Separation of concerns** is what kills the flicker: heavy state updates on events only;
the light `pos`/`scroll` channels touch only their own widgets, so ticking never rebuilds a row.

**Marquee = backend string rotation.** `scroll_frames()` slices the title into a fixed-width
window (start-hold, one window per char, end-hold); the daemon advances an index per tick.
The label has a fixed `min-width` so variable-width emoji can't resize the panel. `mpris-close`
hides the window *before* clearing the open-flag, so the daemon's reset frame lands in an
already-hidden label.

**The hover model is shared** with the calendar and settings popups: `mkHoverPopup` in
`default.nix` generates an open/keep/close trio per popup (see the Gotchas on why `keep` must
not call `eww`). The media panel is the only one whose flag also gates deflistens.

## Gotchas

- **Popup hover must not re-open the window.** GTK fires `onhover`/`onhoverlost` on a popup's
  eventbox as the pointer crosses its child widgets; if those re-run `eww open`/`update`, the
  window churns and flickers. Popup hover only refreshes a keepalive flag (the `*-keep` helper,
  no `eww` call); a debounced close checks the flag's mtime to detect a re-hover.
- **eww `?.[dynamic-key]` doesn't resolve** a variable key inside a `for`-generated widget
  (silently empty). Index with bracket syntax — `pos[p.player]` — instead.
- **`pos`/`scroll` deflistens are gated on panel-open** via `OPEN_FLAG`, and the vars are
  passed into `mpris-row` as params so eww tracks the dependency and starts the deflisten.
- Session bus: the eww user unit inherits `DBUS_SESSION_BUS_ADDRESS`. MPRIS_ICON_* glyphs are
  decoded in Nix (the daemon shell mangles `\uXXXX`).
