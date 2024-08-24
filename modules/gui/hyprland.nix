{
  pkgs,
  lib,
  config,
  ...
}:
let
  lock_script = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh";
in
{
  options = {
    hyprland.enable = lib.mkEnableOption "hyprland and its associated config";
  };

  config = lib.mkIf config.hyprland.enable {
    wayland.windowManager.hyprland = {
      enable = true;
      settings = {
        "$terminal" = "${pkgs.alacritty}/bin/alacritty";
        "$mainMod" = "SUPER";
        "$shiftMod" = "SUPER_SHIFT";
        "$ctrlMod" = "SUPER_CTRL";
        "$volumeNotification" = "${pkgs.pulseaudio}/bin/paplay ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga";

        exec-once = [
          "${pkgs._1password-gui}/bin/1password --silent"
          "${pkgs.networkmanagerapplet}/bin/nm-applet"
          "${pkgs.wpaperd}/bin/wpaperd"
          "${pkgs.protonmail-bridge}/bin/protonmail-bridge"
          "${pkgs.swaynotificationcenter}/bin/swaync"
          "${pkgs.blueman}/bin/blueman-applet"
          "${pkgs.xss-lock}/bin/xss-lock -- ${lock_script}"
        ];

        input = {
          # This requires pkgs.qwerty-fr to be installed
          kb_layout = "qwerty-fr";
          kb_options = "ctrl:nocaps";
          repeat_rate = 30;
          repeat_delay = 300;
          numlock_by_default = true;
          follow_mouse = 1;
          touchpad = {
            natural_scroll = true;
          };
          sensitivity = 0;
        };

        # Some default env vars.
        env = [
          "XCURSOR_SIZE,24"
          "QT_QPA_PLATFORMTHEME,qt6ct" # change to qt6ct if you have that
        ];

        general = {
          gaps_in = 2;
          gaps_out = 2;
          border_size = 1;
          layout = "master";
          allow_tearing = false;
        };

        decoration = {
          rounding = 2;

          blur = {
            enabled = true;
            size = 3;
            passes = 1;

            vibrancy = 0.1696;
          };

          drop_shadow = true;
          shadow_range = 4;
          shadow_render_power = 3;
          # "col.shadow" = "rgba(1a1a1aee)";
        };

        animations = {
          enabled = true;
          # Some default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more
          bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
          animation = [
            "windows, 1, 4, myBezier"
            "windowsOut, 1, 4, default, popin 80%"
            "border, 1, 3, default"
            "borderangle, 1, 3, default"
            "fade, 1, 3, default"
            "workspaces, 1, 3, default"
          ];
        };

        dwindle = {
          # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
          pseudotile = true; # master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = true; # you probably want this
        };

        master = {
          # See https://wiki.hyprland.org/Configuring/Master-Layout/ for more
          new_status = "inherit";
          no_gaps_when_only = false;
          mfact = 0.75;
        };

        gestures = {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          workspace_swipe = true;
          workspace_swipe_cancel_ratio = 0.3;
        };

        misc = {
          # See https://wiki.hyprland.org/Configuring/Variables/ for more
          force_default_wallpaper = 1; # Set to 0 or 1 to disable the anime mascot wallpapers
          focus_on_activate = true;
        };

        "$pictureInPicture" = "title:^(Picture-in-Picture)$";
        windowrulev2 = [
          # See https://wiki.hyprland.org/Configuring/Window-Rules/ for more
          "suppressevent maximize, class:.*" # You'll probably like this.
          "idleinhibit always, fullscreen:1"

          "stayfocused, title:^(swappy)$"
          "float, title:^(Bluetooth Devices)$"
          "float, $pictureInPicture"
          "move 100%-34% 100%-34%, $pictureInPicture"
          "size 33% 33%, $pictureInPicture"

          # Spotify to workspace 10
          "workspace 10, class:Spotify"
        ];

        # Monitors
        # Home
        "$mainHome" = "desc:Shenzhen KTC Technology Group OLED G27P6";
        "$mainHomeDefault" = "$mainHome, 2560x1440@240, 4480x0, 1";
        "$secondaryHome" = "desc:Dell Inc. DELL S2421HS 45WFW83";
        "$secondaryHomeDefault" = "$secondaryHome, 1920x1080@60, 7040x0, 1";
        # Office
        "$mainOffice" = "desc:AOC Q27P2W TAIN3HA011747";
        "$mainOfficeDefault" = "$mainOffice, 2560x1440@60, 0x0, 1";
        monitor = [
          "eDP-1, 1920x1200@60, 2560x0, 1"
          "$mainHomeDefault"
          "$secondaryHomeDefault"
          "$mainOfficeDefault"
        ];

        workspace = [
          "1, monitor:$mainHome, monitor:eDP-1, default:true"
          "3, monitor:$mainHome"
          "5, monitor:$mainHome"
          "7, monitor:$mainHome"
          "9, monitor:$mainHome"

          "2, monitor:$secondaryHome, default:true"
          "4, monitor:$secondaryHome"
          "6, monitor:$secondaryHome"
          "8, monitor:$secondaryHome"
          "10, monitor:$secondaryHome"
        ];

        # Outputs submap
        "$monitorsSubmap" = "Monitors (s)ingle (r)eset (w)allpaper (d)ual";
        "$restartWpaperd" = "killall wpaperd && hyprctl dispatch exec /usr/bin/wpaperd";

        "$backlight_step" = "20";
        bind = [
          "$mainMod, Return, exec, $terminal"
          "$mainMod, W, exec, firefox"
          "$shiftMod, A, killactive,"
          "$mainMod, Space, exec, hyprctl --batch \"dispatch togglefloating active\""
          "$mainMod, D, exec, ${pkgs.wofi}/bin/wofi --show drun"
          "$mainMod, Tab, exec, ${pkgs.wofi-emoji}/bin/wofi-emoji"
          "$mainMod, V, exec, ${pkgs.cliphist}/bin/cliphist list | ${pkgs.wofi}/bin/wofi --dmenu | ${pkgs.cliphist}/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy"
          "$mainMod, P, pseudo, # dwindle"
          "$mainMod, E, togglesplit, # dwindle"

          # Screenshot
          ", Print, exec, ${pkgs.grim}/bin/grim -g \"$(${pkgs.slurp}/bin/slurp)\" - | ${pkgs.swappy}/bin/swappy -f -"

          # Bluetooth
          "$mainMod, B, exec, ${pkgs.blueman}/bin/blueman-manager"

          # Volume
          ", XF86AudioMute, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && $volumeNotification"
          # Notification pannel toggle
          "$mainMod, N, exec, ${pkgs.swaynotificationcenter}/bin/swaync-client -t"

          # Media play
          ", XF86AudioPause, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
          ", XF86AudioPlay, exec, ${pkgs.playerctl}/bin/playerctl play-pause"
          ", XF86AudioNext, exec, ${pkgs.playerctl}/bin/playerctl next"
          ", XF86AudioPrev, exec, ${pkgs.playerctl}/bin/playerctl previous"

          # Sreen brightness controls
          ", XF86MonBrightnessUp, exec, ${pkgs.brightnessctl}/bin/brightnessctl set $backlight_step%+"
          ", XF86MonBrightnessDown, exec, ${pkgs.brightnessctl}/bin/brightnessctl set $backlight_step%- -n 1"
          # Stockly helpers
          "$mainMod, Backslash, exec, ${pkgs.alacritty}/bin/alacritty --title \"Charybdis nvim\" -e sh -c \"ssh -o ClearAllForwardings=yes -t charybdis 'exec env LANG=C.UTF-8 tmux new-session -A -s nvim'\""
          "$shiftMod, Backslash, exec, ${pkgs.alacritty}/bin/alacritty --title \"Charybdis bo\" -e sh -c \"ssh -q -t charybdis 'exec env LANG=C.UTF-8 tmux new-session -A -s bo'\""

          # Move focus with mainMod + arrow keys
          "$mainMod, H, movefocus, l"
          "$ctrlMod, H, changegroupactive, b"
          "$mainMod, L, movefocus, r"
          "$ctrlMod, L, changegroupactive, f"
          "$mainMod, K, movefocus, u"
          "$mainMod, J, movefocus, d"
          "$mainMod, Q, layoutmsg, swapwithmaster master"
          "$mainMod, P, pin"
          "$mainMod, F, fullscreen"
          "$mainMod, T, togglegroup"

          # Move window
          "$shiftMod, H, movewindow, l"
          "$shiftMod, L, movewindow, r"
          "$shiftMod, K, movewindow, u"
          "$shiftMod, J, movewindow, d"

          # Switch workspaces with mainMod + [0-9]
          "$mainMod, 1, workspace, 1"
          "$mainMod, 2, workspace, 2"
          "$mainMod, 3, workspace, 3"
          "$mainMod, 4, workspace, 4"
          "$mainMod, 5, workspace, 5"
          "$mainMod, 6, workspace, 6"
          "$mainMod, 7, workspace, 7"
          "$mainMod, 8, workspace, 8"
          "$mainMod, 9, workspace, 9"
          "$mainMod, 0, workspace, 10"

          # Move active window to a workspace with mainMod + SHIFT + [0-9]
          "$mainMod SHIFT, 1, movetoworkspacesilent, 1"
          "$mainMod SHIFT, 2, movetoworkspacesilent, 2"
          "$mainMod SHIFT, 3, movetoworkspacesilent, 3"
          "$mainMod SHIFT, 4, movetoworkspacesilent, 4"
          "$mainMod SHIFT, 5, movetoworkspacesilent, 5"
          "$mainMod SHIFT, 6, movetoworkspacesilent, 6"
          "$mainMod SHIFT, 7, movetoworkspacesilent, 7"
          "$mainMod SHIFT, 8, movetoworkspacesilent, 8"
          "$mainMod SHIFT, 9, movetoworkspacesilent, 9"
          "$mainMod SHIFT, 0, movetoworkspacesilent, 10"

          # Example special workspace (scratchpad)
          "$mainMod, S, togglespecialworkspace, scratchpad"
          "$shiftMod, S, movetoworkspace, special:scratchpad"

          # Scroll through existing workspaces with mainMod + scroll
          "$mainMod, mouse_down, workspace, e+1"
          "$mainMod, mouse_up, workspace, e-1"

          # Move workspace between monitors
          "$mainMod, X, movecurrentworkspacetomonitor, +1"
          "$shiftMod, X, movecurrentworkspacetomonitor, -1"
        ];

        # Holdable binds
        binde = [
          # Volume
          ", XF86AudioRaiseVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ --limit 1.0 && $volumeNotification"
          ", XF86AudioLowerVolume, exec, ${pkgs.wireplumber}/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 && ${pkgs.wireplumber}/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && $volumeNotification"
        ];

        bindm = [
          # Move/resize windows with mainMod + LMB/RMB and dragging
          "$mainMod, mouse:272, movewindow"
          "$mainMod, mouse:273, resizewindow"
        ];

        bindn = [ ", mouse:274, exec, ${pkgs.wl-clipboard}/bin/wl-copy -pc" ];
      };

      extraConfig = ''
        # Submpaps
        # Power submap
        $powerSubmap = Power (s)uspend (l)ock (e)xit (h)ibernate (p)oweroff (r)eboot
        bind = $mainMod, Escape, submap, $powerSubmap
        submap = $powerSubmap
        bind = , L, exec, ${lock_script}
        bind = , L, submap, reset
        bind = , S, exec, systemctl suspend-then-hibernate
        bind = , S, submap, reset
        bind = , E, exec, hyprctl dispatch exit
        bind = , E, submap, reset
        bind = , E, exec, hyprctl dispatch exit
        bind = , E, submap, reset
        bind = , H, exec, systemctl hibernate
        bind = , H, submap, reset
        bind = , P, exec, systemctl poweroff
        bind = , P, submap, reset
        bind = , R, exec, systemctl reboot
        bind = , R, submap, reset
        # ...
        bind = , Escape, submap, reset
        submap=reset

        bind = $mainMod, M, submap, $monitorsSubmap
        submap = $monitorsSubmap
        bind = , S, exec, hyprctl keyword monitor "desc:AOC Q27P2W TAIN3HA011747, disable"
        bind = , S, exec, hyprctl keyword monitor "desc:ASUSTek COMPUTER INC VG278 L1LMQS025816, disable"
        bind = , S, exec, hyprctl keyword monitor "desc:Dell Inc. DELL S2421HS 45WFW83, disable"
        bind = , S, exec, $restartWpaperd
        bind = , S, submap, reset
        # Home dual
        bind = , D, exec, hyprctl keyword monitor "desc:Dell Inc. DELL S2421HS 45WFW83, disable"
        bind = , D, exec, $restartWpaperd
        bind = , D, submap, reset
        bind = , W, exec, $restartWpaperd
        bind = , R, exec, hyprctl keyword monitor "$mainHomeDefault"
        bind = , R, exec, hyprctl keyword monitor "$secondaryHomeDefault"
        bind = , R, exec, hyprctl keyword monitor "$mainOfficeDefault"
        bind = , R, exec, $restartWpaperd
        bind = , R, submap, reset
        # ...
        bind = , Escape, submap, reset
        submap=reset
      '';
    };
  };
}
