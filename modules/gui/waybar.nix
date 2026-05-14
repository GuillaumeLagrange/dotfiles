{
  flake.modules.homeManager.waybar =
    { pkgs, config, ... }:
    let
      niri-windows-script = pkgs.writers.writePython3Bin "niri-windows" { doCheck = false; } (
        builtins.replaceStrings [ "\"niri\"" ] [ "\"${pkgs.niri}/bin/niri\"" ] (
          builtins.readFile ./niri/windows.py
        )
      );

      aiUsageRuntimePath = pkgs.lib.makeBinPath [
        pkgs.jq
        pkgs.curl
        pkgs.coreutils
        pkgs.gnused
      ];
      claudeUsageScript = pkgs.writeShellScriptBin "waybar-claude-usage" ''
        export PATH="${aiUsageRuntimePath}:$PATH"
        export AI_USAGE_COMMON="${./waybar-scripts/ai-usage-common.sh}"
        export AI_USAGE_RETRY_LIMIT="5"
        exec ${pkgs.bash}/bin/bash ${./waybar-scripts/claude-usage.sh} "$@"
      '';
    in
    {
      programs.waybar = {
        enable = true;
        style = builtins.readFile ./waybar.css;
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
              "custom/niri-windows"
              "niri/window"
            ];
            modules-center = [ ];
            modules-right = [
              "custom/screenrecord"
              "mpris"
              "tray"
              "custom/claude-usage"
              "disk"
              "cpu"
              "memory"
              "battery"
              "power-profiles-daemon"
              "pulseaudio"
              "clock"
            ];

            "custom/claude-usage" = {
              return-type = "json";
              format = "{}";
              exec = "${claudeUsageScript}/bin/waybar-claude-usage";
              on-click = "${claudeUsageScript}/bin/waybar-claude-usage --force-refresh";
              on-click-right = "${claudeUsageScript}/bin/waybar-claude-usage --restart";
              # /api/oauth/usage aggressively 429s — see github.com/anthropics/claude-code/issues/30930
              interval = 300;
            };

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
              icon = false;
              separate-outputs = true;
            };

            "custom/niri-windows" = {
              exec = "${niri-windows-script}/bin/niri-windows";
              return-type = "json";
              on-click = "${pkgs.niri}/bin/niri msg action toggle-overview";
            };

            "custom/screenrecord" = {
              exec = "${pkgs.writeShellScript "waybar-screenrecord" ''
                if ${pkgs.procps}/bin/pgrep -x wl-screenrec > /dev/null; then
                  echo '{"text": "⏺ REC", "class": "recording"}'
                else
                  echo '{"text": "", "class": "idle"}'
                fi
              ''}";
              return-type = "json";
              signal = 8;
              on-click = "${config.screenrecordScreenTool}";
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
                "default" = " ";
                "spotify" = " ";
                "firefox" = " ";
              };
              "status-icons" = {
                "paused" = " ";
                "playing" = " ";
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
              "format-bluetooth" = " {icon} {volume}%";
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
              "format" = "  {:L%B %d, %R}";
              "format-alt" = "  {:L%H:%M} ";
              "tooltip-format" = "<tt><small>{calendar}</small></tt>";
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
