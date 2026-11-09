# desktop: a machine with a screen.
{ inputs, lib, ... }:
{
  # The graphical session: GDM, niri, pipewire, bluetooth, printing, locale and
  # keyboard layout, plus what every such machine runs (steam, distrobox, zram).
  flake.modules.nixos.desktop = {
    imports = [
      inputs.stylix.nixosModules.stylix
      ./nixos.nix
    ];
  };

  # The session's config and apps: niri, the quickshell bar, vicinae, lock and idle,
  # browsers, terminals.
  flake.modules.homeManager.desktop = {
    imports = [
      ./apps.nix
      ./audio.nix
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
