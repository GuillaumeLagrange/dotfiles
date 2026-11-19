# desktop: a machine with a screen.
{
  inputs,
  self,
  lib,
  ...
}:
{
  # The bar's tests, on granary's bar (see quickshell/AGENTS.md).
  perSystem =
    { pkgs, ... }:
    {
      checks.quickshell = pkgs.callPackage ./quickshell/tests/check.nix {
        inherit (pkgs.unstable) rustPlatform;
        testEnv = self.nixosConfigurations.granary.config.home-manager.users.guillaume.quickshellTestEnv;
      };
    };

  # The graphical session: the greeter, niri, pipewire, bluetooth, printing, locale
  # and keyboard layout, plus what every such machine runs (steam, distrobox, zram),
  # and gullywash's binary cache.
  flake.modules.nixos.desktop = {
    imports = [
      inputs.stylix.nixosModules.stylix
      ./greeter.nix
      ./nixos.nix
      ./nix-cache.nix
    ];

    options.greeter.wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Image behind the login prompt, on every screen.";
    };
  };

  # The session's config and apps: niri, the quickshell bar, vicinae, lock and idle,
  # browsers, terminals.
  flake.modules.homeManager.desktop = {
    imports = [
      ./apps.nix
      ./audio.nix
      ./easyeffects.nix
      ./firefox.nix
      ./lock.nix
      ./niri.nix
      ./quickshell
      ./vicinae
      ./zellij-sessions.nix
    ];

    # Set by `work-desktop`. niri's and the bar's configs are generated text, so
    # their work bits are switched on from here rather than added from outside.
    options.work.enable = lib.mkEnableOption "the work bits of niri and the bar";
    options.niri.spawnAtStartup = lib.mkOption {
      type = lib.types.listOf (lib.types.listOf lib.types.str);
      default = [ ];
      description = "Extra commands niri runs at startup, as argument lists.";
    };
    options.niri.assignWorkspace = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      description = "Numbered workspace that new windows go to, by app id regex (`niri-workspaces watch --assign`).";
    };
  };
}
