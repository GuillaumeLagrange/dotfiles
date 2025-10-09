{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    niri.enable = lib.mkEnableOption "niri and its associated config";
  };

  config = lib.mkIf config.niri.enable {
    # Just install niri package - config will be in ~/.config/niri/config.kdl
    home.packages = with pkgs; [
      niri
    ];

    # Basic niri config file - keeping it minimal
    xdg.configFile."niri/config.kdl".text = ''
      input {
          keyboard {
              xkb {
                  layout "qwerty-fr"
                  options "ctrl:nocaps"
              }
          }

          touchpad {
              natural-scroll true
          }
      }

      spawn-at-startup "${pkgs._1password-gui}/bin/1password" "--silent"
      spawn-at-startup "${pkgs.protonmail-bridge}/bin/protonmail-bridge"
      spawn-at-startup "${pkgs.swaynotificationcenter}/bin/swaync"
      spawn-at-startup "${pkgs.blueman}/bin/blueman-applet"
      spawn-at-startup "${pkgs.waybar}/bin/waybar"

      prefer-no-csd

      // Basic app launchers
      binds {
          Mod+Return { spawn "${config.term}"; }
          Mod+W { spawn "${config.firefoxMain}"; }
          Mod+Shift+W { spawn "${config.firefoxAlt}"; }
          Mod+Ctrl+W { spawn "${config.chromium}"; }
          Mod+D { spawn "${pkgs.fuzzel}/bin/fuzzel"; }
          Mod+B { spawn "${pkgs.blueman}/bin/blueman-manager"; }
          Mod+N { spawn "${pkgs.swaynotificationcenter}/bin/swaync-client" "-t"; }
          Mod+V { spawn "sh" "-c" "${pkgs.cliphist}/bin/cliphist list | ${pkgs.fuzzel}/bin/fuzzel --dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"; }

          Print { spawn "sh" "-c" "${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -"; }

          XF86MonBrightnessUp { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "10%+"; }
          XF86MonBrightnessDown { spawn "${pkgs.brightnessctl}/bin/brightnessctl" "set" "10%-" "-n" "1"; }

          XF86AudioRaiseVolume { spawn "sh" "-c" "${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0"; }
          XF86AudioLowerVolume { spawn "sh" "-c" "${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"; }
          XF86AudioMute { spawn "${pkgs.wireplumber}/bin/wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }

          XF86AudioPlay { spawn "${pkgs.playerctl}/bin/playerctl" "play-pause"; }
          XF86AudioNext { spawn "${pkgs.playerctl}/bin/playerctl" "next"; }
          XF86AudioPrev { spawn "${pkgs.playerctl}/bin/playerctl" "previous"; }
      }

      window-rule {
          match app-id=r#"^spotify$"#
          open-on-workspace 10
      }
    '';
  };
}
