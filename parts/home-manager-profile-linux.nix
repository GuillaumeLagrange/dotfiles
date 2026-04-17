{
  flake.modules.homeManager.profile-linux =
    { config, ... }:
    {
      xdg = {
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
        };
        configFile."mimeapps.list" = {
          source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/mimeapps.list";
        };
      };
    };
}
