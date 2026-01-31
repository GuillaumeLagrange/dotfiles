{
  config,
  pkgs,
  pkgs-unstable,
  lib,
  ...
}:
let
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  volumeNotification = "${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga";
  backlightStep = "10";
  # Done this way to avoid messing with double quotes in niri
  screenshotTool = pkgs.writeShellScriptBin "screenshot_tool" ''
    ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.swappy}/bin/swappy -f -
  '';
in
{
  options = {
    term = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.ghostty}/bin/ghostty";
    };

    monitors = {
      laptop = lib.mkOption {
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "eDP-1";
            };
            resolution = lib.mkOption {
              type = lib.types.str;
              default = "1920x1200";
            };
            refreshRate = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            position = {
              x = lib.mkOption {
                type = lib.types.int;
                default = 0;
              };
              y = lib.mkOption {
                type = lib.types.int;
                default = 1440;
              };
            };
          };
        };
        default = { };
      };

      mainHome = lib.mkOption {
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "Shenzhen KTC Technology Group OLED G27P6 Unknown";
            };
            resolution = lib.mkOption {
              type = lib.types.str;
              default = "2560x1440";
            };
            refreshRate = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = 60;
            };
            position = {
              x = lib.mkOption {
                type = lib.types.int;
                default = 1920;
              };
              y = lib.mkOption {
                type = lib.types.int;
                default = 1440;
              };
            };
          };
        };
        default = { };
      };

      secondaryHome = lib.mkOption {
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "Dell Inc. DELL S2421HS 45WFW83";
            };
            resolution = lib.mkOption {
              type = lib.types.str;
              default = "1920x1080";
            };
            refreshRate = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            position = {
              x = lib.mkOption {
                type = lib.types.int;
                default = 4480;
              };
              y = lib.mkOption {
                type = lib.types.int;
                default = 1440;
              };
            };
          };
        };
        default = { };
      };

      mainOffice = lib.mkOption {
        type = lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "Dell Inc. DELL P2423D FL44W14";
            };
            resolution = lib.mkOption {
              type = lib.types.str;
              default = "2560x1440";
            };
            refreshRate = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = 75;
            };
            position = {
              x = lib.mkOption {
                type = lib.types.int;
                default = 1920;
              };
              y = lib.mkOption {
                type = lib.types.int;
                default = 1440;
              };
            };
          };
        };
        default = { };
      };
    };

    firefox = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs-unstable.firefox;
      };

      main = lib.mkOption {
        type = lib.types.str;
        default = "${config.firefox.package}/bin/firefox";
      };

      alt = lib.mkOption {
        type = lib.types.str;
        default = "${config.firefox.package}/bin/firefox --new-instance";
      };

      desktopEntry = lib.mkOption {
        type = lib.types.str;
        default = "firefox.desktop";
      };
    };

    browsers = {
      chromium = lib.mkOption {
        type = lib.types.str;
        default = "${pkgs.chromium}/bin/chromium";
      };
    };

    audio = {
      up = lib.mkOption {
        type = lib.types.str;
        default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
      };

      down = lib.mkOption {
        type = lib.types.str;
        default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
      };

      mute = lib.mkOption {
        type = lib.types.str;
        default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle && ${volumeNotification}";
      };
    };

    brightness = {
      up = lib.mkOption {
        type = lib.types.str;
        default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%+";
      };

      down = lib.mkOption {
        type = lib.types.str;
        default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%- -n 1";
      };

      max = lib.mkOption {
        type = lib.types.str;
        default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 100%";
      };

      min = lib.mkOption {
        type = lib.types.str;
        default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 1";
      };
    };

    screenshotTool = lib.mkOption {
      type = lib.types.str;
      default = "${screenshotTool}/bin/screenshot_tool";
    };
  };
}
