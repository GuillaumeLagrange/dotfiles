{ inputs, ... }:
{
  flake.modules.nixos.home-manager = {
    imports = [ inputs.home-manager.nixosModules.home-manager ];

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.backupFileExtension = "backup";
    home-manager.users.guillaume.stylix.overlays.enable = false;
    # Better eval perf
    home-manager.users.guillaume.manual.manpages.enable = false;
  };
}
