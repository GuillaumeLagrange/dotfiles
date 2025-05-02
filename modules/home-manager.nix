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
    ./codspeed.nix
    ./stylix/home-manager.nix
  ];

  options = {
    term = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.kitty}/bin/kitty --title Kitty";
      description = "A shared term value";
    };

    firefoxMain = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.firefox-nightly-bin}/bin/firefox-nightly";
    };

    firefoxAlt = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.firefox-nightly-bin}/bin/firefox-nightly --new-instance";
    };

    chromium = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.chromium}/bin/chromium";
    };
  };

  config = {
    home.username = lib.mkDefault "guillaume";
    home.homeDirectory = lib.mkDefault "/home/guillaume";

    headless.enable = lib.mkDefault true;
    gui.enable = lib.mkDefault true;
    codspeed.enable = lib.mkDefault true;
    stockly.enable = lib.mkDefault false;

    home.sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "kitty";
      # Allows nh to find the flake
      NH_FLAKE = "$HOME/dotfiles";
    };

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
      mimeApps = {
        enable = true;
        defaultApplications = {
          "text/plain" = "nvim.desktop";
          "x-scheme-handler/http" = "firefox-nightly.desktop";
          "x-scheme-handler/https" = "firefox-nightly.desktop";
          "x-scheme-handler/chrome" = "firefox-nightly.desktop";
          "text/html" = "firefox-nightly.desktop";
          "application/x-extension-htm" = "firefox-nightly.desktop";
          "application/x-extension-html" = "firefox-nightly.desktop";
          "application/x-extension-shtml" = "firefox-nightly.desktop";
          "application/xhtml+xml" = "firefox-nightly.desktop";
          "application/x-extension-xhtml" = "firefox-nightly.desktop";
          "application/x-extension-xht" = "firefox-nightly.desktop";
        };
      };
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
