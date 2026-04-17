{ inputs, withSystem, ... }:
{
  configurations.home.guillaume = withSystem "x86_64-linux" (
    { pkgs, pkgs-unstable, ... }:
    {
      inherit pkgs;
      modules = [
        inputs.stylix.homeModules.stylix
        ../../modules/stylix/common.nix
        ../../modules/home-manager.nix
      ];
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
