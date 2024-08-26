{
  pkgs,
  lib,
  config,
  ...
}:
let
  lock_script = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh";
  ssh_charybdis = "${(import ../stockly/charybdis.nix { inherit pkgs; })}/bin/ssh_charybdis.sh";
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
      in
      {
        enable = true;
        # Disable default config
        config = {
          bars = [ { command = "${pkgs.waybar}/bin/waybar"; } ];
          modifier = modifier;
          floating.modifier = modifier;
          keybindings = {
            "${modifier}+Return" = "exec ${pkgs.alacritty}/bin/alacritty";
            "${modifier}+Shift+a" = "kill"; # Kill focused window
            "${modifier}+d" = "exec ${pkgs.wofi}/bin/wofi --show drun";
            "${modifier}+v" = "exec ${pkgs.cliphist}/bin/cliphist list | ${pkgs.wofi}/bin/wofi --dmenu | ${pkgs.cliphist}/bin/cliphist decode | wl-copy";
            "Print" = "exec ${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -";
            "Shift+Print" = "exec ${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -";
            "${modifier}+backslash" = "workspace 3; exec ${ssh_charybdis} nvim";
            "${modifier}+Shift+backslash" = "workspace 2; exec ${ssh_charybdis} bo";
            "${modifier}+Tab" = "exec ${pkgs.wofi-emoji}/bin/wofi-emoji";
            "${modifier}+b" = "exec ${pkgs.blueman}/bin/blueman-manager";
            "${modifier}+n" = "exec ${pkgs.swaynotificationcenter}/bin/swaync-client -t";

            "XF86AudioRaiseVolume" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && ${volumeNotification}";
            "XF86AudioLowerVolume" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && ${volumeNotification}";
            "XF86AudioMute" = "exec ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && ${volumeNotification}";

            "XF86MonBrightnessUp" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%+";
            "XF86MonBrightnessDown" = "exec ${pkgs.brightnessctl}/bin/brightnessctl set ${backlightStep}%- -n 1";

          };
          startup = [
            { command = "${pkgs.networkmanagerapplet}/bin/nm-applet"; }
            { command = "${pkgs.blueman}/bin/blueman-applet"; }
            { command = "${pkgs._1password-gui}/bin/1password --silent"; }
            { command = "${pkgs.xss-lock}/bin/xss-lock -- ${lock_script}"; }
            { command = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --no-window"; }
            { command = "${pkgs.swaynotificationcenter}/bin/swaync"; }
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
        };
        extraConfig =
          builtins.readFile ./sway.config
          + ''
            set $Locker ${lock_script}
          '';
      };
  };
}
