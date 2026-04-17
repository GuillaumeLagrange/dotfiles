{
  flake.modules.homeManager.profile =
    { lib, ... }:
    {
      home.username = lib.mkDefault "guillaume";
      home.homeDirectory = lib.mkDefault "/home/guillaume";

      codspeed.enable = lib.mkDefault true;
      gui.enable = lib.mkDefault true;
      stockly.enable = lib.mkDefault false;

      home.sessionVariables = {
        EDITOR = "nvim";
        TERMINAL = "kitty";
        NH_FLAKE = "$HOME/dotfiles";
      };

      fonts.fontconfig = {
        enable = true;
        defaultFonts = {
          monospace = [
            "Hack Nerd Font"
            "Noto Color Emoji"
          ];
          emoji = [
            "Noto Color Emoji"
          ];
        };
      };

      programs.home-manager.enable = true;

      home.stateVersion = "23.11"; # Do not touch this
    };
}
