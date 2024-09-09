{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./gui
    ./headless
    ./stockly
    ./stylix/home-manager.nix
  ];

  config = {
    home.username = lib.mkDefault "guillaume";
    home.homeDirectory = lib.mkDefault "/home/guillaume";

    headless.enable = lib.mkDefault true;
    gui.enable = lib.mkDefault true;
    stockly.enable = lib.mkDefault true;

    home.sessionVariables = {
      EDITOR = "nvim";
    };

    xdg.userDirs = {
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
    };

    programs.home-manager.enable = true;

    home.stateVersion = "23.11"; # Please read the comment before changing.
  };
}
