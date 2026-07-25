# Guillaume's Dotfiles Repository

This is a comprehensive NixOS/Home Manager configuration repository for Guillaume's personal systems.

## IMPORTANT: Applying config

- Do not proactively run the Home Manager / NixOS config switch (e.g. `home-manager switch`, `sudo nixos-rebuild switch`). After making edits, just tell the user to rebuild. Only run the switch yourself if the user explicitly asks you to.

## IMPORTANT: Testing scripts that run under systemd / a daemon

Many things here (eww bar, services) launch scripts from a **systemd unit** or a
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
   shell's. For eww specifically, extract the exact `Environment=PATH` the unit uses and run
   the daemon under it — don't add anything to it:

   ```bash
   EWW=$(nix build --no-link --print-out-paths '.#...eww')/bin/eww
   PATH_LINE=$(nix eval --raw \
     '.#nixosConfigurations.badlands.config.home-manager.users.guillaume.systemd.user.services.eww.Service.Environment' \
     --apply 'x: builtins.elemAt x 0')   # "PATH=/nix/store/...:..."
   env -i HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
     NIRI_SOCKET="$NIRI_SOCKET" "$PATH_LINE" \
     "$EWW" --config "$CFG" daemon --no-daemonize
   ```

3. **Always read the daemon's own logs after a change** — the failure surfaces there, not in
   your test:

   ```bash
   journalctl --user -u eww -e        # unit stdout/stderr (script-not-found, crashes)
   eww logs                           # eww widget/deflisten errors
   ```

   `stderr of \`<var>\`: ... command not found`is the tell-tale of a missing`PATH` entry.

4. **Rule of thumb:** any new external command used in a bar/service script MUST be added to
   that module's runtime `PATH` (e.g. eww's `runtimePath` in `modules/gui/eww/default.nix`).
   If you add a `sed`/`jq`/`awk`/etc. call, add the package in the same change.

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
- eww status bar (`modules/gui/eww/`) — see `modules/gui/eww/AGENTS.md`.
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
