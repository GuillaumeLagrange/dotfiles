# eww bar — waybar recreation

Recreation of the old waybar setup in [eww](https://github.com/elkowar/eww), on niri.
Feature-parity was the goal; deviations are listed under **Liberties** with reasons.

## Status

- Full `nixosConfigurations.badlands` system builds clean; bar + popups verified live on `eDP-1`.
- Native `systray` renders SNI icons in-bar. Custom two-month calendar, settings/power
  popup, and per-output workspaces all working.
- See **Gotchas** — several bugs here only reproduce under the daemon's real environment;
  test that way (also documented in the repo `AGENTS.md`).

## Apply

```bash
sudo nixos-rebuild switch --flake .#badlands   # or `nh os switch`
```

Three user services come up under `graphical-session.target`:
`eww` (bar), `eww-idle-reset` (clears idle state on start),
`eww-settings-watch` (seeds settings vars + pushes on power-profile change).

Iterate / debug:
```bash
systemctl --user restart eww eww-settings-watch
journalctl --user -u eww -e   # bar-launch / daemon stderr — script-not-found, crashes
eww logs                      # eww widget / deflisten errors
```

## File layout

```
modules/gui/eww/
  default.nix       package, script-bin wrappers (with runtime PATH), bins set,
                    xdg.configFile, 3 systemd services. GENERATES eww.yuck from _eww-yuck.nix.
  _eww-yuck.nix     the yuck config as a Nix function `{ bins }: "…"`. Underscore-prefixed
                    so import-tree does NOT treat it as a flake module. Every command is an
                    absolute `${bins.*}` store path (see "Absolute paths" gotcha).
  eww.scss          styling ported from the old waybar.css (gruvbox material).
  scripts/
    bar-launch.sh   eww daemon + open one bar per connected niri output (3s hotplug poll)
    niri-state.sh   single niri event-stream tap -> workspaces + per-output title/dots
    calendar.sh     custom month-grid emitter (data only) + `push` mode for the popup
    mpris.py        MPRIS state/position/title-scroll over Gio D-Bus + transport
                    (needs pygobject3; see media-player.md)
    cpu.sh          usage% + per-core tooltip
    disk.sh battery.sh   sampled-metric pollers (battery has time-to-full/empty tooltip)
    pulseaudio.sh   deflisten on `pactl subscribe`; emits volume + sink name (tooltip)
    settings.sh     gear/idle/dnd/profile: emit + push (eww update) + watch (dbus)
    idle-inhibit.sh systemd-inhibit idle lock (status/toggle/reset)
modules/gui/bar-scripts/   (renamed from waybar-scripts/) — REUSED VERBATIM
    claude-usage.sh ai-usage-common.sh memory-swap.sh
```

Wired in via `modules/gui/default.nix` (imports `eww`, dropped `waybar`).
Deleted: `waybar.nix`, `waybar.css`, `waybar-scripts/settings_menu.py`.
`screen-tools.nix` was edited to push `screenrecord` state to eww (see below).

## Architecture

- **The yuck is generated from Nix** (`_eww-yuck.nix`), so every command is an absolute
  store path — eww's `deflisten` does NOT reliably resolve bare command names on PATH.
  `default.nix` builds a `bins` attrset of absolute paths and interpolates them in.
- **eww has few prebuilt modules.** cpu/disk/battery/pulseaudio/clock/power-profiles are
  scripts feeding eww vars rendered by primitives. eww *does* ship: `calendar`, `graph`,
  `circular-progress`, and **`systray`** (native SNI host — used for the tray).
- **One `bar` window per output.** `bar-launch.sh` opens `bar --id bar-<output> --screen
  <output> --arg monitor=<output>` per connected niri output. eww vars are global, so
  per-monitor behavior is done by threading the `monitor` arg into widgets.
- **niri-state.sh** re-queries `niri msg workspaces` + `windows` on each relevant event,
  emitting `{workspaces:[...], by_output:{<name>:{title, windows:{count,dots}}}}`. Each bar
  filters workspaces to its own output (`ws.output == monitor`) and reads
  `by_output[monitor]` for its title/dots (matches waybar `separate-outputs`). Safe-access
  `?.` + `?:` guards the initial empty state.

## Data sources: poll vs. push

eww var kinds: `defpoll` (fork a script every N sec), `deflisten` (long-running script
streaming lines), `defvar` (value written from outside via `eww update`). There is **no
signal-number IPC** like waybar's SIGRTMIN — the push primitive is `eww update name=value`.

| var | kind | trigger |
| --- | --- | --- |
| `nstate` (workspaces/title/dots) | deflisten | niri event-stream |
| `mpris` (all players + active) | deflisten | MPRIS D-Bus signals via Gio — event-driven, idle at zero |
| `mprispos` (per-player position) | deflisten 500ms | runs only while the panel is open |
| `mprisscroll` (per-player title frame) | deflisten 180ms | runs only while the panel is open |
| `audio` | deflisten | `pactl subscribe` (event-driven); emits volume + sink name |
| `screenrecord` | defvar (push) | `screen-tools.nix` pushes on record start/stop (instant) |
| `settings`/`idlest`/`dndst`/`profst` | defvar (push) | toggle handlers push; `eww-settings-watch` seeds at startup + pushes on external profile change (dbus) |
| `cal_offset`/`cal_left`/`cal_right` | defvar (push) | `calendar.sh push <base>` from clock click + nav arrows |
| `claude` | defpoll 300s | API, rate-limited |
| `cpu` 3s / `disk` 30s / `memswap` 5s / `battery` 30s | defpoll | sampled metrics — poll is right |
| `clock_main`/`clock_alt` | defpoll 10s | it's a clock |

Rationale: event-driven things push (instant, idle at ~zero); sampled metrics poll.

## Module mapping (waybar -> eww)

| waybar | eww |
| --- | --- |
| niri/workspaces | `workspaces` widget, per-monitor filter, click = focus-workspace |
| custom/niri-windows | `niri-windows`, `by_output[monitor].windows.dots`, click = toggle-overview |
| niri/window | `window-title`, `by_output[monitor].title` |
| custom/screenrecord | `screenrecord-w`, push from screen-tools.nix (instant) |
| mpris | `mpris-w` bar pill (source icon + title—artist + play/pause button; hover opens the panel) + `mpris-popup` panel (album art, scrolling title, read-only progress, per-player transport, title click = MPRIS Raise to that window/tab). One color-railed row per player. See `media-player.md` |
| tray | **native `systray` widget** (`tray-w`) — in-bar SNI host |
| custom/claude-usage | reused `claude-usage.sh`, 300s poll; click refresh / right-click restart (detached) |
| disk / cpu / battery | poller scripts; cpu has per-core tooltip, battery has time-to-full tooltip |
| pulseaudio | `pulseaudio.sh` deflisten; scroll = volume ±1%, click = pavucontrol, tooltip = sink name |
| custom/memory-swap | reused `memory-swap.sh`, 5s poll |
| group/settings drawer | **settings popup panel** (`settings-popup`) — hover the gear; toggle rows with state pills |
| idle_inhibitor | settings row -> `settings.sh toggle-idle` -> `idle-inhibit.sh` (systemd-inhibit) |
| power-profiles-daemon | settings row: left-click = more powerful, right-click = more saving; `eww-settings-watch` catches external changes |
| clock | `clock-w`, hover = calendar popup, right-click = compact-time toggle |

## Popups (media panel, calendar, settings) — open/close model

All three open on **hovering their bar widget** and close when the pointer leaves both the
widget and the popup. `mkHoverPopup` in `default.nix` generates three helpers per popup:

- **open** — trigger hover: touch a keepalive flag, seed content if needed, show the window.
- **keep** — popup hover: touch the flag only. GTK fires hover/hover-lost as the pointer
  crosses the popup's *child* widgets; calling `eww` there would re-open the window on every
  crossing, which flickers.
- **close** — hover-lost: touch a closing marker, wait ~0.3s, and bail if the flag's mtime is
  now newer (a re-hover). Otherwise hide the window, then clear the flag.

**Triggers must be detached** (`setsid -f <helper>`): a handler that calls `eww` back blocks
against the single-threaded daemon that's still running it, and eww kills any handler after
~1s. `keep` is the exception — it only touches a file, so it runs inline.

eww has no dismiss-on-focus-loss, which is why this is done with flags and hover events
rather than a focus-out signal.

## Calendar

Custom-drawn — **not** GtkCalendar. `calendar.sh` emits only *data* (day number,
`other`/`today` flags, ISO week number, month title/year); the yuck renders it as
class-tagged labels so all visuals live in `eww.scss`. Two-month sliding window
(`cal_left` = `cal_offset` months out, `cal_right` = +1); `‹ ›` nav arrows shift both.
Header shows `‹ June 2026   July 2026 ›`.

Why not GtkCalendar: it renders a legible today marker impossible to override under eww's
CSS — the built-in `.today` decoration wins on specificity, and **eww's CSS parser rejects
`!important`** (the only thing that beat it). Abandoned after several attempts; the custom
grid gives full control (today = solid aqua pill).

## Liberties taken (differ from waybar, by necessity/choice)

1. **Idle inhibit** = `systemd-inhibit --what=idle` lock, not the raw Wayland
   `zwp_idle_inhibit` protocol (eww can't hold a Wayland protocol). Works because swayidle
   timeouts + suspend-then-hibernate go through logind.
2. **Clock/calendar** = click opens a custom two-month popup (see Calendar), right-click
   toggles the compact time form. No GTK year-scroll tooltip.
3. **Screenrecord** = instant push from `screen-tools.nix` (replacing waybar's SIGRTMIN+8).
4. **Output hotplug** = `bar-launch.sh` polls `niri msg outputs` every 3s (niri emits no
   output-change event; waybar tracked outputs natively).
5. **Empty workspaces** hidden via `:visible` + collapsed CSS.

## Multi-monitor

Per-output bars, each with its own `monitor` arg. Left side (workspaces/title/dots) is
per-output via `by_output[monitor]`; right-side status is shared (global vars), same as
waybar. Calendar/settings popups open on the clicked bar's monitor (`--screen <monitor>`).
Native `systray` draws on every bar. Hotplug reconciled by the 3s poll. Only tested on a
single output end-to-end — docked multi-output untested.

## Known cleanups / TODO

- [ ] Verify multi-monitor live (docked DP outputs untested end-to-end).
- [ ] Battery `class` uses `charging` for both Charging and Full; waybar had `.plugged` too.
- [ ] `settings.sh` still has unused `profst.icon` / `emit_profile` icon (gauge removed from the row).

## Gotchas learned (so future-me doesn't re-discover)

- **Daemon PATH ≠ your shell PATH.** The eww daemon runs every deflisten/defpoll/onclick via
  `sh -c` under the systemd unit's minimal `Environment=PATH`. A script that works in your
  shell fails in production with `<tool>: command not found` (has bitten `sh`, `sed`), and
  `set -euo pipefail` then kills it mid-output → blank widget. **Any external command a bar
  script uses MUST be in `runtimePath` (default.nix).** Test under the real env, not your
  shell — see repo `AGENTS.md` "Testing scripts that run under systemd / a daemon".
- **Absolute paths in the yuck.** eww `deflisten` doesn't reliably resolve bare command
  names on PATH → use `${bins.*}` absolute store paths (why the yuck is Nix-generated).
- **Never call `eww` synchronously from an onclick.** It deadlocks the single-threaded
  daemon (still running the handler) and hits eww's ~1s onclick kill. Detach with
  `setsid -f <helper>`.
- **eww CSS rejects `!important`** — a single `!important` throws "Junk at end of value" and
  **drops the entire stylesheet** (whole bar goes unstyled). Use selector specificity.
- **Any yuck/scss error = no bar at all.** A single bad widget attr (e.g. an undeclared
  param) makes the whole config fail to load → bar doesn't spawn. When the bar is missing,
  it's almost always a config-load error: check `journalctl --user -u eww`.
- **Nerd-font glyphs get silently stripped** from source by some edits (→ 0-byte icons).
  Write them as codepoint escapes: bash `printf ''`, Nix `builtins.fromJSON ''"‹"''`.
- **`printf '\uXXXX'` is NOT portable to the daemon's shell.** Works in your
  interactive bash but emits the literal escape (not the glyph) under the eww
  daemon's shell/printf. Decode glyphs once in Nix (`builtins.fromJSON`) and pass
  them into the script as env vars (see `mprisIcons` / `MPRIS_ICON_*` in default.nix).
- **JSON `\u` is 4-hex, BMP only.** `builtins.fromJSON ''"\\U000f0381"''` fails
  (`\U` is not JSON). Astral-plane glyphs (nf-md-*, U+F0000+) need a surrogate
  pair, e.g. U+F0381 -> `''"\\udb80\\udf81"''`.
- **FontAwesome vs Material Design glyph metrics.** fa-cog (``) is top-heavy and
  renders visually high in a pill; the MD equivalents (cog `\U000f0493`, gauges) are
  centered. Prefer MD glyphs for in-bar badges.
- **`window { background-color: transparent }`** is needed globally — eww's top-level window
  node is opaque by default, so any window shows GTK grey around its content without it.
- **eww's SCSS parser rejects attribute selectors** (`[class*="x"]`) with "Expected a valid
  selector", which drops the whole stylesheet. Use plain classes.
- **Flakes only see git-tracked files.** New files under `modules/` must be `git add`-ed or
  import-tree won't load them (`undefined variable 'eww'`).
- **import-tree ignores `_`-prefixed files** — that's why the yuck template is `_eww-yuck.nix`
  (it's a plain function, not a flake module).
- **`.#homeConfigurations.guillaume` is the HEADLESS config** (no GUI). The GUI config is
  `nixosConfigurations.badlands.config.home-manager.users.guillaume`. Build/eval THAT.
- **eww's calendar widget is single-month and can't be forced to a fixed month/today style**
  — hence the custom grid.
