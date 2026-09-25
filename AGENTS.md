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

- Niri (primary) / Sway window manager setup
- quickshell status bar (`modules/gui/quickshell/`) — see `modules/gui/quickshell/AGENTS.md`.
- Firefox browser config
- Wallpapers collection
- Screen locking configuration

#### `modules/headless/`

Server/headless system configuration:

- Tmux terminal multiplexer setup
- Git push stack utilities
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
