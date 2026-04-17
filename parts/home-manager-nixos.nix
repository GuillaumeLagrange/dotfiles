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
      };
      home-manager.users.guillaume = {
        imports = [
          inputs.stylix.homeModules.stylix
        ]
        ++ config.homeProfileModules;
        stylix.overlays.enable = false;
      };
    };
}
