# Guillaume's Dotfiles Repository

This is a comprehensive NixOS/Home Manager configuration repository for Guillaume's personal systems.

## IMPORTANT: Applying config

- Do not proactively run the Home Manager / NixOS config switch (e.g. `home-manager switch`, `sudo nixos-rebuild switch`). After making edits, just tell the user to rebuild. Only run the switch yourself if the user explicitly asks you to.

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
   wrapper in `modules/gui/quickshell/default.nix`). If you add a `sed`/`jq`/`awk`/etc. call,
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

### Core Files

- **flake.nix**: Main Nix flake configuration defining system inputs, outputs, and configurations
- **README.md**: Basic usage instructions for NixOS and Home Manager configurations
- **justfile**: `just check` runs every linter and test suite in the repo (`just lint`, `just test`, `just fmt`)

### Hosts Configuration (`hosts/`)

Personal systems configuration:

#### `hosts/badlands/`

- Desktop/workstation configuration
- Files: `configuration.nix`, `default.nix`, `hardware-configuration.nix`

#### `hosts/gullywash/`

- Server configuration with ZFS storage
- **Key Features:**
  - ZFS filesystem support with tuned ARC settings (4GB limit for 16GB RAM)
  - Email notifications for ZFS events via Gmail SMTP
  - Docker virtualization enabled
  - Firewall configured for HTTP/HTTPS and Wireguard
  - Monthly ZFS scrubbing enabled
  - Logrotate configured for memory monitoring logs
- Files: `configuration.nix`, `default.nix`, `hardware-configuration.nix`, `zfs-notifications.nix`

### Modules (`modules/`)

Shared configuration modules:

#### `modules/gui/`

Desktop environment configuration:

- Niri window manager setup
- niri stall tracing (`modules/gui/niri/stall-tracing.nix`, off since the ttm fix below: flip its `enable`), for stutters with no known trigger:
  `niri-stall.service` runs `niri-stall.bt` (bpftrace) and logs each niri event-loop iteration over 30 ms,
  split into on CPU / blocked / waiting for a CPU, with the kernel stack of the longest block, niri's direct
  reclaim/compaction, who held the locks it waited on and what they did, and sampled on-CPU stacks; every 5 s
  of reclaim, who woke kswapd at which order, the xe GPU buffer shrinker, evictions/rebinds and buddyinfo
  (see the script's header); plus an hourly histogram of all iterations. `below` records cgroup/process
  memory, swap, PSI and IO every 5s for 14 days
  (`below replay -t <time>`). Mod+Ctrl+S logs a felt stutter with the PSI of the moment.
  `journalctl -t niri-stall -t stutter` shows both. What it found on granary: on fragmented memory, xe's 2 MB
  GPU allocations wake kswapd, whose xe shrinker evicts every app's GPU buffers; restoring them holds the
  buffer locks niri composites with. `hosts/granary/ttm-reclaim.nix` builds a patched `ttm.ko` out of tree
  whose `max_reclaim_order` parameter, set to 0 on the kernel command line, stops such allocations from
  reclaiming; writing 10 to `/sys/module/ttm/parameters/max_reclaim_order` restores upstream behaviour live.
- quickshell status bar (`modules/gui/quickshell/`) — see `modules/gui/quickshell/AGENTS.md`.
- Firefox browser config
- Wallpapers collection
- Screen locking configuration

#### `modules/headless/`

Server/headless system configuration:

- Tmux terminal multiplexer setup
- Zellij config and helpers; `omp-panel/` is the floating picker (normal-mode `a`) over every omp in every
  zellij session, fed by `ai/omp/extensions/omp-panel.ts`. `omp-panel panes` (normal-mode `z`) lists every
  pane of every session with the command in its foreground, read from /proc (the pane's process carries
  `ZELLIJ_SESSION_NAME`/`ZELLIJ_PANE_ID`, its terminal's foreground group is what runs), filtered as you type
- `reviews/`: ratatui picker over PRs, in two tabs (Tab switches): open ones awaiting my review, and those
  I reviewed updated in the last 14 days, merged/closed included (two concurrent `gh api graphql` searches).
  The description pane renders GitHub markdown itself (`src/markdown.rs`: tables, alerts, task lists, the
  HTML of templates) with images drawn inline; uploads are fetched through the signed URLs of the PR's
  `bodyHTML`. List, avatars and images cached in `~/.cache/reviews/`; the `reviews-refresh` user timer runs
  `reviews --refresh` every 5 minutes while the graphical session is up, so the list opens fresh. The bar's
  PR pill (left of Claude) counts the requested ones from that cache; hovering lists them, clicking the pill
  runs what Mod+Shift+\ does and clicking a PR runs `review --pr URL` without a terminal, as if it were picked:
  `zellij-attach --focus` (also zsm's Enter) focuses the window showing the session or opens one. Off PATH: `review` (`reviews/review.sh`, niri `Mod+Shift+\`) is
  the entrypoint. It opens the pick in a tab `<repo>#<number>` of the `reviews` zellij session, whose wt
  session I create (`wt add` the repo there when it is still a symlink or missing from the mirror; run without a terminal, failures are notifications), checks the PR out and opens diffy
  (closing the tab of another PR of the same repo, after the new one exists so the session never empties),
  then attaches to the session, focuses the window showing it, or switches to it from inside zellij. The
  zellij session is ephemeral: `review` starts it with `--session-serialization false` and deletes a
  resurrectable leftover instead of resurrecting it
- Git push stack utilities
- clangd user config (`~/.config/clangd/config.yaml`): `*.bpf.c`/`*.bpf.h` get the flags libbpf-cargo compiles
  them with (`--target=bpf`, `__TARGET_ARCH_*`, vmlinux.h from `libbpf/vmlinux.h`, libbpf headers)
- GPG public key

#### `modules/stockly/`

Work-specific configurations:

- Insomnia API client
- Development tools

#### `modules/stylix/`

System-wide theming configuration

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
  sends through `:Fixit`.
- `:Fixit [text]` (`nvim/lua/fixit/`): hands what should change to an omp, with a snapshot of the nvim taken
  when it ran (keys typed, cmdline history, messages, windows, config and cwd repo state, `add_context`
  providers under `extra`) written to `~/.local/state/nvim/fixit/`. Without text, a float takes it. The omp
  side is editor-agnostic: `omp-fixit [-s SESSION] [-c FILE] NAME DIR PROMPT` (`modules/headless/omp-fixit.sh`)
  starts `omp --auto-approve` in its own tab of the background zellij session `fixit` (attach to watch, or
  pick it in omp-panel); `ai/omp/extensions/fixit.ts` titles the omp session after NAME, and makes fixit
  omps in the same git repo take turns: tools only run while the omp holds the repo's flock
  (`~/.local/state/omp-fixit/locks/`), taken on its turn's first tool call and released when the turn ends; a
  blocked omp calls `fixit_lock` to wait.

## Home Manager Configurations

### `guillaume`

Full desktop configuration with GUI enabled

### `guillaume@gullywash`

Server configuration with:

- GUI disabled
- Minimal shell setup
- Headless-optimized packages

## Commands Reference

### System Management

```bash
# Apply NixOS configuration
sudo nixos-rebuild switch --flake .#<hostname>

# Apply Home Manager configuration
home-manager switch --flake .#<username>

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
