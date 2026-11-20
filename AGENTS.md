# Guillaume's Dotfiles Repository

This is a comprehensive NixOS/Home Manager configuration repository for Guillaume's personal systems.

## IMPORTANT: Applying config

- Do not proactively run the Home Manager / NixOS config switch (e.g. `home-manager switch`, `sudo nixos-rebuild switch`). After making edits, just tell the user to rebuild. Only run the switch yourself if the user explicitly asks you to.

## IMPORTANT: Patching third-party software

- Ask before patching the source of software I did not write (niri, quickshell, any nixpkgs package or flake
  input), and say what the patch would be for. Prefer a solution through the program's existing interfaces,
  even a less clean one; I decide whether a patch is worth carrying.

## IMPORTANT: Testing scripts that run under systemd / a daemon

Many things here (the quickshell bar, services) launch scripts from a **systemd unit** or a
long-running **daemon**, which run with a **minimal, locked-down `PATH`** — only the
binaries the module explicitly put there. Your interactive shell has a huge `PATH`, so a
script that works when you run it by hand can still fail in production with
`<tool>: command not found` (this has bitten `sh`, `sed`, and others repeatedly, and with
`set -euo pipefail` the script dies mid-output → the widget silently shows nothing).

**Never validate such a script using your own shell's PATH.** Test it the way the daemon
actually launches it:

1. **Reproduce under the real environment, not your shell.** Prefer running the _installed
   wrapper_ (which exports its own `PATH` internally) rather than the raw `.sh`:

   ```bash
   # Build the config's package set and run the wrapper as installed:
   HP=$(nix build --no-link --print-out-paths \
     '.#nixosConfigurations.badlands.config.home-manager.users.guillaume.home.path')
   "$HP/bin/<wrapper>"        # runs with the module's PATH, like the daemon
   ```

   To catch a _missing_ dependency, strip your PATH so only the wrapper's own PATH counts:

   ```bash
   env -i HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
     WAYLAND_DISPLAY="$WAYLAND_DISPLAY" NIRI_SOCKET="$NIRI_SOCKET" \
     PATH=/run/current-system/sw/bin "$HP/bin/<wrapper>"
   ```

2. **Test a daemon by launching a throwaway instance with the config's env**, not your
   shell's. For the bar, stop the unit and run the installed binary in the foreground with
   only the session variables it needs:

   ```bash
   systemctl --user stop quickshell
   env -i HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
     NIRI_SOCKET="$NIRI_SOCKET" PATH=/run/current-system/sw/bin \
     "$HP/bin/qs" -c bar
   ```

3. **Always read the daemon's own logs after a change** — the failure surfaces there, not in
   your test:

   ```bash
   journalctl --user -u quickshell -e   # QML errors, script-not-found, crashes
   ```

4. **Rule of thumb:** any new external command used in a bar/service script MUST be reached
   by absolute store path or added to that script wrapper's `PATH` (e.g. the `claudeUsage`
   wrapper in `modules/desktop/quickshell/default.nix`). If you add a `sed`/`jq`/`awk`/etc. call,
   add the package in the same change.

5. **A nested compositor hijacks the session's systemd environment.** Running a headless
   `sway`/`wayland` instance to render a widget is fine, but sway imports its own
   `WAYLAND_DISPLAY` into the systemd user manager on start. Once it exits, every user
   service that restarts — `quickshell` among them — dies, because the display it is told
   to use no longer exists. Put the session's values back afterwards:

   ```bash
   systemctl --user set-environment WAYLAND_DISPLAY=wayland-1 DISPLAY=:0
   dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY
   systemctl --user restart quickshell
   ```

   Recover the right values from a process the real compositor spawned
   (`tr '\0' '\n' < /proc/$(pgrep -f kitty | head -1)/environ`), not from your shell.

## Repository Structure

### Root files

- **flake.nix**: inputs, and the list of every file that defines something (see below)
- **README.md**: the machines, how to rebuild, how the repo is laid out, for humans
- **Justfile**: `just check` runs every linter and test suite in the repo (`just lint`, `just test`); `just format` rewrites every file with its language's formatter. The crates are every directory with a tracked `Cargo.lock`. `just test` is the local loop, incremental in each crate's `target/`. `just ci` is what CI's test step runs, and runs the same anywhere: `nix flake check`, where each package of `pkgs/` runs its tests in its build, with the programs they drive as `nativeCheckInputs` (a test without its program fails, never skips), the `review` check runs `review.sh`'s and the `quickshell` check (defined by the desktop group, on granary's bar) the bar's; a check is only rebuilt, so its tests only rerun, when what it is built from changed. Plus `ai/omp`'s npm tests, the one suite that is no nix build yet, in the devshell
- **devshell.nix**: `devShells.default`, the one shell for working here and for CI, entered by `.envrc` (`use flake`) and by the workflow, force-added like the hooks' config. It holds the tools the Justfile and the hooks call (formatters, prek, nextest, nix-update), Rust (cargo, rustc, clippy, rustfmt and rust-analyzer of nixpkgs-unstable, the same `unstable.rustPlatform` the crates of `pkgs/` build with, `rust` in `pkgs/default.nix`, so tests, clippy and packages share one rustc that moves with the unstable input), and every program the tests drive: the locked zellij, `script`, jq, git, direnv, node, the same the packages' builds get as `nativeCheckInputs`. A program a test needs goes in both
- **.pre-commit-config.yaml**: pre-commit hooks run by prek (`just hooks` installs them): each language's formatter on the staged files, then `cargo fmt` and clippy for each crate the commit touches. A hook that rewrites a file fails the commit; stage the result. Force-added: the global gitignore excludes the file name

### How the Nix code is organised

flake-parts, without import-tree: `flake.nix` imports every file that defines a flake output or a
named module, so the name of a module leads to its file. Four kinds of file, told apart by where
they sit and by their first lines:

| kind  | where                                                 | what it holds                                                                                                                                          |
| ----- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| host  | `hosts/<name>/default.nix`, `hosts/installer.nix`     | `flake.nixosConfigurations.<name>`: the groups, the host's own parts, and the home its user gets                                                      |
| home  | `homes/<name>.nix`                                    | `flake.modules.homeManager.<name>`: groups plus identity lines (username, prompt, zellij accent); `flake.homeConfigurations.<x>` when built standalone |
| group | `modules/<name>.nix` or `modules/<name>/default.nix` | `flake.modules.nixos.<name>` and/or `flake.modules.homeManager.<name>`: the imports of its parts, what needs `inputs`/`self`, and the group's options  |
| part  | any other `.nix` under `hosts/<x>/` or `modules/<x>/` | a plain NixOS or home-manager module, starting with `_class = "nixos";` or `_class = "homeManager";`                                                   |

Rules:

- `self.modules.<class>.<name>` is defined in `modules/<name>` or `homes/<name>.nix` and nowhere else:
  flake-parts merges every definition of a name without complaint.
- Imports point down only: host → home → group → part → `pkgs/`. Groups do not import other groups.
- Only hosts, homes and groups see `self`/`inputs`. Parts get everything through module args; whatever
  comes from an input is imported by the part's group.
- A program I wrote is a package in `pkgs/`, `pkgs.<name>` everywhere through the overlay; modules only
  configure.

| host         | NixOS groups                                            | home                                       |
| ------------ | ------------------------------------------------------- | ------------------------------------------ |
| `badlands`   | core desktop laptop secure-boot work                    | `work-laptop`                              |
| `granary`    | core desktop laptop encrypted-disk secure-boot work     | `work-laptop` + `hosts/granary/easyeffects.nix` |
| `snakewater` | core desktop encrypted-disk secure-boot                 | `personal-desktop` + `hosts/snakewater/easyeffects.nix` |
| `gullywash`  | core                                                    | `server` + blue zellij accent              |

| home               | home-manager groups                   | standalone output |
| ------------------ | ------------------------------------- | ----------------- |
| `work-laptop`      | core shell desktop work work-desktop | —                 |
| `personal-desktop` | core shell desktop                    | —                 |
| `server`           | core shell                            | `.#guillaume`     |
| `codspeed-mac`     | core shell work                       | `.#codspeed`      |
| `cloud`            | core shell work                       | `.#headless` (impure: user and system from the environment, see `scripts/bootstrap-headless.sh`) |

### Hosts (`hosts/`)

- `badlands`: work laptop
- `granary`: Framework laptop (Core Ultra series 3), work. Its own parts: `caffeine.nix` (closing the lid
  locks and blanks instead of suspending, driven from the bar's control centre), `keylightd.nix` (keyboard
  backlight), `fingerprint-led.nix` (the power button's LED blinks while fprintd waits for a finger:
  alejandroqh/framework-fingerprint-led-blink, sandboxed, writing the LED through a udev-granted group),
  `ttm-reclaim.nix` (see stall tracing below), `easyeffects.nix` (Framework's Dolby speaker tuning),
  `btintel-pcie.nix` (btintel_pcie.ko built out of tree with Intel's PM fixes from 7.4: 7.3's `.thaw`
  re-probes the controller, its firmware reload races `.poweroff` and aborts hibernation; drop it once
  the kernel has them).
  Mod+W and Mod+Shift+W open the Work and Perso firefox profiles (`firefox.mainProfile`/`altProfile`, see
  `modules/desktop/firefox.nix`); elsewhere the last used profile and a new instance
- `snakewater`: personal gaming/dev desktop: Ryzen 7800X3D, RTX 4080 (proprietary driver, open kernel module,
  LTS kernel so the out-of-tree module builds, both from nixos-unstable for a current driver), Sunshine server (KMS capture, NVENC). Same disk layout as
  granary (`encrypted-disk`): LUKS2 partition unlocked by the TPM alone (PCR 7, secure boot through
  lanzaboote), btrfs subvolumes `root`/`nix`/`log`/`home`/`swap`. No work tooling: it imports neither the
  `work` NixOS group (1Password, Oneleet) nor the home-manager ones, so no codspeed tools, `wt`, `cdr`, omp MCP
  servers of `ai/omp/mcp.json`, `review` with its refresh timer and bar pill, 1Password autostart or Slack.
  Its own part: `easyeffects.nix` (Arctis Nova Pro Wireless: headphone EQ; mic RNNoise, gate and EQ).
  niri starts Steam and Discord, through the desktop
  group's `niri.spawnAtStartup` (argument lists, appended to niri's `spawn-at-startup` lines). Steam waits a
  second first, or it exits silently when niri spawns it (niri-wm/niri#2463). Steam and Battle.net (Proton's
  `steam_app_default`, which every non-Steam shortcut gets) go to workspace 3, Discord to 5
- `gullywash`: home server: ZFS (`zfs.nix`: ARC limit, scrubs, mail notifications), Docker, firewall for
  HTTP/HTTPS and WireGuard, nightly config backup, the Nix binary cache `nix-cache.gullywash.glagrange.eu`
  (`nix-cache.nix`, behind the Traefik of `~/homelab_stack`) and the self-hosted GitHub runner that runs
  the checks and then builds the hosts on every push (`github-runner.nix`, `.github/workflows/build.yml`,
  roots in `/var/lib/ci-roots`),
  Dependabot's nightly flake update PR included (`.github/dependabot.yml`).
  `hosts/gullywash/README.md` has the steps no config holds (signing key, password, runner token); keep it
  current when either changes
- `installer.nix`: the installation ISO
- `guiom_ssh.pub`: my SSH key, authorized on the hosts that run sshd

### Groups (`modules/`)

#### `core`

Every host (nix settings, my user, home-manager wiring, the overlay) and every home (identity, xdg dirs,
fonts, the stylix theme). It assumes no screen: stylix's GUI targets and dconf stay off until `desktop`
turns them on.

#### `shell`

The terminal on any machine: zsh, git, fzf, atuin, editors and language servers, tmux, and zellij with its
helpers (`zsm`, `zsk`, the rename and close keybinds' scripts, `omp-fixit`). Also:

- `ai.nix`: links the omp config of `ai/omp` into `~/.omp/agent`
- clangd user config (`~/.config/clangd/config.yaml`): `*.bpf.c`/`*.bpf.h` get the flags libbpf-cargo compiles
  them with (`--target=bpf`, `__TARGET_ARCH_*`, vmlinux.h from `libbpf/vmlinux.h`, libbpf headers)
- `self.lib.zellijAccent "<base16 slot>"`: a module that recolours zellij's accent, so a session on another
  machine is told apart

#### `desktop`

A machine I sit in front of: the greeter, niri, pipewire, bluetooth, printing, steam and gullywash's binary cache
(`nix-cache.nix`, password in a hand-written `/etc/nix/netrc`, see `hosts/gullywash/README.md`) on the NixOS
side; niri's config, the bar, vicinae, firefox, kitty, hyprlock/swayidle and the apps on the home-manager side.

- Greeter (`greeter.nix`): greetd runs Noctalia Greeter (from `pkgs.unstable`, set up by hand: unstable's
  module needs options stable lacks). Its own compositor shows the login box on every screen at its preferred
  mode and scale, over `greeter.wallpaper` (set by the host, a `greeter-wallpaper.jpg` next to it); it opens on
  my password, with the last session (kept in `/var/lib/noctalia-greeter/sync.toml`) picked. Colours are
  stylix's. The password unlocks gnome-keyring through greetd's PAM service; fingerprint is off there.
- EasyEffects (`easyeffects.nix`): `easyeffects.autoload.<preset> = { device; profile; preset = ./file.json; }`
  installs the preset and loads it on that device and profile (`hosts/granary/easyeffects.nix`,
  `hosts/snakewater/easyeffects.nix`); any other device gets the empty `Flat` preset, on input and output.
  Unset, EasyEffects does not run.
- Display setups (`pkgs/niri-displays/displays.py`, `niri-displays`): no monitor's mode, scale or position is in
  the config. Arrange them with anything (wdisplays, `niri msg output`), then save the layout under a name from
  the control centre's Displays section (+); its cards draw each setup's monitors to scale, a click applies one,
  the × on hover deletes it. A setup records the monitors it turns on ("make model serial") and fits wherever
  those are connected, whatever else is: applying it turns the others off. The section hides the setups that do
  not fit behind a "Show N for other screens" toggle (kept across opens). Mod+M / Mod+Shift+M open the control
  centre and move a keyboard preselection over the setups that fit (from the one on screen, arrows and Tab too),
  Enter applies it. The `niri-displays` user service (`watch`) applies, at login and whenever a monitor is plugged
  or unplugged, the setup last used with exactly the connected monitors, else the one turning the most of them on;
  it leaves a layout changed by hand alone otherwise. Applying a
  setup focuses the focused output again, so the cursor follows outputs that moved; at login the top-left one
  instead of niri's first by name. Saved in `~/.local/state/niri-displays/setups.json`. What the IPC cannot set
  (the KTC's side struts) stays an `output` block in the niri config. Tests:
  `modules/desktop/quickshell/tests/tests/displays.rs`.
- sway-like numbered workspaces (`pkgs/niri-workspaces/workspaces.py`, `niri-workspaces`): none is declared in
  the config; Mod+N / Mod+Shift+N run `niri-workspaces focus|move N`, which names an empty workspace of the
  focused output N when N does not exist yet and puts it in place before switching (so niri slides to it), and
  unnames an empty one left behind so niri removes it. The `niri-workspaces` user service (`watch`) keeps them so
  for what niri's own actions do (Mod+J/K, opening a window on an unnamed workspace, hotplug), gives an output
  showing an unnamed workspace (at niri's start, or once its last one moved to another output) the lowest free
  number, sorts each output's numbers, and sends windows to the workspace `niri.assignWorkspace` gives their app
  id (`--assign`; Signal/Spotify to 5 everywhere, hosts add theirs). It talks to niri's socket by
  id: `niri msg` reads a name like "1" as an index. Tests: `modules/desktop/quickshell/tests/tests/workspaces.rs`.
- quickshell status bar (`modules/desktop/quickshell/`) — see `modules/desktop/quickshell/AGENTS.md`.
- zellij session colours (`zellij-sessions.nix`, `pkgs/zellij-sessions/`): each session gets a colour of the
  palette there (stylix's red, yellow, green, blue and purple: its orange and aqua are too close to their
  neighbours to tell apart as a dot), set and changed from omp-panel's side pane, never declared. It
  shows as the session's zellij accent (a `session-<colour>` theme: stylix's with `zellijAccent`'s three
  slots recoloured), as a border on its terminal windows (window rules in `~/.local/state/zellij-sessions/niri.kdl`,
  an optional `include` at the end of niri's config), and as a dot on the bar's strip blocks and workspace map.
  The registry (`~/.local/state/zellij-sessions/sessions.json`: name, colour, folded, in display order) is the
  only state; the rest is derived from it on every change. zellij only takes a theme when its server starts,
  so a session is started on a config of its own (`zellij-sessions config NAME`: zellij's config plus its
  `theme`), which `zellij-attach`, wt and `review` pass with `--config`; zellij live-reloads that file, so a
  recolour reaches a running session. Sessions started before have no such config: they get theirs once
  restarted, and their windows' border and dot meanwhile.
- `commands.nix`: the commands the desktop's parts share (lock, screenshot and screen recording, the terminal,
  calls into the bar). Not a module: parts `import` it.

#### `work`

CodSpeed. `work` (any machine I work from, terminal or not): codspeed tools and aliases, `wt`, `review` and its
refresh timer, the `cdr`/`WORKSPACE_ROOT` zsh snippet, the omp MCP servers of `ai/omp/mcp.json`.
`work-desktop`: Slack, dbeaver, kcachegrind, the mac-mini ssh entry, and `work.enable` for niri's review
bindings, 1Password autostart and the bar's PR pill. Its NixOS side: 1Password and Oneleet.

#### `laptop`, `encrypted-disk`, `secure-boot`

Lid, battery and fingerprint reader (with the sudo PAM rules); the TPM-unlocked LUKS + btrfs swapfile layout
of granary and snakewater; lanzaboote.

#### `stall-tracing`

Imported by no host since the ttm fix below; add `self.modules.nixos.stall-tracing` to a host to record again.
For stutters with no known trigger: `niri-stall.service` runs `niri-stall.bt` (bpftrace) and logs each niri
event-loop iteration over 30 ms, split into on CPU / blocked / waiting for a CPU, with the kernel stack of the
longest block, niri's direct reclaim/compaction, who held the locks it waited on and what they did, and sampled
on-CPU stacks; every 5 s of reclaim, who woke kswapd at which order, the xe GPU buffer shrinker,
evictions/rebinds and buddyinfo (see the script's header); plus an hourly histogram of all iterations. `below`
records cgroup/process memory, swap, PSI and IO every 5s for 14 days (`below replay -t <time>`). Mod+Ctrl+S
logs a felt stutter with the PSI of the moment. `journalctl -t niri-stall -t stutter` shows both. What it found
on granary: on fragmented memory, xe's 2 MB GPU allocations wake kswapd, whose xe shrinker evicts every app's
GPU buffers; restoring them holds the buffer locks niri composites with. `hosts/granary/ttm-reclaim.nix` builds
a patched `ttm.ko` out of tree whose `max_reclaim_order` parameter, set to 0 on the kernel command line, stops
such allocations from reclaiming; writing 10 to `/sys/module/ttm/parameters/max_reclaim_order` restores
upstream behaviour live.

### Programs (`pkgs/`)

One directory each, with its `package.nix`; `pkgs/default.nix` is the overlay that makes each `pkgs.<name>`,
and exposes them as `.#<name>`. It also patches niri, one patch per feature in `niri/` (hot-corner delay and
barrier, middle click closing a window in the overview, the `WindowPreview` IPC request behind the bar's
workspace map, app icons and titles on the overview's tiles; a new feature gets its own file) and adds `pkgs.unstable`, whose
quickshell (the bar's) is patched to take virtual sinks and sources, such as EasyEffects' source, for
devices (`quickshell/virtual-devices.patch`).

- `wt/`: feature-scoped multi-repo workspaces (see its README). Installed by the `work` group.
- `omp-panel/`: the floating picker (zellij normal-mode `a`, or niri `Mod+A`/`Mod+BackSpace` in its own
  floating kitty window, app-id `omp-panel`) over every omp in every zellij session, fed by
  `ai/omp/extensions/omp-panel.ts`. On the left, one tree: every live session (its colour dot, the rollup of
  its omps), its omps under it. `J`/`K` reorder the selected row's session, space folds it (its omps leave the
  list, Tab skips them; `h`/`l` fold, unfold and move between a session and its omps), `c`/`C` cycle its
  colour (`zellij-sessions`' registry, shared with niri and the bar). Enter on an omp jumps to it, on a
  session opens it. Per omp: state and time in it, title, tab, the running tool while working, else the start
  of its last reply. On the right, framed in the session's colour, the selected omp's conversation (on a
  session, its first omp's), read from the tail of its session file along the current branch (tool runs
  folded into one line), opened on the last question, with cwd and git branch/ahead/behind/dirty above, model,
  context % and whether a client shows it below; `^u`/`^d` scroll back. `s` switches between the tree and one
  list by priority (kept in `~/.local/state/omp-panel/sort`), Tab goes to the next blocked/done one (layout
  borrowed from herdr's sidebar). `omp-panel panes` (normal-mode `z`) lists every
  pane of every session with the command in its foreground, read from /proc (the pane's process carries
  `ZELLIJ_SESSION_NAME`/`ZELLIJ_PANE_ID`, its terminal's foreground group is what runs), filtered as you type
- `reviews/`: ratatui picker over PRs, in three tabs (Tab switches): open ones awaiting my review, those
  I reviewed updated in the last 14 days, merged/closed included, and my own open ones (three concurrent
  `gh api graphql` searches). PRs not updated in 60 days are hidden until `a` shows them; a stack shows whole
  as long as one member is fresh (`stacks::stale`).
  Each PR carries the Linear issues linked to it (`src/linear.rs`): one `linear api` request per list asks
  `attachmentsForURL` for every PR URL, the link Linear's GitHub integration records, so it holds whatever the
  branch is named. Linear failing or absent leaves them out. The picker shows their identifiers by state, the
  issues in the description pane, `i` opens them; the bar's cards show them too, and both filters match them.
  The description pane renders GitHub markdown itself (`src/markdown.rs`: tables, alerts, task lists, the
  HTML of templates) with images drawn inline; uploads are fetched through the signed URLs of the PR's
  `bodyHTML`. List, avatars and images cached in `~/.cache/reviews/`; the `reviews-refresh` user timer
  (`modules/work/review.nix`) runs `reviews --refresh` every 5 minutes while the graphical session is up, so
  the list opens fresh. The bar's PR pill (left of Claude) shows what `reviews --json` prints: every tab from
  that cache, laid out with their stacks as the picker shows them, with and without the stale ones, so the CLI
  is the bar's only source. The pill counts the requested ones; clicking it or Mod+" lists the tabs (the last
  picked one and the "Show N stale" toggle are kept across opens; typing filters, Tab cycles the tabs, Up/Down
  or Ctrl+P/Ctrl+N move, Left/Right reach the PR's Linear issues, Enter picks). It opens with no PR selected,
  unless the focused window's zellij tab (`review-tab` in `modules/desktop/quickshell/default.nix`) is a review
  tab `<repo>#<number>` one of the tabs lists: that tab and PR are selected. The panel's refresh button runs
  `reviews --refresh`, its terminal button runs what Mod+Shift+\ does, right-clicking a PR opens it on GitHub
  (the picker's Shift+Enter), clicking one of its Linear issues opens that in the browser, and clicking a PR runs
  `review --pr URL` (`review --mine URL BRANCH` in My PRs) without a terminal, as if it were picked:
  `zellij-attach --focus` (also zsm's Enter) focuses the window showing the session or opens one. Off PATH:
  `review` (`pkgs/reviews/review.sh`, niri `Mod+Shift+\`) is the entrypoint. A PR to review opens in a tab
  `<repo>#<number>` of the `reviews` zellij session, whose wt session I create (`wt add` the repo there when it
  is still a symlink or missing from the mirror; run without a terminal, failures are notifications), checks
  the PR out and opens diffy (closing the tab of another PR of the same repo, after the new one exists so the
  session never empties). One of mine opens on the repo's tab of the wt session whose worktree has its branch
  checked out (`wt tabs` lays out the members' tabs first); else on the repo's tab of the main checkout's
  session (`wt main`, root `wt main --path`), checking the branch out there unless it has uncommitted changes
  (a submodule merely at another commit does not count: `git submodule update` follows the checkout). Then it
  attaches to the session, focuses the window showing it, or switches to it from inside zellij.
  `tests/review.rs` drives `review.sh` headless against real git, wt and zellij, in a fixture with its own
  `XDG_RUNTIME_DIR`, stubbing `zellij-attach`, `notify-send` and `gh`. No package runs it: `review-tests.nix`
  is the flake's `review` check, handing it the wt package as `WT_BIN`; locally it builds wt from `pkgs/wt/`.
- `niri-state/`: the niri IPC tap the bar reads its layout model from (see its AGENTS.md)
- `niri-workspaces/`, `niri-displays/`: see the desktop group above
- `zellij-attach/`, `mux-name/`: attach to a zellij session by name, and name a tab after a directory; shared
  by the shell and work groups and by `review`, `wt` and `omp-panel`. niri's Mod+\ (`zsm`) and Mod+Shift+\
  (`review`) run in a floating kitty window, app-id `zellij-picker`; `zellij-attach` run from it (found by
  `KITTY_PID`) opens the session in a new tiled `zellij-session` window instead of in place, and the picker closes
- zellij's CLI (0.46) races with itself: the server gives each connection the lowest free client id and tears
  the previous holder of an id down after it may already be handed out again, so a connection can lose its
  own messages or get the late ones of the one before it. Every `zellij action` first probes the session's
  socket, and that check can fail on a live session (`There is no active session!` / `Session '…' not found`,
  nothing sent); `list-sessions` can leave a live session out; a query can print nothing or another command's
  answer; a mutation can return before it took effect. And the server waits a hard-coded 1s for an action,
  then exits 2 with `Action … did not complete within 1s, its outcome is unknown` (`Timeout listing tabs|panes`
  for those two): the action is not cancelled, so on a loaded machine (CI) any action can say so. Anything
  scripting zellij retries a not-found action, retries a query until its answer parses or for as long as it
  times out, takes a timed-out mutation as sent (never resends it), confirms an absence over several
  listings, and waits for a mutation's effect (`run`/`query`/`act` in `pkgs/wt/crates/core/src/zellij.rs`,
  `pkgs/omp-panel/src/zellij.rs`, `act`/`ask` in `review.sh`, and the tests' own helpers). No wait has a
  fixed deadline: it ends on an outcome (the state reached, the session or the client process gone), and
  in tests a state that never comes is nextest's `terminate-after`, with `waiting for …` as the last line of
  output. Counted retries are only for zellij's races, never for time. `zellij attach --create` on a
  session it wrongly thinks gone starts a second server that takes the name over, so `zellij-attach` only
  passes `--create` for a session no listing shows; `switch-session` reconnects that way inside zellij, out
  of reach: omp-panel's switch test runs again when `beta` was replaced or the client dropped. Every fixture
  SIGKILLs (zellij catches SIGTERM) the servers under
  its directory when dropped, and on creation those of fixtures whose `.fixture` marker is gone: an orphaned
  server re-creates its directories, and a test nextest killed never dropped its fixture
- `cargo-tools/`: Rust CLIs nixpkgs lacks, which would otherwise be `cargo install`ed: one `<name>.nix` each
  (today only `linear`, schpet's linear-cli), listed in the overlay as `pkgs.cargoTools.<name>` and exposed as
  `.#<name>`. `just bump [NAME [VERSION]]` runs nix-update on them: latest release (crates.io or GitHub) and
  both hashes. Tools nixpkgs has are taken from `pkgs.unstable` instead.

### Neovim Configuration (`nvim/`)

Standalone Neovim configuration with:

- Lazy.nvim plugin manager
- LSP, DAP, and completion setup
- Lua-based configuration
- AI integrations
- Tmux integration
- `nvim/plugin/diffy.lua`: loads diffy, the diff viewer and review plugin (replaces diffview), from its own
  private repo `GuillaumeLagrange/diffy` checked out at `~/projects/diffy`. Usage, code and tests live there.
  It adds diffy's `debug_state()` to `:Fixit` snapshots while a diffy session is open, and `:Diffy feedback`
  sends through `:Fixit`. A review submitted to GitHub (`User DiffyReviewSubmitted`) starts the
  `reviews-refresh` user service, so the bar's PR pill and the picker drop it without waiting for the timer.
- `:Fixit [text]` (`nvim/lua/fixit/`): hands what should change to an omp, with a snapshot of the nvim taken
  when it ran (keys typed, cmdline history, messages, windows, config and cwd repo state, `add_context`
  providers under `extra`) written to `~/.local/state/nvim/fixit/`. Without text, a float takes it. The omp
  side is editor-agnostic: `omp-fixit [-s SESSION] [-c FILE] NAME DIR PROMPT` (`modules/shell/omp-fixit.sh`)
  starts `omp --auto-approve` in its own tab of the background zellij session `fixit` (attach to watch, or
  pick it in omp-panel); `ai/omp/extensions/fixit.ts` titles the omp session after NAME, and makes fixit
  omps in the same git repo take turns: tools only run while the omp holds the repo's flock
  (`~/.local/state/omp-fixit/locks/`), taken on its turn's first tool call and released when the turn ends; a
  blocked omp calls `fixit_lock` to wait.

## Commands Reference

```bash
# Apply the NixOS configuration of this machine
nh os switch                 # or: sudo nixos-rebuild switch --flake .#<hostname>

# Apply a standalone home (guillaume, codspeed, headless)
home-manager switch --flake .#<name>

# Build installation ISO
nix build .#nixosConfigurations.guiom-nixos-installation.config.system.build.isoImage
```

### ZFS Operations

ZFS tools are installed system-wide on gullywash. Common commands:

```bash
# Check pool status
zpool status

# List snapshots
zfs list -t snapshot

# Create snapshot
zfs snapshot <dataset>@<snapshot-name>

# Destroy snapshot
zfs destroy <dataset>@<snapshot-name>
```

## Security Features

- SSH key-based authentication only
- Fail2ban intrusion detection
- Firewall configuration
- GPG agent enabled
- No root password authentication

## Development Environment

- Docker containerization
- Nix development shells
- Comprehensive editor setup (Neovim)
- Git configuration and tools
