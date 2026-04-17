{
  inputs,
  withSystem,
  config,
  ...
}:
{
  configurations.home.guillaume = withSystem "x86_64-linux" (
    { pkgs, pkgs-unstable, ... }:
    {
      inherit pkgs;
      modules = [
        inputs.stylix.homeModules.stylix
        config.flake.modules.homeManager.stylix-common
      ]
      ++ config.homeProfileModules
      ++ config.homeProfileLinuxModules;
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
