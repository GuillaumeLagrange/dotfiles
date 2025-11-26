{
  pkgs,
  lib,
  config,
  ...
}:
let
  lock = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh";

  move-to-bottom-right = "${
    (import ./move-to-bottom-right.nix { inherit pkgs; })
  }/bin/move-to-bottom-right.sh";

  swap_workspaces = pkgs.writeShellScriptBin "swap-workspaces" ''
    # Check if an argument is provided
    if [ -z "$1" ]; then
      echo "Usage: $0 <workspace_number>"
      exit 1
    fi

    # Get the list of workspaces
    workspaces=$(swaymsg -t get_workspaces | jq -r '.[].name')

    # Get the current workspace
    current_workspace=$(swaymsg -t get_workspaces | jq -r '.[] | select(.focused) | .name')

    # Check if the current workspace is valid
    if [ -z "$current_workspace" ]; then
      echo "Failed to get the current workspace."
      exit 1
    fi

    # Get the target workspace from the argument
    target_workspace=$1

    # Check if the target workspace exists
    if ! echo "$workspaces" | grep -qx "$target_workspace"; then
      echo "The target workspace $target_workspace does not exist."
      exit 1
    fi

    # Check if the target workspace is the same as the current workspace
    if [ "$current_workspace" = "$target_workspace" ]; then
      echo "The target workspace is the same as the current workspace. No swap needed."
      exit 0
    fi

    # Perform the swap
    swaymsg "rename workspace $current_workspace to temporary; rename workspace $target_workspace to $current_workspace; rename workspace temporary to $target_workspace; workspace $current_workspace"

    echo "Swapped workspace $current_workspace with $target_workspace."
  '';
in
{
  options = {
    sway.enable = lib.mkEnableOption "sway and its associated config";
  };

  config = lib.mkIf config.sway.enable {
    wayland.windowManager.sway =
      let
        modifier = "Mod4";
        volumeNotification = "${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga";
        backlightStep = "10";
        spotifyVolumeStep = "0.05";
      in
      {
        enable = true;
        # Disable default config
        config = {
          modifier = modifier;
          floating.modifier = modifier;
          keybindings = {
            "${modifier}+Return" = "exec ${config.term}";
            "${modifier}+Shift+a" = "kill";
            "${modifier}+d" = "exec vicinae toggle";
            "Print" = "exec ${config.screenshotTool}";
            "Shift+Print" = "exec ${config.screenshotTool}";
            "${modifier}+b" = "exec ${pkgs.blueman}/bin/blueman-manager";
            "${modifier}+n" = "exec ${pkgs.mako}/bin/makoctl menu fuzzel -d -p 'Choose Action: '";

            # Browsers
            "${modifier}+w" = "exec ${config.firefox.main}";
            "${modifier}+Shift+w" = "exec ${config.firefox.alt}";
            "${modifier}+Ctrl+w" = "exec ${config.browsers.chromium}";

            "--locked ${modifier}+equal" = "exec ${config.audio.up}";
            "--locked ${modifier}+minus" = "exec ${config.audio.down}";
            "--locked XF86AudioRaiseVolume" = "exec ${config.audio.up}";
            "--locked XF86AudioLowerVolume" = "exec ${config.audio.down}";
            "--locked XF86AudioMute" = "exec ${config.audio.mute}";

            "XF86MonBrightnessUp" = "exec ${config.brightness.up}";
            "XF86MonBrightnessDown" = "exec ${config.brightness.down}";
            "Shift+XF86MonBrightnessUp" = "exec ${config.brightness.min}";
            "Shift+XF86MonBrightnessDown" = "exec ${config.brightness.max}";

            # Spotify control
            "--locked Shift+XF86AudioPlay" = "exec ${pkgs.playerctl}/bin/playerctl -p spotify play-pause";
            "--locked Shift+XF86AudioRaiseVolume" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}+";
            "--locked Shift+XF86AudioLowerVolume" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}-";
            "--locked ${modifier}+Shift+equal" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}+";
            "--locked ${modifier}+Shift+minus" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}-";

            # Audio controls
            "--locked XF86AudioPause" = "exec ${pkgs.playerctl}/bin/playerctl pause";
            "--locked XF86AudioPlay" = "exec ${pkgs.playerctl}/bin/playerctl play-pause";
            "--locked XF86AudioNext" = "exec ${pkgs.playerctl}/bin/playerctl next";
            "--locked XF86AudioPrev" = "exec ${pkgs.playerctl}/bin/playerctl previous";

            "${modifier}+Ctrl+p" = "exec ${move-to-bottom-right}";

            "${modifier}+Ctrl+1" = "exec swap-workspaces 1";
            "${modifier}+Ctrl+2" = "exec swap-workspaces 2";
            "${modifier}+Ctrl+3" = "exec swap-workspaces 3";
            "${modifier}+Ctrl+4" = "exec swap-workspaces 4";
            "${modifier}+Ctrl+5" = "exec swap-workspaces 5";
            "${modifier}+Ctrl+6" = "exec swap-workspaces 6";
            "${modifier}+Ctrl+7" = "exec swap-workspaces 7";
            "${modifier}+Ctrl+8" = "exec swap-workspaces 8";
            "${modifier}+Ctrl+9" = "exec swap-workspaces 9";
            "${modifier}+Ctrl+0" = "exec swap-workspaces 0";
          };
          startup = [
            { command = "${pkgs.blueman}/bin/blueman-applet"; }
            { command = "${pkgs._1password-gui}/bin/1password --silent"; }
            { command = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --no-window"; }
            { command = "${pkgs.mako}/bin/mako"; }
            { command = "${pkgs.protonvpn-gui}/bin/protonvpn-app --start-minimized"; }
            # Allows nautilus to find applications to open files properly
            { command = "dbus-update-activation-environment PATH"; }
            # Set keyboard layout here because nix cannot find qwerty-fr in the input block
            {
              command = "swaymsg input type:keyboard xkb_layout qwerty-fr";
              always = true;
            }
          ];
          input = {
            "type:keyboard" = {
              "repeat_delay" = "300";
              "repeat_rate" = "30";
              "xkb_options" = "ctrl:nocaps";
              "xkb_numlock" = "enabled";
            };
            "type:touchpad" = {
              natural_scroll = "enabled";
              tap = "enabled";
              middle_emulation = "disabled";
            };
          };
          bars = [ ];
          window.commands = [
            {
              command = "floating enable, border pixel 1, sticky enable, exec ${move-to-bottom-right}, move scratchpad, scratchpad show";
              criteria = {
                title = "^Picture-in-Picture$";
                app_id = "firefox";
              };
            }
            {
              command = "floating enable, border pixel 1, sticky enable, move scratchpad, scratchpad show";
              criteria = {
                title = "^Huddle:*$";
                class = "Slack";
              };
            }
          ];
        };
        extraConfig =
          let
            mkOutputConfig = name: monitor: ''
              ${name} mode ${monitor.resolution}${lib.optionalString (monitor.refreshRate != null) "@${toString monitor.refreshRate}HZ"} position ${toString monitor.position.x} ${toString monitor.position.y}
            '';
          in
          builtins.readFile ./sway.config + ''
            set $Locker ${lock}
            set $laptop "${config.monitors.laptop.name}"
            set $main_home "${config.monitors.mainHome.name}"
            set $secondary_home "${config.monitors.secondaryHome.name}"
            set $main_office "${config.monitors.mainOffice.name}"

            # Output configuration generated from options
            output {
                ${mkOutputConfig "$laptop" config.monitors.laptop}

                # Home
                ${mkOutputConfig "$main_home" config.monitors.mainHome}
                ${mkOutputConfig "$secondary_home" config.monitors.secondaryHome}

                # Office
                ${mkOutputConfig "$main_office" config.monitors.mainOffice}
            }
          '';
      };

    home.packages = [
      swap_workspaces
    ];
  };
}
