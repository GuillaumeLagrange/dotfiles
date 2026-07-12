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
      memorySwapScript = pkgs.writeShellScriptBin "waybar-memory-swap" ''
        export PATH="${pkgs.lib.makeBinPath [ pkgs.gawk pkgs.coreutils ]}:$PATH"
        exec ${pkgs.bash}/bin/bash ${./waybar-scripts/memory-swap.sh} "$@"
      '';

      claudeUsageScript = pkgs.writeShellScriptBin "waybar-claude-usage" ''
        export PATH="${aiUsageRuntimePath}:$PATH"
        export AI_USAGE_COMMON="${./waybar-scripts/ai-usage-common.sh}"
        export AI_USAGE_RETRY_LIMIT="5"
        exec ${pkgs.bash}/bin/bash ${./waybar-scripts/claude-usage.sh} "$@"
      '';

      settingsMenuRuntimePath = pkgs.lib.makeBinPath [
        pkgs.wlinhibit
        pkgs.mako
        pkgs.power-profiles-daemon
        pkgs.procps
      ];
      settingsMenuScript = pkgs.writeShellScriptBin "waybar-settings-menu" ''
        export PATH="${settingsMenuRuntimePath}:$PATH"
        exec ${pkgs.python3}/bin/python3 ${./waybar-scripts/settings_menu.py} "$@"
      '';

      # The native power-profiles-daemon module repaints itself on profile
      # change, but the settings gear tints its background to the profile too
      # and only refreshes on SIGRTMIN+9. Bridge D-Bus profile changes to that
      # signal so the gear tint stays in sync.
      profileWatchScript = pkgs.writeShellScriptBin "waybar-profile-watch" ''
        # The daemon emits PropertiesChanged on two object paths per change
        # (net.hadess and its UPower alias); match one so the gear repaints once.
        # Anchor the pkill on the real waybar binary path so it doesn't also
        # match (and kill) this watcher, whose name contains "waybar".
        ${pkgs.glib.bin}/bin/gdbus monitor --system --dest net.hadess.PowerProfiles \
          | ${pkgs.gnugrep}/bin/grep --line-buffered "^/net/hadess/PowerProfiles.*ActiveProfile" \
          | while read -r _; do
              ${pkgs.procps}/bin/pkill -RTMIN+9 -f 'bin/waybar$'
            done
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
              "custom/memory-swap"
              "battery"
              "pulseaudio"
              "group/settings"
              "clock"
            ];

            "group/settings" = {
              orientation = "horizontal";
              drawer = {
                transition-duration = 300;
                transition-left-to-right = false;
              };
              modules = [
                "custom/settings"
                "custom/settings-idle"
                "custom/settings-dnd"
                "power-profiles-daemon"
              ];
            };

            "custom/settings" = {
              return-type = "json";
              format = "{}";
              exec = "${settingsMenuScript}/bin/waybar-settings-menu gear-status";
              signal = 9;
            };

            "custom/settings-idle" = {
              return-type = "json";
              format = "{}";
              exec = "${settingsMenuScript}/bin/waybar-settings-menu idle-status";
              on-click = "${settingsMenuScript}/bin/waybar-settings-menu toggle-idle";
              signal = 9;
            };

            "custom/settings-dnd" = {
              return-type = "json";
              format = "{}";
              exec = "${settingsMenuScript}/bin/waybar-settings-menu dnd-status";
              on-click = "${settingsMenuScript}/bin/waybar-settings-menu toggle-dnd";
              signal = 9;
            };

            # Native D-Bus module: cycles on left/right click with instant
            # repaint, no subprocess. Left-click goes toward power-saver,
            # right-click toward performance (order is hardcoded upstream).
            "power-profiles-daemon" = {
              format = "{icon}";
              tooltip-format = "Profile: {profile}";
              format-icons = {
                performance = "󰓅"; # md-speedometer (U+F04C5)
                balanced = "󰾅"; # md-gauge (U+F0F85)
                power-saver = "󰾆"; # md-gauge_low (U+F0F86)
              };
            };

            "custom/claude-usage" = {
              return-type = "json";
              format = "{}";
              exec = "${claudeUsageScript}/bin/waybar-claude-usage";
              on-click = "${claudeUsageScript}/bin/waybar-claude-usage --force-refresh && ${pkgs.procps}/bin/pkill -RTMIN+8 waybar";
              on-click-right = "${claudeUsageScript}/bin/waybar-claude-usage --restart && ${pkgs.procps}/bin/pkill -RTMIN+8 waybar";
              # /api/oauth/usage aggressively 429s — see github.com/anthropics/claude-code/issues/30930
              signal = 8;
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
              "format" = "󰋊 {free}";
            };

            "cpu" = {
              "format" = "󰍛 {usage}%";
            };

            "custom/memory-swap" = {
              return-type = "json";
              format = "{}";
              exec = "${memorySwapScript}/bin/waybar-memory-swap";
              interval = 5;
            };

            "pulseaudio" = {
              "format" = "{icon} {volume}%";
              "format-bluetooth" = "{icon} {volume}%";
              "format-muted" = "󰝟 {volume}%";
              "format-icons" = {
                "default" = [
                  "󰕿"
                  "󰖀"
                  "󰕾"
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
              "format" = "󰃰 {:L%B %d, %R}";
              "format-alt" = "󰥔 {:L%H:%M}";
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

      systemd.user.services.waybar-profile-watch = {
        Unit = {
          Description = "Refresh waybar settings gear on power-profile change";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${profileWatchScript}/bin/waybar-profile-watch";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
