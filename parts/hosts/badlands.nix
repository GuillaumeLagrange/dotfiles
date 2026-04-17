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
        config.flake.modules.nixos.secure-boot
        config.flake.modules.nixos.home-manager-base
        inputs.stylix.nixosModules.stylix
        config.flake.modules.nixos.stylix-common
        ./badlands/_configuration.nix
        inputs.nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
      ];

      _module.args.pkgs-unstable = pkgs-unstable;

      home-manager.users.guillaume.imports = [ config.flake.modules.homeManager.stylix-common ];
    }
  );
}
