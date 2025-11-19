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
      (import ./lock.nix { inherit pkgs; })
    ];

    home.sessionVariables = {
      DISPLAY = ":0";
    };

    # Basic niri config file - keeping it minimal
    xdg.configFile."niri/config.kdl".text =
      let
        ws_web = "1. Web";
        ws_term = "2. Term";
        ws_code = "3. Code";
        ws_scratchpad = "4. Scratch";
        ws_perso = "5. Perso";

        # Function to quote each element in a space-separated string
        quoteArgs = str: lib.concatMapStringsSep " " (arg: ''"${arg}"'') (lib.splitString " " str);
      in
      ''
        input {
            focus-follows-mouse max-scroll-amount="10%"

            keyboard {
                xkb {
                    layout "qwerty-fr"
                    options "ctrl:nocaps"
                }
                repeat-delay 300
                repeat-rate 30
            }

            touchpad {
                tap
                natural-scroll
            }
        }

        spawn-at-startup "${pkgs._1password-gui}/bin/1password" "--silent"
        spawn-at-startup "${pkgs.protonmail-bridge}/bin/protonmail-bridge"
        spawn-at-startup "${pkgs.mako}/bin/mako"
        spawn-at-startup "${pkgs.blueman}/bin/blueman-applet"
        // Spawn xwayland manually because NixOS stable does not have 25.08 yet
        spawn-at-startup "${pkgs.xwayland-satellite}/bin/xwayland-satellite"

        prefer-no-csd

        layout {
            gaps 4

            focus-ring {
                width 2
                active-color "#ad530d"
                inactive-color "#505050"
            }

            border {
                off
            }
        }

        workspace "${ws_web}"
        workspace "${ws_term}"
        workspace "${ws_code}"
        workspace "${ws_scratchpad}"
        workspace "${ws_perso}"

        binds {
            // Hotkey overlay
            Mod+Shift+Slash { show-hotkey-overlay; }

            // Application launching
            Mod+Return { spawn ${quoteArgs config.term}; }
            Mod+D { spawn "vicinae" "toggle"; }
            Super+Alt+L { spawn "lock.sh"; }
            Mod+Backslash { spawn ${quoteArgs config.term} "-e" "zsh" "-i" "-c" "tsm"; }

            // Browser launchers
            Mod+W { spawn "${config.firefoxMain}"; }
            Mod+Shift+W { spawn ${quoteArgs config.firefoxAlt}; }
            Mod+Ctrl+W { spawn "${config.chromium}"; }


            // Additional apps
            Mod+B { spawn "${pkgs.blueman}/bin/blueman-manager"; }
            Mod+N { spawn "${pkgs.mako}/bin/makoctl" "menu" "${pkgs.fuzzel}/bin/fuzzel" "-d" "-p" "Choose Action: "; }

            // Media and system keys
            XF86AudioRaiseVolume allow-when-locked=true { spawn "sh" "-c" "${config.audioUp}"; }
            XF86AudioLowerVolume allow-when-locked=true { spawn "sh" "-c" "${config.audioDown}"; }
            XF86AudioMute allow-when-locked=true { spawn "sh" "-c" "${config.audioMute}"; }

            // Media player controls
            XF86AudioPlay allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "play-pause"; }
            XF86AudioStop allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "stop"; }
            XF86AudioPrev allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "previous"; }
            XF86AudioNext allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "next"; }

            // Brightness controls
            XF86MonBrightnessUp allow-when-locked=true { spawn "sh" "-c" "${config.brightnessUp}"; }
            XF86MonBrightnessDown allow-when-locked=true { spawn "sh" "-c" "${config.brightnessDown}"; }

            // Screenshots
            Print { screenshot; }
            Shift+Print { spawn "sh" "-c" "${config.screenshotTool}"; }
            Ctrl+Print { screenshot-screen; }
            Alt+Print { screenshot-window; }

            // Window management
            Mod+O repeat=false { toggle-overview; }
            Mod+Tab repeat=false { toggle-overview; }
            Mod+Q repeat=false { close-window; }

            // Focus navigation
            Mod+Left  { focus-column-or-monitor-left; }
            Mod+Down  { focus-window-down; }
            Mod+Up    { focus-window-up; }
            Mod+Right { focus-column-or-monitor-right; }
            Mod+H     { focus-column-or-monitor-left; }
            Mod+U     { focus-window-down; }
            Mod+I     { focus-window-up; }
            Mod+L     { focus-column-or-monitor-right; }

            // Window movement
            Mod+Shift+Left  { move-column-left; }
            // Mod+Ctrl+Down  { move-window-down; }
            // Mod+Ctrl+Up    { move-window-up; }
            Mod+Shift+Right { move-column-right; }
            Mod+Shift+H     { move-column-left; }
            // Mod+Ctrl+U     { move-window-down; }
            // Mod+Ctrl+I     { move-window-up; }
            Mod+Shift+L     { move-column-right; }

            Mod+Home { focus-column-first; }
            Mod+End  { focus-column-last; }
            Mod+Ctrl+Home { move-column-to-first; }
            Mod+Ctrl+End  { move-column-to-last; }

            // Monitor navigation
            // Mod+Shift+Left  { focus-monitor-left; }
            Mod+Shift+Down  { focus-monitor-down; }
            Mod+Shift+Up    { focus-monitor-up; }
            // Mod+Shift+Right { focus-monitor-right; }
            // Mod+Shift+H     { focus-monitor-left; }
            // Mod+Shift+J     { focus-monitor-down; }
            // Mod+Shift+K     { focus-monitor-up; }
            // Mod+Shift+L     { focus-monitor-right; }

            // Move window to monitor
            Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
            Mod+Shift+Ctrl+Down  { move-column-to-monitor-down; }
            Mod+Shift+Ctrl+Up    { move-column-to-monitor-up; }
            Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }
            Mod+Shift+Ctrl+H     { move-column-to-monitor-left; }
            Mod+Shift+Ctrl+J     { move-column-to-monitor-down; }
            Mod+Shift+Ctrl+K     { move-column-to-monitor-up; }
            Mod+Shift+Ctrl+L     { move-column-to-monitor-right; }

            // Workspace navigation
            Mod+Page_Down      { focus-workspace-down; }
            Mod+Page_Up        { focus-workspace-up; }
            Mod+J              { focus-workspace-down; }
            Mod+K              { focus-workspace-up; }
            Mod+Shift+Page_Down { move-column-to-workspace-down; }
            Mod+Shift+Page_Up   { move-column-to-workspace-up; }
            Mod+Shift+J         { move-column-to-workspace-down; }
            Mod+Shift+K         { move-column-to-workspace-up; }

            Mod+Ctrl+Page_Down { move-workspace-down; }
            Mod+Ctrl+Page_Up   { move-workspace-up; }
            Mod+Ctrl+J         { move-workspace-down; }
            Mod+Ctrl+K         { move-workspace-up; }

            // Move workspace to next monitor
            Mod+Z { move-workspace-to-monitor-left; }
            Mod+X { move-workspace-to-monitor-right; }

            // Mouse wheel workspace navigation
            Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
            Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
            Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
            Mod+Ctrl+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }

            Mod+WheelScrollRight      { focus-column-right; }
            Mod+WheelScrollLeft       { focus-column-left; }
            Mod+Ctrl+WheelScrollRight { move-column-right; }
            Mod+Ctrl+WheelScrollLeft  { move-column-left; }

            Mod+Shift+WheelScrollDown      { focus-column-right; }
            Mod+Shift+WheelScrollUp        { focus-column-left; }
            Mod+Ctrl+Shift+WheelScrollDown { move-column-right; }
            Mod+Ctrl+Shift+WheelScrollUp   { move-column-left; }

            // Named workspace navigation
            Mod+1 { focus-workspace "${ws_web}"; }
            Mod+2 { focus-workspace "${ws_term}"; }
            Mod+3 { focus-workspace "${ws_code}"; }
            Mod+4 { focus-workspace "${ws_scratchpad}"; }
            Mod+5 { focus-workspace "${ws_perso}"; }
            Mod+Shift+1 { move-column-to-workspace "${ws_web}"; }
            Mod+Shift+2 { move-column-to-workspace "${ws_term}"; }
            Mod+Shift+3 { move-column-to-workspace "${ws_code}"; }
            Mod+Shift+4 { move-column-to-workspace "${ws_scratchpad}"; }
            Mod+Shift+5 { move-column-to-workspace "${ws_perso}"; }

            // Workspace by index
            // Mod+4 { focus-workspace 4; }
            // Mod+5 { focus-workspace 5; }
            // Mod+6 { focus-workspace 6; }
            // Mod+7 { focus-workspace 7; }
            // Mod+8 { focus-workspace 8; }
            // Mod+9 { focus-workspace 9; }
            // Mod+Ctrl+4 { move-column-to-workspace 4; }
            // Mod+Ctrl+5 { move-column-to-workspace 5; }
            // Mod+Ctrl+6 { move-column-to-workspace 6; }
            // Mod+Ctrl+7 { move-column-to-workspace 7; }
            // Mod+Ctrl+8 { move-column-to-workspace 8; }
            // Mod+Ctrl+9 { move-column-to-workspace 9; }

            // Column management
            Mod+BracketLeft  { consume-or-expel-window-left; }
            Mod+BracketRight { consume-or-expel-window-right; }
            Mod+Comma  { consume-window-into-column; }
            Mod+Period { expel-window-from-column; }

            // Window sizing and layout
            Mod+R { switch-preset-column-width; }
            Mod+Shift+R { switch-preset-window-height; }
            Mod+Ctrl+R { reset-window-height; }
            Mod+F { maximize-column; }
            Mod+Shift+F { fullscreen-window; }
            Mod+Ctrl+F { expand-column-to-available-width; }
            Mod+C { center-column; }
            Mod+Ctrl+C { center-visible-columns; }

            // Width adjustments
            Mod+Minus { set-column-width "-10%"; }
            Mod+Equal { set-column-width "+10%"; }
            Mod+Shift+Minus { set-window-height "-10%"; }
            Mod+Shift+Equal { set-window-height "+10%"; }

            // Floating windows
            Mod+Space { switch-focus-between-floating-and-tiling; }
            Mod+Shift+Space       { toggle-window-floating; }

            // System actions
            Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }
            Mod+Shift+E { quit; }
            Ctrl+Alt+Delete { quit; }
            Mod+Shift+P { power-off-monitors; }
        }

        window-rule {
            geometry-corner-radius 4
            clip-to-geometry true
        }
      '';
  };
}
