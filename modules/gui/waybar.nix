{
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    waybar.enable = lib.mkEnableOption "waybar and its configuration";
  };

  config = lib.mkIf config.waybar.enable {
    programs.waybar = {
      enable = true;
      style = builtins.readFile ./style.css;
      systemd.enable = true;
      settings = {
        mainBar = {
          layer = "top";
          position = "bottom";
          height = 22;
          output = [ "*" ];
          modules-left = [
            "hyprland/submap"
            "hyprland/workspaces"
            "hyprland/window"
            "sway/workspaces"
            "sway/window"
            "sway/mode"
            "niri/workspaces"
            "niri/window"
          ];
          modules-center = [ ];
          modules-right = [
            "mpris"
            "tray"
            "disk"
            "cpu"
            "memory"
            "battery"
            "power-profiles-daemon"
            "pulseaudio"
            "clock"
          ];

          "hyprland/workspaces" = {
            all-outputs = false;
            show-special = true;
          };

          "hyprland/window" = {
            separate-outputs = true;
          };

          "niri/workspaces" = {
            all-outputs = false;
          };

          "niri/window" = {
            separate-outputs = true;
          };

          "power-profiles-daemon" = {
            "format" = "{icon}";
            "format-icons" = {
              "power-saver" = "󰾆";
              "balanced" = "󰾅";
              "performance" = "󰓅";
            };
          };

          "mpris" = {
            "format" = " {player_icon} {status_icon} {dynamic} ";
            "player-icons" = {
              "default" = " ";
              "spotify" = " ";
              "firefox" = " ";
            };
            "status-icons" = {
              "paused" = " ";
              "playing" = " ";
            };
            "dynamic-order" = [
              "title"
              "artist"
              "position"
              "length"
            ];
            "dynamic-len" = 70;
            "interval" = 1;
          };

          "tray" = {
            icon-size = 14;
            spacing = 8;
            show-passive-items = true;
          };

          "disk" = {
            "format" = "{free}";
          };

          "pulseaudio" = {
            "format" = "{icon} {volume}%";
            "format-bluetooth" = " {icon} {volume}%";
            "format-muted" = "󰝟  {volume}%";
            "format-icons" = {
              "default" = [
                "󰕿 "
                "󰖀 "
                "󰕾 "
              ];
            };
            "scroll-step" = 1;
            "on-click" = "pavucontrol";
          };

          "battery" = {
            "format" = "{icon} {capacity}%";
            "format-charging" = "󱐋 {icon} {capacity}%";
            "format-icons" = [
              "󰂎"
              "󱊡"
              "󱊢"
              "󱊣"
            ];
          };

          "clock" = {
            "format" = "  {:L%B %d, %R}";
            "format-alt" = "  {:L%H:%M} ";
            "tooltip-format" = "<tt><small>{calendar}</small></tt>";
            # "locale" = "en_GB";
            "calendar" = {
              "mode" = "year";
              "mode-mon-col" = 2;
              "weeks-pos" = "left";
              "on-scroll" = 1;
              "on-click-right" = "mode";
              "format" = {
                "months" = "<span color='#ffead3'><b>{}</b></span>";
                "days" = "<span color='#ecc6d9'><b>{}</b></span>";
                "weeks" = "<span color='#99ffdd'><b>W{}</b></span>";
                "weekdays" = "<span color='#ffcc66'><b>{}</b></span>";
                "today" = "<span color='#ff6699'><b><u>{}</u></b></span>";
              };
            };
            "actions" = {
              "on-click-right" = "mode";
              "on-click-left" = "mode";
            };
          };
        };
      };
    };
  };
}
