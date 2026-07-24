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
      # mpris.py talks to D-Bus via Gio (PyGObject), so it needs a python with
      # pygobject3. The GI runtime needs glib/gobject-introspection on the
      # library path, which withPackages wires up.
      mprisPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
      mpris = pkgs.writeShellScriptBin "mpris-eww" ''
        export PATH="${runtimePath}:$PATH"
        export MPRIS_ICON_SPOTIFY=${pkgs.lib.escapeShellArg mprisIcons.spotify}
        export MPRIS_ICON_FIREFOX=${pkgs.lib.escapeShellArg mprisIcons.firefox}
        export MPRIS_ICON_CHROME=${pkgs.lib.escapeShellArg mprisIcons.chrome}
        export MPRIS_ICON_MOVIE=${pkgs.lib.escapeShellArg mprisIcons.movie}
        export MPRIS_ICON_MUSIC=${pkgs.lib.escapeShellArg mprisIcons.music}
        exec ${mprisPython}/bin/python3 ${./scripts/mpris.py} "$@"
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

      eww = "${pkgs.eww}/bin/eww";

      # Hover-driven popups (media panel, calendar, settings). Three scripts per
      # popup, because GTK fires hover/hover-lost as the pointer crosses a
      # window's *child* widgets:
      #   open  — trigger hover: mark open, show the window (runs detached; an
      #           onclick/onhover that calls `eww` back would block the
      #           single-threaded daemon and hit its ~1s handler kill).
      #   keep  — popup hover: only refresh the flag's mtime. No `eww` call, so
      #           the churn from crossing child widgets can't re-open the window
      #           (re-opening on every event makes it flicker).
      #   close — popup/trigger hover-lost: debounce, then hide. A re-hover during
      #           the debounce (from open or keep) pushes the flag's mtime past the
      #           closing marker, which aborts the close.
      # `seed` runs before the window is shown, for popups whose content is pushed
      # rather than polled. `postClose` runs after it's hidden.
      mkHoverPopup =
        {
          name,
          window,
          var,
          seed ? "",
          postClose ? "",
        }:
        let
          flag = "\${XDG_RUNTIME_DIR:-/tmp}/eww-${name}-open";
          closing = "\${XDG_RUNTIME_DIR:-/tmp}/eww-${name}-closing";
        in
        {
          inherit flag;
          open = pkgs.writeShellScriptBin "eww-${name}-open" ''
            m="$1"
            touch "${flag}"
            ${seed}
            ${eww} update ${var}=true
            ${eww} open ${window} --screen "$m" --arg monitor="$m" 2>/dev/null || true
          '';
          keep = pkgs.writeShellScriptBin "eww-${name}-keep" ''
            touch "${flag}"
          '';
          close = pkgs.writeShellScriptBin "eww-${name}-close" ''
            touch "${closing}"
            sleep 0.30
            if [ "${flag}" -nt "${closing}" ]; then rm -f "${closing}"; exit 0; fi
            rm -f "${closing}"
            ${eww} update ${var}=false
            ${eww} close ${window} 2>/dev/null || true
            rm -f "${flag}"
            ${postClose}
          '';
        };

      # The pos/scroll deflistens gate on the media panel's flag — it is cleared
      # only after the window is hidden, so the scroll daemon's reset frame lands
      # in an already-hidden label instead of visibly snapping to the title start.
      mprisPopup = mkHoverPopup {
        name = "mpris";
        window = "mpris-popup";
        var = "mpris_open";
      };
      calPopup = mkHoverPopup {
        name = "cal";
        window = "calendar-popup";
        var = "cal_open";
        seed = "${calendar}/bin/calendar-eww push 0";
      };
      settingsPopup = mkHoverPopup {
        name = "settings";
        window = "settings-popup";
        var = "settings_open";
      };

      # Title click: raise the player's window and close the panel at once (a click
      # is a definite intent, so no debounce).
      mprisJump = pkgs.writeShellScriptBin "eww-mpris-jump" ''
        rm -f "${mprisPopup.flag}"
        ${eww} update mpris_open=false
        ${eww} close mpris-popup 2>/dev/null || true
        exec ${mpris}/bin/mpris-eww focus "$1"
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
        mprisPopup.open
        mprisPopup.keep
        mprisPopup.close
        mprisJump
        calPopup.open
        calPopup.keep
        calPopup.close
        settingsPopup.open
        settingsPopup.keep
        settingsPopup.close
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
        mprisOpen = "${mprisPopup.open}/bin/eww-mpris-open";
        mprisKeep = "${mprisPopup.keep}/bin/eww-mpris-keep";
        mprisClose = "${mprisPopup.close}/bin/eww-mpris-close";
        mprisJump = "${mprisJump}/bin/eww-mpris-jump";
        calOpen = "${calPopup.open}/bin/eww-cal-open";
        calKeep = "${calPopup.keep}/bin/eww-cal-keep";
        calClose = "${calPopup.close}/bin/eww-cal-close";
        settingsOpen = "${settingsPopup.open}/bin/eww-settings-open";
        settingsKeep = "${settingsPopup.keep}/bin/eww-settings-keep";
        settingsClose = "${settingsPopup.close}/bin/eww-settings-close";
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
