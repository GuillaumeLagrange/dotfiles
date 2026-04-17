{ lib, config, ... }:
{
  options.homeProfileModules = lib.mkOption {
    type = lib.types.listOf lib.types.unspecified;
    default = [ ];
    description = "Home-manager modules shared by every host that gets the 'guillaume' profile.";
  };

  config.homeProfileModules = with config.flake.modules.homeManager; [
    profile
    headless
    headless-tmux
    headless-zellij
    headless-zsh
    codspeed
    stockly
    stylix-home
    ../modules/gui
  ];
}
