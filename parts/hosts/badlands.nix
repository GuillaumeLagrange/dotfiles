{
  inputs,
  withSystem,
  mkHomeManagerModule,
  ...
}:
{
  configurations.nixos.badlands.module = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    {
      imports = [
        (import ../../modules/secure_boot.nix { lanzaboote = inputs.lanzaboote; })
        inputs.home-manager.nixosModules.home-manager
        inputs.stylix.nixosModules.stylix
        ../../modules/stylix/common.nix
        ../../hosts/badlands/configuration.nix
        inputs.nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
        (mkHomeManagerModule { inherit pkgs-unstable; } {
          extraModules = [ ../../modules/stylix/common.nix ];
        })
      ];
    }
  );
}
