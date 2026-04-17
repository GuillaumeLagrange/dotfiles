{ lib, config, ... }:
{
  options = {
    homeProfileModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      description = "Home-manager modules shared by every host (linux + darwin).";
    };

    homeProfileLinuxModules = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      description = "Home-manager modules to add on top of homeProfileModules on Linux hosts.";
    };
  };

  config = {
    homeProfileModules = with config.flake.modules.homeManager; [
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

    homeProfileLinuxModules = with config.flake.modules.homeManager; [
      profile-linux
      headless-linux
      codspeed-linux
    ];
  };
}
