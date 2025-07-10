# Guillaume's Dotfiles Repository

This is a comprehensive NixOS/Home Manager configuration repository for Guillaume's personal systems.

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
- Hyprland/Sway window manager setup
- Waybar status bar
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

## System Information

### Gullywash Server Specs
- **OS**: NixOS 24.11
- **Storage**: ZFS with 4GB ARC limit
- **RAM**: 16GB total
- **Services**: Docker, SSH, Fail2ban
- **Monitoring**: ZFS scrubbing, email notifications
- **Networking**: IPv6 disabled, Wireguard support

### ZFS Configuration
- **Scrubbing**: Monthly automatic scrubs
- **Notifications**: Email alerts for pool events, scrub completion, and errors
- **Tuning**: ARC limited to 4GB, ABD scatter disabled
- **Monitoring**: Comprehensive ZED (ZFS Event Daemon) configuration

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