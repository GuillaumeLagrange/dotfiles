{
  inputs,
  withSystem,
  config,
  ...
}:
{
  configurations.nixos.badlands.module = withSystem "x86_64-linux" (
    { pkgs-unstable, ... }:
    {
      imports = [
        (import ../../modules/secure_boot.nix { lanzaboote = inputs.lanzaboote; })
        config.flake.modules.nixos.home-manager-base
        inputs.stylix.nixosModules.stylix
        ../../modules/stylix/common.nix
        ../../hosts/badlands/configuration.nix
        inputs.nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
      ];

      _module.args.pkgs-unstable = pkgs-unstable;

      home-manager.users.guillaume.imports = [ ../../modules/stylix/common.nix ];
    }
  );
}
