{ inputs, withSystem, ... }:
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
        ../../modules/home-manager.nix
      ];
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
