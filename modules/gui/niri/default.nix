{
  flake.modules.homeManager.niri =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      workspaces = pkgs.callPackage ./_workspaces.nix { };
      displays = pkgs.callPackage ./_displays.nix { };

      # Only granary has caffeine.service; elsewhere logind suspends on the lid anyway.
      lidClose = pkgs.writeShellScript "niri-lid-close" ''
        ${pkgs.systemd}/bin/systemctl is-active --quiet caffeine.service || exit 0
        ${pkgs.procps}/bin/pgrep hyprlock >/dev/null || { ${config.lock} & ${pkgs.coreutils}/bin/sleep 1; }
        ${pkgs.niri}/bin/niri msg action power-off-monitors
      '';

      # Mod+Ctrl+S: timestamps a felt stutter next to niri-stall's reports (stall-tracing.nix).
      stutterMark = pkgs.writeShellScript "stutter-mark" ''
        avg10() { read -r _ avg _ <"$1"; echo "''${avg#avg10=}"; }
        ${pkgs.util-linux}/bin/logger -t stutter \
          "mark, psi some avg10: memory $(avg10 /proc/pressure/memory) io $(avg10 /proc/pressure/io) cpu $(avg10 /proc/pressure/cpu)"
        ${pkgs.libnotify}/bin/notify-send -t 2000 "Stutter marked"
      '';
    in
    {
      home.packages = with pkgs; [
        niri
        xwayland-satellite
        workspaces
        displays
        # secret-tool, through which CLIs such as linear reach gnome-keyring
        libsecret
      ];

      # Numbered workspaces the sway way: see workspaces.py.
      systemd.user.services.niri-workspaces = {
        Unit = {
          Description = "Keep niri's numbered workspaces sway-like";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${workspaces}/bin/niri-workspaces watch --assign=signal=5 '--assign=^spotify$=5'";
          Environment = [ "PYTHONUNBUFFERED=1" ];
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      # Saved display setups (displays.py): applies the last used one of the monitors plugged in.
      systemd.user.services.niri-displays = {
        Unit = {
          Description = "Apply the saved display setup of the connected monitors";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStart = "${displays}/bin/niri-displays watch";
          Environment = [ "PYTHONUNBUFFERED=1" ];
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      xdg.configFile."niri/config.kdl".text =
        let
          numbers = map toString (lib.range 1 9);
          quoteArgs = str: lib.concatMapStringsSep " " (arg: ''"${arg}"'') (lib.splitString " " str);
        in
        # kdl
        ''
          // Modes and positions are saved setups (niri-displays), not config. What the IPC cannot set stays here:
          // the KTC's always-on pixel orbiting pushes the 2px focus ring off the panel's side edges.
          output "Shenzhen KTC Technology Group OLED G27P6 Unknown" {
              layout { struts { left 4; right 4; }; }
          }

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
                  click-method "clickfinger"
              }
          }

          ${lib.optionalString config.work.enable ''spawn-at-startup "${pkgs._1password-gui}/bin/1password" "--silent"''}
          spawn-at-startup "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"

          switch-events {
              lid-close { spawn "${lidClose}"; }
              // Caffeine blanked them at lid close; nothing else wakes them but input.
              lid-open { spawn "${pkgs.niri}/bin/niri" "msg" "action" "power-on-monitors"; }
          }

          prefer-no-csd

          hotkey-overlay {
              skip-at-startup
          }

          layout {
              gaps 2
              default-column-width { proportion 0.5; }

              focus-ring {
                  width 2
                  active-color "#ad530d"
                  inactive-color "#505050"
              }

              border {
                off
              }
          }

          // Niri does not support $XDG_PICTURES_DIR: https://github.com/niri-wm/niri/issues/3346
          screenshot-path "~/pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

          binds {
              Mod+Shift+Slash { show-hotkey-overlay; }

              Mod+Return { spawn ${quoteArgs config.term}; }
              Mod+D { spawn "vicinae" "toggle"; }
              Mod+Shift+D { spawn "vicinae" "deeplink" "vicinae://launch/wm/switch-windows"; }
              Mod+V { spawn "vicinae" "deeplink" "vicinae://launch/clipboard/history"; }
              Mod+E { spawn "vicinae" "deeplink" "vicinae://launch/core/search-emojis"; }
              Mod+O { spawn "vicinae" "deeplink" "vicinae://launch/@knoopx/firefox/bookmarks"; }
              Mod+Shift+O { spawn "vicinae" "deeplink" "vicinae://launch/@knoopx/firefox/history"; }
              Super+Alt+L { spawn "${config.lock}"; }
              // Class zellij-session: the window rule below opens them full width, like zellij-attach's.
              Mod+Backslash { spawn ${quoteArgs config.term} "--class" "zellij-session" "-e" "zsh" "-i" "-c" "zsm"; }
              ${lib.optionalString config.work.enable ''Mod+Shift+Backslash { spawn ${quoteArgs config.term} "--class" "zellij-session" "-e" "zsh" "-i" "-c" "review"; }''}
              // omp-panel in its own floating window: Esc closes it, Enter goes to the omp.
              Mod+A { spawn ${quoteArgs config.term} "--class" "omp-panel" "-e" "omp-panel"; }
              Mod+BackSpace { spawn ${quoteArgs config.term} "--class" "omp-panel" "-e" "omp-panel"; }

              Mod+W { spawn "${config.firefox.main}"; }
              Mod+Shift+W { spawn ${quoteArgs config.firefox.alt}; }
              Mod+Ctrl+W { spawn "${config.browsers.chromium}"; }

              Mod+N { spawn ${quoteArgs "${config.quickshellIpc} notifs center"}; }
              Mod+Shift+N { spawn ${quoteArgs "${config.quickshellIpc} notifs clear"}; }
              Mod+Ctrl+N { spawn ${quoteArgs "${config.quickshellIpc} notifs dnd"}; }
              Mod+P { spawn ${quoteArgs "${config.quickshellIpc} media panel"}; }
              Mod+B { spawn ${quoteArgs "${config.quickshellIpc} bt panel"}; }
              ${lib.optionalString config.work.enable "Mod+Shift+Apostrophe { spawn ${quoteArgs "${config.quickshellIpc} reviews panel"}; }"}

              XF86AudioRaiseVolume allow-when-locked=true { spawn "sh" "-c" "${config.audio.up}"; }
              XF86AudioLowerVolume allow-when-locked=true { spawn "sh" "-c" "${config.audio.down}"; }
              XF86AudioMute allow-when-locked=true { spawn "sh" "-c" "${config.audio.mute}"; }

              XF86AudioPlay allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "play-pause"; }
              XF86AudioPause allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "pause"; }
              XF86AudioStop allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "stop"; }
              XF86AudioPrev allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "previous"; }
              XF86AudioNext allow-when-locked=true { spawn "${pkgs.playerctl}/bin/playerctl" "next"; }
              XF86AudioMedia { spawn "${config.lock}"; }

              XF86MonBrightnessUp allow-when-locked=true { spawn "sh" "-c" "${config.brightness.up}"; }
              Shift+XF86MonBrightnessUp allow-when-locked=true { spawn "sh" "-c" "${config.brightness.max}"; }
              XF86MonBrightnessDown allow-when-locked=true { spawn "sh" "-c" "${config.brightness.down}"; }
              Shift+XF86MonBrightnessDown allow-when-locked=true { spawn "sh" "-c" "${config.brightness.min}"; }

              Print { screenshot; }
              Shift+Print { spawn "sh" "-c" "${config.screenshotTool}"; }
              Ctrl+Print { screenshot-screen; }
              Alt+Print { screenshot-window; }

              Mod+Print hotkey-overlay-title="Toggle Screen Recording" { spawn "sh" "-c" "${config.screenrecordScreenTool}"; }
              Mod+Shift+Print hotkey-overlay-title="Toggle Region Recording" { spawn "sh" "-c" "${config.screenrecordRegionTool}"; }

              Mod+Tab repeat=false { toggle-overview; }
              Mod+Q repeat=false { close-window; }

              Mod+Left  { focus-column-or-monitor-left; }
              Mod+Down  { focus-window-down; }
              Mod+Up    { focus-window-up; }
              Mod+Right { focus-column-or-monitor-right; }
              Mod+H     { focus-column-left; }
              Mod+U     { focus-window-down; }
              Mod+I     { focus-window-up; }
              Mod+L     { focus-column-right; }

              Mod+Shift+Left  { move-column-left; }
              Mod+Shift+Right { move-column-right; }
              Mod+Shift+H     { move-column-left; }
              Mod+Shift+L     { move-column-right; }

              Mod+Home { focus-column-first; }
              Mod+End  { focus-column-last; }
              Mod+Ctrl+Home { move-column-to-first; }
              Mod+Ctrl+End  { move-column-to-last; }

              Mod+Shift+Down  { focus-monitor-down; }
              Mod+Shift+Up    { focus-monitor-up; }

              Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
              Mod+Shift+Ctrl+Down  { move-column-to-monitor-down; }
              Mod+Shift+Ctrl+Up    { move-column-to-monitor-up; }
              Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }
              Mod+Shift+Ctrl+H     { move-column-to-monitor-left; }
              Mod+Shift+Ctrl+J     { move-column-to-monitor-down; }
              Mod+Shift+Ctrl+K     { move-column-to-monitor-up; }
              Mod+Shift+Ctrl+L     { move-column-to-monitor-right; }

              Mod+Page_Down      { focus-workspace-down; }
              Mod+Page_Up        { focus-workspace-up; }
              Mod+J              { focus-workspace-down; }
              Mod+K              { focus-workspace-up; }
              Mod+Shift+Page_Down { move-column-to-workspace-down; }
              Mod+Shift+Page_Up   { move-column-to-workspace-up; }
              Mod+Shift+J         { move-column-to-workspace-down; }
              Mod+Shift+K         { move-column-to-workspace-up; }

              // The watcher sorts the workspaces of the output it lands on.
              Mod+X { move-workspace-to-monitor-next; }

              Mod+Ctrl+S hotkey-overlay-title="Mark a Stutter in the Journal" { spawn "${stutterMark}"; }

              Mod+WheelScrollDown      { focus-column-right; }
              Mod+WheelScrollUp        { focus-column-left; }
              Mod+Ctrl+WheelScrollDown { move-column-right; }
              Mod+Ctrl+WheelScrollUp   { move-column-left; }

              Mod+WheelScrollRight      { focus-column-right; }
              Mod+WheelScrollLeft       { focus-column-left; }
              Mod+Ctrl+WheelScrollRight { move-column-right; }
              Mod+Ctrl+WheelScrollLeft  { move-column-left; }

              Mod+Shift+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
              Mod+Shift+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
              Mod+Ctrl+Shift+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
              Mod+Ctrl+Shift+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }

              ${lib.concatMapStrings (n: ''
                Mod+${n} { spawn "${workspaces}/bin/niri-workspaces" "focus" "${n}"; }
                Mod+Shift+${n} { spawn "${workspaces}/bin/niri-workspaces" "move" "${n}"; }
              '') numbers}

              Mod+BracketLeft  { consume-or-expel-window-left; }
              Mod+BracketRight { consume-or-expel-window-right; }
              Mod+Comma  { consume-window-into-column; }
              Mod+Period { expel-window-from-column; }

              Mod+R { switch-preset-column-width; }
              Mod+Shift+R { switch-preset-window-height; }
              Mod+Ctrl+R { reset-window-height; }
              Mod+F { maximize-column; }
              Mod+Shift+F { fullscreen-window; }
              Mod+Ctrl+F { expand-column-to-available-width; }
              Mod+C { center-column; }
              Mod+Ctrl+C { center-visible-columns; }

              Mod+Minus { set-column-width "-10%"; }
              Mod+Equal { set-column-width "+10%"; }
              Mod+Shift+Minus { set-window-height "-10%"; }
              Mod+Shift+Equal { set-window-height "+10%"; }

              Mod+Space { switch-focus-between-floating-and-tiling; }
              Mod+Shift+Space       { toggle-window-floating; }

              Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }
              Mod+Shift+E { quit; }
              Ctrl+Alt+Delete { quit; }
              Mod+Shift+P { power-off-monitors; }
              Mod+M hotkey-overlay-title="Next Display Setup" { spawn "${displays}/bin/niri-displays" "next"; }
              Mod+Shift+M hotkey-overlay-title="Previous Display Setup" { spawn "${displays}/bin/niri-displays" "prev"; }
          }

          window-rule {
              geometry-corner-radius 4
              clip-to-geometry true
          }

          // Open full width as a maximized column, so Mod+F restores the default width.
          window-rule {
              match app-id="^zellij-session$"
              match app-id="^firefox$"
              exclude title="^Picture-in-Picture$"

              open-maximized true
          }

          window-rule {
              match app-id="^omp-panel$"

              open-floating true
              default-column-width { proportion 0.8; }
              default-window-height { proportion 0.7; }
          }

          window-rule {
              match app-id="firefox$" title="^Picture-in-Picture$"

              open-floating true
              default-column-width { fixed 480; }
              default-window-height { fixed 270; }
              default-floating-position x=32 y=32 relative-to="bottom-right"
          }

          // Steam's friends list and chats (titled after the friend) tile as narrow
          // columns; only known dialogs float.
          // Games have app-id steam_app_<id>, so they are unaffected.
          window-rule {
              match app-id="^steam$"
              exclude app-id="^steam$" title="^(Steam|Special Offers|Steam Big Picture Mode)$"

              default-column-width { proportion 0.25; }
          }

          window-rule {
              match app-id="^steam$" title="^(Steam Settings|Sign in to Steam|Steam Guard.*|Screenshot Manager|Install - .*|Uninstall - .*|.* - Properties)$"

              open-floating true
          }

          window-rule {
              match app-id="^steam$" title=r#"^notificationtoasts_\d+_desktop$"#

              default-floating-position x=10 y=10 relative-to="bottom-right"
              open-focused false
          }

          window-rule {
              match app-id="^xdg-desktop-portal-gtk$"

              open-floating true
          }

          // Disable alt tab
          recent-windows {
            off
          }

          gestures {
            hot-corners {
              top-left
              // Patched in (patch.nix): the pointer has to rest in the corner, and is kept
              // from sliding onto the neighbouring output within 50 px of it. The bottom-left
              // corner is the bar's start menu (quickshell StartCorner): barrier only.
              delay-ms 150
              barrier 50
              barrier-corners {
                bottom-left
              }
            }
          }

          // Make niri accept xdg activations more reliably
          debug {
            honor-xdg-activation-with-invalid-serial
          }
        '';
    };

  flake.modules.nixos.niri = {
    programs.niri.enable = true;
    # Swapped-out compositor pages stall the main loop when touched again.
    systemd.user.services.niri.serviceConfig.MemorySwapMax = 0;
  };
}
