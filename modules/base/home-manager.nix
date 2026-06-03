{
  flake.modules.homeManager.base =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
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
        };
        configFile."mimeapps.list" = {
          source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/mimeapps.list";
        };
        configFile."harper-ls/dictionary.txt" = {
          source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/harper-dict.txt";
        };
      };

      # Hack Nerd Font covers the Nerd Font icon ranges but not the Unicode
      # Dingbats/Misc-Symbols blocks (e.g. ✶ U+2736, used as Claude Code's
      # spinner), which render as tofu. Noto Sans Symbols 2 fills that gap and
      # sits in the fontconfig fallback chain below.
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

      programs.home-manager.enable = true;

      home.stateVersion = "23.11";
    };
}
