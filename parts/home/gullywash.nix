{
  inputs,
  withSystem,
  config,
  ...
}:
{
  configurations.home."guillaume@gullywash" = withSystem "x86_64-linux" (
    { pkgs, pkgs-unstable, ... }:
    {
      inherit pkgs;
      modules = [
        {
          gui.enable = false;
          codspeed.enable = false;
          programs.zsh.oh-my-zsh.theme = "gnzh";
        }
        inputs.stylix.homeModules.stylix
      ]
      ++ config.homeProfileModules
      ++ config.homeProfileLinuxModules;
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
