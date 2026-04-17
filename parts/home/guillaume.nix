{ inputs, withSystem, ... }:
{
  flake.homeConfigurations.guillaume = withSystem "x86_64-linux" (
    { pkgs, pkgs-unstable, ... }:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        inputs.stylix.homeModules.stylix
        ../../modules/stylix/common.nix
        ../../modules/home-manager.nix
      ];
      extraSpecialArgs = {
        inherit pkgs-unstable;
      };
    }
  );
}
