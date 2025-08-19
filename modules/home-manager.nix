{
  config,
  pkgs,
  pkgs-unstable,
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

    firefoxPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs-unstable.firefox;
    };

    firefoxMain = lib.mkOption {
      type = lib.types.str;
      default = "${config.firefoxPackage}/bin/firefox";
    };

    firefoxAlt = lib.mkOption {
      type = lib.types.str;
      default = "${config.firefoxPackage}/bin/firefox --new-instance";
    };

    firefoxDesktopEntry = lib.mkOption {
      type = lib.types.str;
      default = "${config.firefoxPackage}/share/applications/firefox.desktop";
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
          "x-scheme-handler/http" = config.firefoxDesktopEntry;
          "x-scheme-handler/https" = config.firefoxDesktopEntry;
          "x-scheme-handler/chrome" = config.firefoxDesktopEntry;
          "text/html" = config.firefoxDesktopEntry;
          "application/x-extension-htm" = config.firefoxDesktopEntry;
          "application/x-extension-html" = config.firefoxDesktopEntry;
          "application/x-extension-shtml" = config.firefoxDesktopEntry;
          "application/xhtml+xml" = config.firefoxDesktopEntry;
          "application/x-extension-xhtml" = config.firefoxDesktopEntry;
          "application/x-extension-xht" = config.firefoxDesktopEntry;
          "image/jpeg" = config.firefoxDesktopEntry;
          "image/png" = config.firefoxDesktopEntry;
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
