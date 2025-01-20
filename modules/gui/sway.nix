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
          bars = [ { command = "${pkgs.waybar}/bin/waybar"; } ];
          modifier = modifier;
          floating.modifier = modifier;
          keybindings = {
            "${modifier}+Return" = "exec ${config.term}";
            "${modifier}+Shift+a" = "kill";
            "${modifier}+d" = "exec ${pkgs.wofi}/bin/wofi --show drun --insensitive";
            "${modifier}+v" =
              "exec ${pkgs.cliphist}/bin/cliphist list | ${pkgs.wofi}/bin/wofi --dmenu | ${pkgs.cliphist}/bin/cliphist decode | wl-copy";
            "Print" =
              "exec ${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -";
            "Shift+Print" =
              "exec ${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -";
            "${modifier}+Tab" = "exec ${pkgs.wofi-emoji}/bin/wofi-emoji";
            "${modifier}+b" = "exec ${pkgs.blueman}/bin/blueman-manager";
            "${modifier}+n" = "exec ${pkgs.mako}/bin/makoctl menu wofi -d -p 'Choose Action: '";

            "${modifier}+equal" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
            "${modifier}+minus" =
              "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
            "XF86AudioRaiseVolume" =
              "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
            "XF86AudioLowerVolume" =
              "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
            "XF86AudioMute" =
              "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && ${volumeNotification}";

            "XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%+";
            "XF86MonBrightnessDown" =
              "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%- -n 1";
            "Shift+XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 100%";
            "Shift+XF86MonBrightnessDown" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set 1";

            # Spotify control
            "Shift+XF86AudioPlay" = "exec ${pkgs.playerctl}/bin/playerctl -p spotify play-pause";
            "Shift+XF86AudioRaiseVolume" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}+";
            "Shift+XF86AudioLowerVolume" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}-";
            "${modifier}+Shift+equal" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}+";
            "${modifier}+Shift+minus" =
              "exec ${pkgs.playerctl}/bin/playerctl -p spotify volume ${spotifyVolumeStep}-";

            # Audio controls
            "XF86AudioPause" = "exec ${pkgs.playerctl}/bin/playerctl pause";
            "XF86AudioPlay" = "exec ${pkgs.playerctl}/bin/playerctl play-pause";
            "XF86AudioNext" = "exec ${pkgs.playerctl}/bin/playerctl next";
            "XF86AudioPrev" = "exec ${pkgs.playerctl}/bin/playerctl previous";

            "${modifier}+Ctrl+p" = "exec ${move-to-bottom-right}";
          };
          startup = [
            { command = "${pkgs.networkmanagerapplet}/bin/nm-applet"; }
            { command = "${pkgs.blueman}/bin/blueman-applet"; }
            { command = "${pkgs._1password-gui}/bin/1password --silent"; }
            { command = "${pkgs.xss-lock}/bin/xss-lock -- ${lock}"; }
            { command = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --no-window"; }
            { command = "${pkgs.mako}/bin/mako"; }
            { command = "${pkgs.spotify}/bin/spotify"; }
            { command = "${pkgs.protonvpn-gui}/bin/protonvpn-app --start-minimized"; }
            # Set keyboard layout here because nix cannot find qwerty-fr in the input block
            {
              command = "swaymsg input type:keyboard xkb_layout qwerty-fr";
              always = true;
            }
            {
              command = ''
                ${pkgs.procps}/bin/pgrep wpaperd | xargs -r kill &&\
                ${pkgs.wpaperd}/bin/wpaperd
              '';
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
          window.commands = [
            {
              command = "floating enable, border pixel 1, sticky enable, exec ${move-to-bottom-right}, move scratchpad, scratchpad show";
              criteria = {
                title = "^Picture-in-Picture$";
                app_id = "firefox";
              };
            }
          ];
        };
        extraConfig =
          builtins.readFile ./sway.config
          + ''
            set $Locker ${lock}
          '';
      };
  };
}
