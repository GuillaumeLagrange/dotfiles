{
  inputs,
  withSystem,
  config,
  ...
}:
{
  # IN PROGRESS: mac-mini configuration of my home-manager flake
  configurations.home.codspeed = withSystem "aarch64-darwin" (
    { pkgs, pkgs-unstable, ... }:
    {
      inherit pkgs;
      modules = [
        {
          home.username = "codspeed";
          home.homeDirectory = "/Users/codspeed";
          gui.enable = false;
          stockly.enable = false;
          programs.zsh.oh-my-zsh.theme = "gnzh";
          # GPG agent is forwarded via SSH, prevent local auto-start
          programs.gpg.settings.no-autostart = true;
        }
        inputs.stylix.homeModules.stylix
      ]
      ++ config.homeProfileModules;
      extraSpecialArgs = { inherit pkgs-unstable; };
    }
  );
}
