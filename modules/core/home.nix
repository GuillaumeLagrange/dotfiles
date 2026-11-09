{
  config,
  pkgs,
  lib,
  ...
}:
{
  _class = "homeManager";

  home.username = lib.mkDefault "guillaume";
  home.homeDirectory = lib.mkDefault "/home/guillaume";

  home.sessionVariables = {
    EDITOR = "nvim";
    TERMINAL = "kitty";
    NH_FLAKE = "$HOME/dotfiles";
  };

  xdg = lib.mkIf pkgs.stdenv.isLinux {
    userDirs = {
      enable = true;
      download = "${config.home.homeDirectory}/downloads";
      desktop = "${config.home.homeDirectory}";
      documents = "${config.home.homeDirectory}/documents";
      music = "${config.home.homeDirectory}/media/music";
      videos = "${config.home.homeDirectory}/media/videos";
      pictures = "${config.home.homeDirectory}/media/pictures";
      publicShare = "${config.home.homeDirectory}/media/public";
      templates = "${config.home.homeDirectory}/media/templates";
      createDirectories = false;
      setSessionVariables = false;
    };
    configFile."mimeapps.list" = {
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/mimeapps.list";
    };
    configFile."harper-ls/dictionary.txt" = {
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/harper-dict.txt";
    };
  };

  home.packages = [ pkgs.noto-fonts ];

  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      monospace = [
        "Hack Nerd Font"
        "Noto Sans Symbols 2"
        "Noto Color Emoji"
      ];
      emoji = [
        "Noto Color Emoji"
      ];
    };
  };

  # Off without a screen; the desktop group turns it on.
  dconf.enable = lib.mkDefault false;

  programs.home-manager.enable = true;

  home.stateVersion = "23.11";
}
