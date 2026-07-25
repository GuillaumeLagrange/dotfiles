# eww bar

Status bar for niri, built on [eww](https://github.com/elkowar/eww).

## Layout

```
default.nix     Script wrappers (each with its own runtime PATH), the `bins` set of
                absolute paths, xdg.configFile, and three systemd user services.
                Generates eww.yuck from _eww-yuck.nix.
_eww-yuck.nix   The yuck config as a Nix function `{ bins }: "…"`. Underscore-prefixed
                so import-tree does not treat it as a flake module.
eww.scss        Styling (gruvbox material).
scripts/
  bar-launch.sh   Starts the daemon, opens one bar per connected niri output.
  niri-state.sh   One niri event-stream tap -> workspaces + per-output title/dots.
  metrics.py      CPU / memory+swap / disk / battery in one long-lived deflisten.
  mpris.py        Media state, position, and title scrolling over Gio D-Bus.
  calendar.py     Two-month grid data + `push` mode for the popup.
  pulseaudio.sh   deflisten on `pactl subscribe`; volume + sink name.
  settings.sh     Gear badge, idle inhibit, do-not-disturb, power profile.
  idle-inhibit.sh systemd idle lock (status/toggle/reset).
```

`modules/gui/bar-scripts/` holds scripts shared with other bars (Claude usage).

## Services

Three user services under `graphical-session.target`: `eww` (the bar),
`eww-idle-reset` (clears idle-inhibit state on start), and `eww-settings-watch`
(seeds the settings vars, then pushes on external power-profile changes).

Iterate:

```bash
systemctl --user restart eww eww-settings-watch
journalctl --user -u eww -e   # daemon stderr: script-not-found, crashes
eww logs                      # widget / deflisten errors
```

## Design

**The yuck is generated from Nix** so every command is an absolute store path.
eww's `deflisten` does not reliably resolve bare command names on PATH, so
`default.nix` builds a `bins` attrset of absolute paths and interpolates them in.

**eww ships few prebuilt modules.** CPU, disk, battery, volume, clock, and power
profiles are all scripts feeding eww vars that primitives render. eww does provide
`calendar`, `graph`, `circular-progress`, and `systray` (a native SNI host, used
for the tray).

**One `bar` window per output.** eww vars are global, so per-monitor behavior is
threaded through a `monitor` argument: each bar filters workspaces to
`ws.output == monitor` and reads `by_output[monitor]` for its title and dots.

**Event-driven sources push; sampled metrics poll.** `deflisten` for things with a
real event stream (niri, MPRIS D-Bus, `pactl subscribe`), `defpoll` for sampled
metrics (CPU, disk, battery, clock), and `defvar` + `eww update` where an outside
process owns the state (screen recording, settings). There is no signal-number IPC
like waybar's SIGRTMIN; `eww update name=value` is the only push primitive.

The calendar is drawn from scratch rather than using GtkCalendar, whose built-in
`.today` decoration cannot be overridden under eww's CSS (see the `!important`
gotcha below).

## Popups

The media panel, calendar, and settings popups all open on hovering their bar
widget and close when the pointer leaves both the widget and the popup.
`mkHoverPopup` in `default.nix` generates three helpers per popup:

- **open** — touch a keepalive flag, seed content if needed, show the window.
- **keep** — touch the flag only. GTK fires hover/hover-lost as the pointer
  crosses the popup's *child* widgets, so calling `eww` here would re-open the
  window on every crossing and make it flicker.
- **close** — touch a closing marker, wait ~0.3s, then bail if the flag's mtime is
  newer (meaning a re-hover). Otherwise hide the window, then clear the flag.

eww has no dismiss-on-focus-loss, hence the flag-and-hover approach.

`mpris.py`'s position and title-scroll deflistens also gate on the media panel's
flag so they cost nothing while the panel is closed.

## Gotchas

- **The daemon's PATH is not your shell's.** eww runs every deflisten, defpoll, and
  onclick through `sh -c` under the unit's minimal `Environment=PATH`. A script that
  works in your shell fails in production with `<tool>: command not found`, and
  `set -euo pipefail` then kills it mid-output, leaving a blank widget. **Any
  external command a bar script uses must be in `runtimePath`.** Test under the real
  environment — see the repo `AGENTS.md`, "Testing scripts that run under systemd /
  a daemon".
- **Use absolute paths in the yuck** (`${bins.*}`), because `deflisten` does not
  reliably resolve bare command names.
- **Never call `eww` synchronously from an onclick.** It deadlocks against the
  single-threaded daemon that is still running the handler, and eww kills handlers
  after ~1s. Detach with `setsid -f`.
- **eww's CSS rejects `!important`** — one occurrence throws "Junk at end of value"
  and drops the *entire* stylesheet, leaving the whole bar unstyled. Use selector
  specificity instead. Its SCSS parser likewise rejects attribute selectors
  (`[class*="x"]`); use plain classes.
- **Any yuck or scss error means no bar at all.** A single bad widget attribute makes
  the whole config fail to load, so the bar never spawns. When the bar is missing,
  check `journalctl --user -u eww` first.
- **Nerd-font glyphs get silently stripped** from source by some edits, leaving
  zero-width icons. Write them as escapes: `builtins.fromJSON ''"\uf111"''` in Nix,
  `printf '\uXXXX'` in bash.
- **`printf '\uXXXX'` is not portable to the daemon's shell.** It works in an
  interactive bash but emits the literal escape under the daemon's shell. Decode
  glyphs once in Nix and pass them in as environment variables (see `mprisIcons`).
- **JSON `\u` escapes are 4-hex, BMP only.** Astral-plane glyphs (nf-md-*, U+F0000
  and above) need a UTF-16 surrogate pair: U+F0381 becomes `''"\udb80\udf81"''`.
- **Material Design glyphs sit better than FontAwesome in a pill.** fa-cog is
  top-heavy and renders visually high; the MD equivalents are vertically centered.
- **`window { background-color: transparent }`** is needed globally, because eww's
  top-level window node is opaque by default and otherwise shows GTK grey.
- **eww `?.[dynamic-key]` does not resolve** a variable key inside a `for`-generated
  widget — it silently yields empty. Use bracket syntax: `pos[p.player]`.
- **Flakes only see git-tracked files.** New files under `modules/` must be
  `git add`-ed or import-tree will not load them (`undefined variable 'eww'`).
- **`.#homeConfigurations.guillaume` is the headless config**, with no GUI. Build and
  evaluate `nixosConfigurations.badlands.config.home-manager.users.guillaume`.
