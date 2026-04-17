{ inputs, config, ... }:
{
  flake.modules.nixos.home-manager-base =
    {
      pkgs-unstable,
      ...
    }:
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
      ];

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.backupFileExtension = "backup";
      home-manager.extraSpecialArgs = {
        inherit pkgs-unstable;
        hmModules = config.flake.modules.homeManager or { };
      };
      home-manager.users.guillaume = {
        imports = [
          inputs.stylix.homeModules.stylix
          ../modules/home-manager.nix
        ];
        stylix.overlays.enable = false;
      };
    };
}
