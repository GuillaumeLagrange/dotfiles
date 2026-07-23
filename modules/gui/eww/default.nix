{
  flake.modules.homeManager.eww =
    { pkgs, config, ... }:
    let
      # Runtime deps the bar scripts shell out to.
      runtimePath = pkgs.lib.makeBinPath [
        # eww runs deflisten/defpoll/onclick commands via `sh -c`, so a shell
        # must be on the daemon's PATH — without it every listen-var fails with
        # ENOENT (the missing shell, not the command).
        pkgs.bash
        pkgs.niri
        pkgs.jq
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused # sed, for pulseaudio sink-name extraction
        pkgs.playerctl
        pkgs.curl # mpris album-art download
        pkgs.xdg-utils # xdg-open, for "jump to source" from the now-playing title
        pkgs.wireplumber
        pkgs.pulseaudio # pactl, for the pulseaudio deflisten
        pkgs.mako
        pkgs.power-profiles-daemon
        pkgs.glib.bin # gdbus, for the power-profile watch
        pkgs.procps
        pkgs.systemd
        pkgs.pavucontrol
      ];

      # Each script wraps its .sh with the runtime deps on PATH. The yuck refers
      # to these by absolute `${bin <name>}` path (see below) rather than bare
      # command name — eww's deflisten does not resolve bare names against PATH
      # reliably, so absolute paths are the robust idiom.
      mkScript =
        name: file:
        pkgs.writeShellScriptBin name ''
          export PATH="${runtimePath}:$PATH"
          exec ${pkgs.bash}/bin/bash ${file} "$@"
        '';

      idleInhibit = mkScript "idle-inhibit" ./scripts/idle-inhibit.sh;

      # settings.sh reaches idle-inhibit by name and pushes state via `eww update`.
      settings = pkgs.writeShellScriptBin "settings-eww" ''
        export PATH="${runtimePath}:${idleInhibit}/bin:${pkgs.eww}/bin:$PATH"
        export IDLE_INHIBIT_BIN="${idleInhibit}/bin/idle-inhibit"
        exec ${pkgs.bash}/bin/bash ${./scripts/settings.sh} "$@"
      '';

      # Reused verbatim from the waybar setup.
      claudeUsage = pkgs.writeShellScriptBin "claude-usage-eww" ''
        export PATH="${pkgs.lib.makeBinPath [ pkgs.jq pkgs.curl pkgs.coreutils pkgs.gnused ]}:$PATH"
        export AI_USAGE_COMMON="${../bar-scripts/ai-usage-common.sh}"
        export AI_USAGE_RETRY_LIMIT="5"
        exec ${pkgs.bash}/bin/bash ${../bar-scripts/claude-usage.sh} "$@"
      '';
      memorySwap = pkgs.writeShellScriptBin "memory-swap-eww" ''
        export PATH="${pkgs.lib.makeBinPath [ pkgs.gawk pkgs.coreutils ]}:$PATH"
        exec ${pkgs.bash}/bin/bash ${../bar-scripts/memory-swap.sh} "$@"
      '';

      niriState = mkScript "niri-state" ./scripts/niri-state.sh;

      # Player glyphs injected from Nix (fromJSON \u escapes) rather than printed
      # by the script: `printf '\uXXXX'` is not portable across the daemon's
      # shell/printf and silently emits the literal escape there.
      mprisIcons = {
        spotify = builtins.fromJSON ''"\uf1bc"''; # nf-fa-spotify
        firefox = builtins.fromJSON ''"\uf269"''; # nf-fa-firefox
        chrome  = builtins.fromJSON ''"\uf268"''; # nf-fa-chrome
        movie   = builtins.fromJSON ''"\udb80\udf81"''; # nf-md-movie U+F0381 (JSON surrogate pair)
        music   = builtins.fromJSON ''"\uf001"''; # nf-fa-music
      };
      mpris = pkgs.writeShellScriptBin "mpris-eww" ''
        export PATH="${runtimePath}:$PATH"
        export MPRIS_ICON_SPOTIFY=${pkgs.lib.escapeShellArg mprisIcons.spotify}
        export MPRIS_ICON_FIREFOX=${pkgs.lib.escapeShellArg mprisIcons.firefox}
        export MPRIS_ICON_CHROME=${pkgs.lib.escapeShellArg mprisIcons.chrome}
        export MPRIS_ICON_MOVIE=${pkgs.lib.escapeShellArg mprisIcons.movie}
        export MPRIS_ICON_MUSIC=${pkgs.lib.escapeShellArg mprisIcons.music}
        exec ${pkgs.bash}/bin/bash ${./scripts/mpris.sh} "$@"
      '';
      disk = mkScript "disk-eww" ./scripts/disk.sh;
      cpu = mkScript "cpu-eww" ./scripts/cpu.sh;
      battery = mkScript "battery-eww" ./scripts/battery.sh;
      pulseaudio = mkScript "pulseaudio-eww" ./scripts/pulseaudio.sh;
      # calendar's `push` mode calls `eww update`, so it needs eww on PATH.
      calendar = pkgs.writeShellScriptBin "calendar-eww" ''
        export PATH="${runtimePath}:${pkgs.eww}/bin:$PATH"
        exec ${pkgs.bash}/bin/bash ${./scripts/calendar.sh} "$@"
      '';

      # Popup-open helpers. eww onclick handlers that call `eww` back (open /
      # update) block against the daemon and hit its ~1s kill; these are run
      # detached (setsid -f) from the widgets, so the handler returns at once and
      # the eww calls happen in the background. $1 = monitor connector.
      eww = "${pkgs.eww}/bin/eww";
      calSeedOpen = pkgs.writeShellScriptBin "eww-cal-open" ''
        m="$1"
        ${calendar}/bin/calendar-eww push 0
        ${eww} open backdrop-calendar --screen "$m" --arg monitor="$m"
        ${eww} open calendar-popup     --screen "$m" --arg monitor="$m"
      '';
      settingsOpen = pkgs.writeShellScriptBin "eww-settings-open" ''
        m="$1"
        ${eww} open backdrop-settings --screen "$m" --arg monitor="$m"
        ${eww} open settings-popup    --screen "$m" --arg monitor="$m"
      '';

      # Now-playing popup: seed the deck, open backdrop+popup, then run a 1s
      # refresh loop that lives only while the popup is open (so the position
      # ticks without polling when the popup is closed). The loop's PID is
      # written to a runtime pidfile so mprisClose can stop it.
      mprisPidfile = "\${XDG_RUNTIME_DIR:-/tmp}/eww-mpris-deck.pid";
      mprisOpen = pkgs.writeShellScriptBin "eww-mpris-open" ''
        m="$1"
        ${eww} update "mprisdeck=$(${mpris}/bin/mpris-eww deck)"
        ${eww} open backdrop-mpris --screen "$m" --arg monitor="$m"
        ${eww} open mpris-popup    --screen "$m" --arg monitor="$m"
        # Stop any stale loop, then start a fresh one and record its PID.
        [ -f "${mprisPidfile}" ] && kill "$(cat "${mprisPidfile}")" 2>/dev/null || true
        (
          while true; do
            ${eww} update "mprisdeck=$(${mpris}/bin/mpris-eww deck)"
            sleep 1
          done
        ) &
        echo $! > "${mprisPidfile}"
      '';
      mprisClose = pkgs.writeShellScriptBin "eww-mpris-close" ''
        [ -f "${mprisPidfile}" ] && kill "$(cat "${mprisPidfile}")" 2>/dev/null || true
        rm -f "${mprisPidfile}"
        ${eww} close mpris-popup backdrop-mpris
      '';
      claudeRefresh = pkgs.writeShellScriptBin "eww-claude-refresh" ''
        ${claudeUsage}/bin/claude-usage-eww "$@"
        ${eww} update "claude=$(${claudeUsage}/bin/claude-usage-eww)"
      '';

      allScripts = [
        niriState
        mpris
        disk
        cpu
        battery
        pulseaudio
        calendar
        calSeedOpen
        settingsOpen
        mprisOpen
        mprisClose
        claudeRefresh
        idleInhibit
        settings
        claudeUsage
        memorySwap
      ];

      # Absolute paths to every command the yuck / bar-launch invoke, so nothing
      # depends on PATH resolution.
      bins = {
        niriState = "${niriState}/bin/niri-state";
        mpris = "${mpris}/bin/mpris-eww";
        disk = "${disk}/bin/disk-eww";
        cpu = "${cpu}/bin/cpu-eww";
        battery = "${battery}/bin/battery-eww";
        pulseaudio = "${pulseaudio}/bin/pulseaudio-eww";
        settings = "${settings}/bin/settings-eww";
        claudeUsage = "${claudeUsage}/bin/claude-usage-eww";
        memorySwap = "${memorySwap}/bin/memory-swap-eww";
        calendar = "${calendar}/bin/calendar-eww";
        calSeedOpen = "${calSeedOpen}/bin/eww-cal-open";
        settingsOpen = "${settingsOpen}/bin/eww-settings-open";
        mprisOpen = "${mprisOpen}/bin/eww-mpris-open";
        mprisClose = "${mprisClose}/bin/eww-mpris-close";
        claudeRefresh = "${claudeRefresh}/bin/eww-claude-refresh";
        eww = "${pkgs.eww}/bin/eww";
        # Glyphs via JSON \u escapes so the source stays ASCII (literal glyphs
        # get stripped by some editors). Chevrons U+2039/U+203A; transport +
        # expand are nerd-font (U+F048.. play/pause/skip, U+F065 expand).
        larrow = builtins.fromJSON ''"\u2039"'';
        rarrow = builtins.fromJSON ''"\u203a"'';
        expandGlyph = builtins.fromJSON ''"\uf065"'';   # nf-fa-expand
        playGlyph   = builtins.fromJSON ''"\uf04b"'';   # nf-fa-play
        pauseGlyph  = builtins.fromJSON ''"\uf04c"'';   # nf-fa-pause
        prevGlyph   = builtins.fromJSON ''"\uf048"'';   # nf-fa-step_backward
        nextGlyph   = builtins.fromJSON ''"\uf051"'';   # nf-fa-step_forward
        niri = "${pkgs.niri}/bin/niri";
        wpctl = "${pkgs.wireplumber}/bin/wpctl";
        pavucontrol = "${pkgs.pavucontrol}/bin/pavucontrol";
        setsid = "${pkgs.util-linux}/bin/setsid";
        date = "${pkgs.coreutils}/bin/date";
        screenrecord = config.screenrecordScreenTool;
      };

      ewwYuck = import ./_eww-yuck.nix { inherit bins; };

      daemonPath = "${pkgs.lib.makeBinPath (allScripts ++ [ pkgs.eww ])}:${runtimePath}";

      barLaunch = pkgs.writeShellScriptBin "eww-bar-launch" ''
        export PATH="${daemonPath}:$PATH"
        exec ${pkgs.bash}/bin/bash ${./scripts/bar-launch.sh} "$@"
      '';
    in
    {
      home.packages = [
        pkgs.eww
        barLaunch
      ]
      ++ allScripts;

      xdg.configFile = {
        "eww/eww.yuck".text = ewwYuck;
        "eww/eww.scss".source = ./eww.scss;
      };

      # Clear the idle-inhibit pidfile before the bar comes up so the toggle
      # starts deactivated on every (re)start, matching waybar's native module.
      systemd.user.services.eww-idle-reset = {
        Unit = {
          Description = "Reset eww idle-inhibit state on (re)start";
          Before = [ "eww.service" ];
          PartOf = [ "eww.service" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${idleInhibit}/bin/idle-inhibit reset";
        };
        Install.WantedBy = [ "eww.service" ];
      };

      systemd.user.services.eww = {
        Unit = {
          Description = "eww bar";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          Environment = [ "PATH=${daemonPath}" ];
          ExecStart = "${barLaunch}/bin/eww-bar-launch";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };

      # Seeds the settings vars at startup and pushes on external power-profile
      # changes (e.g. auto power-saver on low battery). User-initiated toggles
      # push from their own click handlers, so this only covers external events.
      systemd.user.services.eww-settings-watch = {
        Unit = {
          Description = "Push power-profile changes into the eww bar";
          PartOf = [ "eww.service" ];
          After = [ "eww.service" ];
        };
        Service = {
          ExecStart = "${settings}/bin/settings-eww watch";
          Restart = "on-failure";
        };
        Install.WantedBy = [ "eww.service" ];
      };
    };
}
