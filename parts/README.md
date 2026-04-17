# `parts/` — flake-parts modules

This directory contains every Nix file in the repo. `flake.nix` auto-imports
all `.nix` files under `parts/` via [`vic/import-tree`](https://github.com/vic/import-tree);
they are flake-parts modules.

## Layout

```
parts/
├── flake-parts.nix           # Imports the flake-parts sub-modules we use
├── systems.nix               # systems = [ "x86_64-linux" "aarch64-darwin" ]
├── pkgs.nix                  # perSystem pkgs / pkgs-unstable via _module.args
├── lib.nix                   # sshPublicKey (read from parts/headless/guiom_ssh.pub)
├── configurations-nixos.nix  # configurations.nixos.<name>.module option + flake.nixosConfigurations derivation
├── configurations-home.nix   # configurations.home.<name> option + flake.homeConfigurations derivation
├── home-manager-nixos.nix    # flake.modules.nixos.home-manager-base: wire home-manager into NixOS hosts
├── home-manager-profile.nix  # flake.modules.homeManager.profile: shared home-manager base
├── home-profile-modules.nix  # homeProfileModules + homeProfileLinuxModules lists (the menu hosts import)
├── secure-boot.nix           # flake.modules.nixos.secure-boot (lanzaboote)
│
├── headless/                 # Terminal tools: tmux, zellij, zsh, git, neovim, etc.
│   ├── main.nix              # Cross-platform bits (flake.modules.homeManager.headless)
│   ├── main-linux.nix        # Linux-only bits (flake.modules.homeManager.headless-linux)
│   ├── tmux.nix  zellij.nix  zsh.nix
│   └── _gitPushStack.nix  _untar.nix   # Underscore-prefix = derivations, not modules
│
├── gui/                      # Desktop: hyprland, niri, sway, waybar, firefox, etc.
│   ├── default.nix           # flake.modules.homeManager.gui (main body)
│   ├── options.nix           # Shared options (term, monitors, audio commands, etc.)
│   ├── <feature>.nix         # Each = flake.modules.homeManager.gui-<feature>
│   └── _move-to-bottom-right.nix  # Script producer, not a module
│
├── codspeed/                 # CodSpeed-specific tools (aliases, scripts, packages)
│   ├── default.nix           # Cross-platform
│   └── linux.nix             # Linux-only (mongodb-compass, kcachegrind, valgrind)
│
├── stockly/                  # Stockly-specific tools
│   ├── default.nix
│   └── _insomnia.nix  _monster.nix    # Derivations
│
├── stylix/                   # Shared theming (works across homeManager + nixos)
│   ├── common.nix            # Declared under both classes
│   └── home-manager.nix      # homeManager-only target disables
│
├── home/                     # Standalone home-manager configurations (one per user/host)
│   ├── guillaume.nix         # guillaume@desktop (linux)
│   ├── gullywash.nix         # guillaume@gullywash (linux)
│   └── codspeed.nix          # codspeed@mac-mini (darwin)
│
└── hosts/                    # NixOS hosts
    ├── badlands.nix          # Wires configurations.nixos.badlands.module
    ├── gullywash.nix         # Wires configurations.nixos.gullywash.module
    ├── iso.nix               # Installation ISO
    ├── _common.nix           # Shared NixOS config, imported by _configuration.nix files
    ├── badlands/             # NixOS configuration fragments for this host
    │   ├── _configuration.nix
    │   ├── _hardware-configuration.nix
    │   ├── _oneleet.nix
    │   └── watch-downloads.sh
    └── gullywash/
        ├── _configuration.nix
        ├── _hardware-configuration.nix
        └── _zfs.nix
```

## Conventions

### Underscore prefix: `_foo.nix`

Any `.nix` file starting with `_` is skipped by `import-tree`. Use it for:

- **Derivation producers** (`_gitPushStack.nix`, `_insomnia.nix`): files that
  return a derivation via `pkgs.writeShellScriptBin` / `pkgs.callPackage`,
  not a flake-parts module.
- **NixOS configuration fragments** (`_configuration.nix`, `_hardware-configuration.nix`,
  `_zfs.nix`): they're NixOS modules, consumed by a host-level `.nix` file via
  `imports = [ ./foo/_configuration.nix ]`. If they weren't underscore-prefixed,
  `import-tree` would try to load them as flake-parts modules and crash.

### Named modules: `flake.modules.<class>.<name>`

The backbone of this config. Each feature file looks like:

```nix
{
  flake.modules.homeManager.my-feature =
    { pkgs, config, ... }:
    {
      # …a regular home-manager module…
    };
}
```

`<class>` is one of `homeManager`, `nixos`, `darwin`, `generic`, etc.
`<name>` is a unique identifier (typically the feature name, prefixed by a
category like `headless-`, `gui-`, etc.). The value is a home-manager / NixOS
module — anything a regular module file would contain.

Hosts and home configs include feature modules by referencing
`config.flake.modules.<class>.<name>` in their module list.

### The `homeProfileModules` / `homeProfileLinuxModules` menu

Every home-manager consumer (standalone `configurations.home.*`, or the
host-embedded `flake.modules.nixos.home-manager-base`) picks its module
list from these two options:

- `homeProfileModules` — cross-platform stuff (always included).
- `homeProfileLinuxModules` — Linux-only additions.

Linux hosts append both. Darwin hosts append only `homeProfileModules`. This
is the *only* place the linux/darwin split happens — individual feature files
are written for one class and one class only.

## Common tasks

### Add a new home-manager feature

1. Create `parts/<category>/<feature>.nix`:
   ```nix
   {
     flake.modules.homeManager.<category>-<feature> =
       { pkgs, ... }:
       {
         # …module body…
       };
   }
   ```
2. Add `<category>-<feature>` to the list in `parts/home-profile-modules.nix`
   (either `homeProfileModules` or `homeProfileLinuxModules` depending on
   portability).
3. `nix flake check --no-build` to verify.

### Add a Linux-only piece to an existing feature

1. Create `parts/<category>/<feature>-linux.nix` as a separate named module.
2. Add it to `homeProfileLinuxModules`.

Do **not** add `lib.optionals pkgs.stdenv.isLinux` inside cross-platform
modules — the whole point of the split is to avoid those checks.

### Add a new NixOS host

1. Create `parts/hosts/<hostname>.nix` declaring
   `configurations.nixos.<hostname>.module`. Import the NixOS modules you
   want (typical: `config.flake.modules.nixos.home-manager-base` plus a
   `./<hostname>/_configuration.nix`).
2. Create `parts/hosts/<hostname>/_configuration.nix` and
   `_hardware-configuration.nix` with the standard NixOS content. Import
   `../_common.nix` for shared system config.

### Add a new standalone home-manager config

Create `parts/home/<name>.nix`:
```nix
{ inputs, withSystem, config, ... }:
{
  configurations.home.<name> = withSystem "<system>" (
    { pkgs, pkgs-unstable, ... }:
    {
      inherit pkgs;
      modules = [
        inputs.stylix.homeModules.stylix
      ]
      ++ config.homeProfileModules
      ++ config.homeProfileLinuxModules;  # drop on darwin
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
```

## Gotchas

### Infinite recursion when one named module references another

If `flake.modules.homeManager.foo` does
`imports = [ config.flake.modules.homeManager.bar ]`, you'll get infinite
recursion. Named modules that need other named modules should not cross-import;
instead, the **consumer** (a host or home config) lists both in its own
module list.

This is why `parts/home-profile-modules.nix` exists: it's the one place where
a flat list of named modules is expanded.

### `nix flake check` operates on the git snapshot

New files must be `git add`ed before they're visible to flake evaluation.
When debugging "attribute missing" errors on a freshly created file, check
`git status` first.

### `nixpkgs.hostPlatform` on NixOS hosts

The dendritic `nixosSystem { modules = [ module ]; }` call doesn't pass a
`system` argument. `nixpkgs.hostPlatform` must be set somewhere — most hosts
inherit it from `parts/hosts/_common.nix`; the ISO sets it inline.
