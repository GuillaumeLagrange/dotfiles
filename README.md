# Guiom's Configuration Files

## Usage

### As a NixOS Configuration

1. Clone this repository
2. Make sure flakes are enabled
3. Apply the configuration: `sudo nixos-rebuild switch --flake .#<hostname>`

### As a Home-Manager Configuration

1. Clone this repository
2. Make sure flakes are enabled and Home-Manager is installed
3. Apply the configuration: `home-manager switch --flake .#<username>`

## Content

### nix
The root flake contains my personal configurations and exposes them as NixOS configurations for my hosts, as well as standalone Home-Manager configurations for non-NixOS systems and quick iterations.

### nvim
The [neovim configuration](./nvim) is standalone, and can be used as is. The nix config just creates a symlink to ``~/.config/nvim``.
