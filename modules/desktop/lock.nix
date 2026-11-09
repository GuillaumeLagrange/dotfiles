{
  pkgs,
  lib,
  config,
  ...
}:
let
  commands = import ./commands.nix { inherit pkgs lib config; };

  fg = "rgba(ddc7a1ee)";
  shadow = {
    shadow_passes = 2;
    shadow_size = 4;
    shadow_boost = 1.2;
  };
in
{
  _class = "homeManager";

  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        hide_cursor = true;
      };
      auth = {
        "fingerprint:enabled" = true;
      };
      background = {
        path = commands.lockWallpaper;
        blur_passes = 2;
        blur_size = 5;
        brightness = 0.7;
      };
      label = [
        (
          {
            text = "$TIME";
            font_family = "Inter Display";
            font_size = 110;
            color = fg;
            position = "0, 170";
            halign = "center";
            valign = "center";
          }
          // shadow
        )
        (
          {
            text = ''cmd[update:60000] date +"%A %-d %B"'';
            font_family = "Inter";
            font_size = 20;
            color = fg;
            position = "0, 70";
            halign = "center";
            valign = "center";
          }
          // shadow
        )
      ];
      input-field = {
        size = "280, 48";
        position = "0, -80";
        halign = "center";
        valign = "center";
        outline_thickness = 2;
        rounding = -1;
        fade_on_empty = true;
        placeholder_text = "";
        dots_spacing = 0.3;
      };
    };
  };

  home.packages = [
    commands.lockScript
    # TODO: Patch soteria and get rid of this
    pkgs.hyprpolkitagent
  ];
}
