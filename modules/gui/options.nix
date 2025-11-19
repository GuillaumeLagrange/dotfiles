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

    audioUp = lib.mkOption {
      type = lib.types.str;
      default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
    };
    audioDown = lib.mkOption {
      type = lib.types.str;
      default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ 0 && ${wpctl} set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
    };
    audioMute = lib.mkOption {
      type = lib.types.str;
      default = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle && ${volumeNotification}";
    };
    brightnessUp = lib.mkOption {
      type = lib.types.str;
      default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%+";
    };
    brightnessDown = lib.mkOption {
      type = lib.types.str;
      default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%- -n 1";
    };
    brightnessMin = lib.mkOption {
      type = lib.types.str;
      default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 100%";
    };
    brightnessMax = lib.mkOption {
      type = lib.types.str;
      default = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 1";
    };
    screenshotTool = lib.mkOption {
      type = lib.types.str;
      default = "${screenshotTool}/bin/screenshot_tool";
    };
  };
}
