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
    gui
    gui-audio
    gui-firefox
    gui-hyprland
    gui-lock
    gui-niri
    gui-options
    gui-sway
    gui-vicinae
    gui-waybar
  ];
}
