# desktop: a machine with a screen.
{ inputs, lib, ... }:
{
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
    ];

    # Set by `work-desktop`. niri's and the bar's configs are generated text, so
    # their work bits are switched on from here rather than added from outside.
    options.work.enable = lib.mkEnableOption "the work bits of niri and the bar";
  };
}
