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
        pkgs.wireplumber
        pkgs.pulseaudio # pactl, for the pulseaudio deflisten
        pkgs.mako
        pkgs.power-profiles-daemon
        pkgs.glib.bin # gdbus, for the power-profile watch
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

      # Decoded here rather than with `printf '\uXXXX'` in the script: the unit
      # runs under the POSIX locale, where bash's printf emits the literal escape
      # text for astral-plane codepoints (\U) instead of the character.
      settingsIcons = {
        gear = builtins.fromJSON ''"\udb81\udc93"''; # md-cog U+F0493
        idle = builtins.fromJSON ''"\uf06e"''; # nf-fa-eye
        dnd = builtins.fromJSON ''"\uf1f6"''; # nf-fa-bell_slash
      };

      # settings.sh reaches idle-inhibit by name and pushes state via `eww update`.
      settings = pkgs.writeShellScriptBin "settings-eww" ''
        export PATH="${runtimePath}:${idleInhibit}/bin:${pkgs.eww}/bin:$PATH"
        export IDLE_INHIBIT_BIN="${idleInhibit}/bin/idle-inhibit"
        export SETTINGS_ICON_GEAR=${pkgs.lib.escapeShellArg settingsIcons.gear}
        export SETTINGS_ICON_IDLE=${pkgs.lib.escapeShellArg settingsIcons.idle}
        export SETTINGS_ICON_DND=${pkgs.lib.escapeShellArg settingsIcons.dnd}
        exec ${pkgs.bash}/bin/bash ${./scripts/settings.sh} "$@"
      '';

      claudeUsage = pkgs.writeShellScriptBin "claude-usage-eww" ''
        export PATH="${pkgs.lib.makeBinPath [ pkgs.jq pkgs.curl pkgs.coreutils pkgs.gnused ]}:$PATH"
        export AI_USAGE_COMMON="${../bar-scripts/ai-usage-common.sh}"
        export AI_USAGE_RETRY_LIMIT="5"
        exec ${pkgs.bash}/bin/bash ${../bar-scripts/claude-usage.sh} "$@"
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
      # CPU/memory/disk/battery in one long-lived deflisten: eww runs defpoll
      # commands through a blocking wait on its script-var runtime, so each poll
      # parks a worker for the script's whole duration, while listen-vars are
      # read asynchronously. Reading procfs/sysfs from a resident process also
      # avoids both the per-tick fork tree and the sample-window sleep a
      # stateless CPU script needs. No PATH beyond python: it shells out to
      # nothing.
      metrics = pkgs.writeShellScriptBin "metrics-eww" ''
        exec ${pkgs.python3}/bin/python3 ${./scripts/metrics.py} "$@"
      '';
      pulseaudio = mkScript "pulseaudio-eww" ./scripts/pulseaudio.sh;
      # calendar's `push` mode calls `eww update`, so it needs eww on PATH.
      # Python rather than shell because the grid is 42 cells x 3 fields: as
      # `date` forks that was ~260 per two-pane push (~1.1s) on the popup's
      # hover path, versus a few ms of datetime arithmetic.
      calendar = pkgs.writeShellScriptBin "calendar-eww" ''
        export EWW_BIN="${pkgs.eww}/bin/eww"
        exec ${pkgs.python3}/bin/python3 ${./scripts/calendar.py} "$@"
      '';

      eww = "${pkgs.eww}/bin/eww";

      # Hover dwell before a popup opens, and the debounce before it closes, in
      # seconds (`sleep` syntax, so fractions are fine). Tweak here; each popup
      # can override via mkHoverPopup's `openDelay` / `closeDelay`.
      hoverOpenDelay = "0.5";
      hoverCloseDelay = "0.30";

      # Hover-driven popups (media panel, calendar, settings). Three scripts per
      # popup, because GTK fires hover/hover-lost as the pointer crosses a
      # window's *child* widgets:
      #   open  — trigger hover: dwell, then mark open and show the window (runs
      #           detached; an onclick/onhover that calls `eww` back would block
      #           the single-threaded daemon and hit its ~1s handler kill).
      #   keep  — popup hover: only refresh the flag's mtime. No `eww` call, so
      #           the churn from crossing child widgets can't re-open the window
      #           (re-opening on every event makes it flicker).
      #   close — popup/trigger hover-lost: debounce, then hide. A re-hover during
      #           the debounce (from open or keep) pushes the flag's mtime past the
      #           closing marker, which aborts the close.
      # The two markers also carry the open dwell: `open` bails when the closing
      # marker outlives its own flag touch, i.e. the pointer left mid-dwell. The
      # closing marker therefore outlives a close and is only ever re-touched.
      # `seed` runs before the window is shown, for popups whose content is pushed
      # rather than polled. `postClose` runs after it's hidden.
      mkHoverPopup =
        {
          name,
          window,
          var,
          seed ? "",
          postClose ? "",
          openDelay ? hoverOpenDelay,
          closeDelay ? hoverCloseDelay,
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
            sleep ${openDelay}
            if [ "${closing}" -nt "${flag}" ]; then exit 0; fi
            ${seed}
            ${eww} update ${var}=true
            ${eww} open ${window} --screen "$m" --arg monitor="$m" 2>/dev/null || true
          '';
          keep = pkgs.writeShellScriptBin "eww-${name}-keep" ''
            touch "${flag}"
          '';
          close = pkgs.writeShellScriptBin "eww-${name}-close" ''
            touch "${closing}"
            sleep ${closeDelay}
            if [ "${flag}" -nt "${closing}" ]; then exit 0; fi
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

      # Transport clicks (play-pause / next / previous) are a single D-Bus method
      # call, so they bypass mpris.py: starting a Python interpreter and importing
      # the GObject typelibs costs ~200ms before the call is even sent, which reads
      # as a dropped click and invites a second one that undoes the first.
      # dbus-send does the same call in ~0ms. Takes the full bus name (the state
      # JSON carries it as `bus`), so no lookup is needed either.
      # --print-reply is load-bearing, not debug output: without it dbus-send sends
      # the call with NO_REPLY_EXPECTED and exits, and Spotify silently discards
      # those — the call is delivered, returns 0, and nothing happens. Waiting for
      # the reply still costs ~0ms.
      mprisCtl = pkgs.writeShellScriptBin "eww-mpris-ctl" ''
        exec ${pkgs.dbus}/bin/dbus-send --session --print-reply=literal \
          --dest="$1" /org/mpris/MediaPlayer2 \
          "org.mpris.MediaPlayer2.Player.$2" >/dev/null 2>&1
      '';

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
        metrics
        pulseaudio
        calendar
        mprisPopup.open
        mprisPopup.keep
        mprisPopup.close
        mprisCtl
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
      ];

      # Absolute paths to every command the yuck / bar-launch invoke, so nothing
      # depends on PATH resolution.
      bins = {
        niriState = "${niriState}/bin/niri-state";
        mpris = "${mpris}/bin/mpris-eww";
        metrics = "${metrics}/bin/metrics-eww";
        pulseaudio = "${pulseaudio}/bin/pulseaudio-eww";
        settings = "${settings}/bin/settings-eww";
        claudeUsage = "${claudeUsage}/bin/claude-usage-eww";
        calendar = "${calendar}/bin/calendar-eww";
        mprisOpen = "${mprisPopup.open}/bin/eww-mpris-open";
        mprisKeep = "${mprisPopup.keep}/bin/eww-mpris-keep";
        mprisClose = "${mprisPopup.close}/bin/eww-mpris-close";
        mprisCtl = "${mprisCtl}/bin/eww-mpris-ctl";
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
        # get stripped by some editors). Chevrons are U+2039/U+203A; the
        # transport glyphs are nerd-font.
        larrow = builtins.fromJSON ''"\u2039"'';
        rarrow = builtins.fromJSON ''"\u203a"'';
        playGlyph   = builtins.fromJSON ''"\uf04b"'';   # nf-fa-play
        pauseGlyph  = builtins.fromJSON ''"\uf04c"'';   # nf-fa-pause
        prevGlyph   = builtins.fromJSON ''"\uf048"'';   # nf-fa-step_backward
        nextGlyph   = builtins.fromJSON ''"\uf051"'';   # nf-fa-step_forward
        # Settings-panel row/segment icons (same md-* set settings.sh emits).
        idleGlyph    = builtins.fromJSON ''"\uf06e"'';       # nf-fa-eye
        dndGlyph     = builtins.fromJSON ''"\uf1f6"'';       # nf-fa-bell_slash
        # Above-BMP md-* codepoints: JSON has no \UXXXXXXXX escape, so these are
        # written as UTF-16 surrogate pairs, which fromJSON does decode.
        saverGlyph    = builtins.fromJSON ''"\udb83\udf86"'';  # md-gauge-low U+F0F86
        balancedGlyph = builtins.fromJSON ''"\udb83\udf85"'';  # md-gauge U+F0F85
        perfGlyph     = builtins.fromJSON ''"\udb81\udcc5"'';  # md-speedometer U+F04C5
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
      # starts deactivated on every (re)start.
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
