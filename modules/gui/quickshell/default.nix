{ ... }:
{
  flake.modules.homeManager.quickshell =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      quickshell = pkgs.unstable.quickshell;

      # Glyphs are decoded from JSON escapes here so the QML sources stay ASCII:
      # a literal nerd-font glyph gets stripped by some edits, leaving a
      # zero-width icon. JSON has no \UXXXXXXXX escape, so astral-plane
      # codepoints go in as UTF-16 surrogate pairs.
      hex4 = n: lib.fixedWidthString 4 "0" (lib.toHexString n);
      glyph =
        hexcp:
        let
          cp = lib.fromHexString hexcp;
          c = cp - 65536;
        in
        if cp < 65536 then
          builtins.fromJSON ''"\u${hex4 cp}"''
        else
          builtins.fromJSON ''"\u${hex4 (55296 + c / 1024)}\u${hex4 (56320 + lib.mod c 1024)}"'';

      # The one compiled component: a niri IPC tap that
      # keeps the layout model in memory and prints a snapshot line only when it
      # changes. See ../niri-state/AGENTS.md.
      niriState = pkgs.callPackage ../niri-state/_package.nix { };

      # A click on a workspace cell goes where Mod+N goes. See ../niri/workspaces.py.
      niriWorkspaces = pkgs.callPackage ../niri/_workspaces.nix { };

      # The control centre's display setups. See ../niri/displays.py.
      niriDisplays = pkgs.callPackage ../niri/_displays.nix { };

      claudeUsage = pkgs.writeShellScriptBin "claude-usage-qs" ''
        export PATH="${lib.makeBinPath [ pkgs.jq ]}:$PATH"
        exec ${pkgs.bash}/bin/bash ${../bar-scripts/claude-usage.sh} "$@"
      '';

      # The derivation zellij.nix installs: the bar reads the picker's data through it.
      reviews = pkgs.callPackage ../../headless/reviews/_package.nix { };

      # Pairing needs an agent to answer BlueZ's prompts, and QML cannot export
      # one. See bt-pair.py.
      btPair = pkgs.writers.writePython3Bin "bt-pair" {
        libraries = [ pkgs.python3Packages.dbus-fast ];
        flakeIgnore = [
          "E501"
          "F722"
          "F821"
        ];
      } (builtins.readFile ./bt-pair.py);

      # Qt's `TextMetrics.tightBoundingRect` clamps a glyph's ink box to the
      # baseline, so a glyph drawn entirely above it (the tray's three dots)
      # reports a box that is too tall and centres too high. The real outline
      # bounds come from the font, in em fractions so they hold at any size, for
      # the ~2k glyphs where Qt is wrong; every other glyph keeps Qt's box.
      inkTable =
        pkgs.runCommand "glyph-ink.json" { nativeBuildInputs = [ pkgs.python3Packages.fonttools ]; }
          ''
            python3 - <<'EOF' > $out
            import json
            from fontTools.ttLib import TTFont
            from fontTools.pens.boundsPen import BoundsPen

            font = TTFont("${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack/HackNerdFontPropo-Regular.ttf")
            upem = font["head"].unitsPerEm
            glyphs = font.getGlyphSet()
            ink = {}
            for cp, name in font.getBestCmap().items():
                pen = BoundsPen(glyphs)
                glyphs[name].draw(pen)
                if not pen.bounds:
                    continue
                _, y0, _, y1 = pen.bounds
                if y0 > 0 or y1 < 0:
                    ink["%x" % cp] = [round(y0 / upem, 4), round(y1 / upem, 4)]
            print(json.dumps(ink, separators=(",", ":")))
            EOF
          '';

      # nf-md-* codepoints live above the BMP; `glyph` handles the surrogate pair.
      glyphs = {
        calendar = glyph "F00F0";
        clockAlt = glyph "F0954";
        disk = glyph "F02CA";
        cpu = glyph "F035B";
        ram = glyph "F061A";
        claude = glyph "F0721";
        pullRequest = glyph "F04C2";
        refresh = glyph "F0450";
        terminal = glyph "F018D";
        stack = glyph "F0328";
        gear = glyph "F0493";
        # Sliders, not a gear: the pill opens a dashboard of toggles.
        controls = glyph "F1542";
        # FontAwesome rather than the md- speakers: at 13px the md- bodies are
        # hairlines and their "low" state is a bare triangle with no waves, so
        # it reads as a broken glyph rather than a quiet speaker.
        volLow = glyph "F027";
        volHigh = glyph "F028";
        volMuted = glyph "EEE8";
        mic = glyph "F036C";
        micMuted = glyph "F036D";
        batHigh = glyph "F12A3";
        batMedium = glyph "F12A2";
        batLow = glyph "F12A1";
        batCharging = glyph "F0084";
        wifi1 = glyph "F091F";
        wifi2 = glyph "F0922";
        wifi3 = glyph "F0925";
        wifi4 = glyph "F0928";
        wifiNone = glyph "F092F";
        wifiOff = glyph "F092D";
        ethernet = glyph "F0200";
        ethernetOff = glyph "F0202";
        vpn = glyph "F0582";
        lock = glyph "F033E";
        fingerprint = glyph "F0237";
        search = glyph "F0349";
        down = glyph "F0045";
        up = glyph "F005D";
        bluetooth = glyph "F00AF";
        bluetoothOff = glyph "F00B2";
        bluetoothOn = glyph "F00B1";
        headphones = glyph "F02CB";
        headphonesBt = glyph "F0970";
        headset = glyph "F02CE";
        earbuds = glyph "F184F";
        speaker = glyph "F04C3";
        speakerBt = glyph "F09A2";
        mouse = glyph "F037D";
        keyboard = glyph "F030C";
        phone = glyph "F011C";
        watch = glyph "F0589";
        gamepad = glyph "F0297";
        device = glyph "F0625";
        idle = glyph "F06E";
        caffeine = glyph "F0176";
        bell = glyph "F009A";
        dnd = glyph "F1F6";
        saver = glyph "F0F86";
        balanced = glyph "F0F85";
        performance = glyph "F04C5";
        play = glyph "F04B";
        pause = glyph "F04C";
        prev = glyph "F048";
        next = glyph "F051";
        spotify = glyph "F1BC";
        firefox = glyph "F269";
        chrome = glyph "F268";
        movie = glyph "F0381";
        music = glyph "F001";
        check = glyph "F00C";
        dot = glyph "F111";
        submenu = glyph "F0DA";
        more = glyph "F01D8";
        pin = glyph "F0403";
        apps = glyph "F003B";
        plus = glyph "F0415";
        close = glyph "F0156";
        monitor = glyph "F0379";
        larrow = builtins.fromJSON ''"\u2039"'';
        rarrow = builtins.fromJSON ''"\u203a"'';
      };

      # Monochrome marks for the strip's columns, keyed by lowercased app_id.
      # Anything missing falls back to a greyscale of the app's own icon.
      appGlyphs = {
        firefox = glyph "F0239";
        chromium-browser = glyph "F02AF";
        kitty = glyph "F018D";
        zellij-session = glyph "F018D";
        omp-panel = glyph "F018D";
        "com.mitchellh.ghostty" = glyph "F02A0";
        slack = glyph "F04B1";
        discord = glyph "F066F";
        spotify = glyph "F04C7";
        "org.telegram.desktop" = glyph "F2C6";
        signal = glyph "F0FCD";
        "md.obsidian.obsidian" = glyph "F01C8";
        "org.gnome.nautilus" = glyph "F024B";
        vlc = glyph "F057C";
        calibre-gui = glyph "F14F7";
        libreoffice-writer = glyph "F37C";
        libreoffice-calc = glyph "F378";
        libreoffice-impress = glyph "F37A";
        libreoffice-draw = glyph "F379";
        libreoffice-startcenter = glyph "F376";
        dbeaver = glyph "F01BC";
        "org.pulseaudio.pavucontrol" = glyph "F066A";
        "proton.vpn.app.gtk" = glyph "F0582";
        proton-pass = glyph "F0BC4";
        "com.yubico.yubioath" = glyph "F030B";
        "io.gitlab.idevecore.pomodoro" = glyph "F13AB";
        "io.github.transmissionremotegtk" = glyph "F0347";
        feh = glyph "F02E9";
        "network.cycles.wdisplays" = glyph "F0379";
      };

      configQml = pkgs.writeText "Config.qml" ''
        pragma Singleton
        // Generated by modules/gui/quickshell/default.nix. Absolute store paths and
        // pre-decoded glyphs, so no QML source depends on PATH or carries a
        // private-use character.
        import Quickshell

        Singleton {
            readonly property string niriState: "${niriState}/bin/niri-state"
            readonly property string niri: "${pkgs.niri}/bin/niri"
            readonly property string niriWorkspaces: "${niriWorkspaces}/bin/niri-workspaces"
            readonly property string niriDisplays: "${niriDisplays}/bin/niri-displays"
            // Arranges the monitors a display setup is saved from.
            readonly property var wdisplays: ["${pkgs.niri}/bin/niri", "msg", "action", "spawn", "--", "${pkgs.wdisplays}/bin/wdisplays"]
            readonly property string claudeUsage: "${claudeUsage}/bin/claude-usage-qs"
            readonly property string btPair: "${btPair}/bin/bt-pair"
            readonly property string screenrecord: ${builtins.toJSON config.screenrecordScreenTool}
            // Mod+Shift+\, spawned through niri so it runs in the same environment as the bind.
            readonly property var review: ${
              builtins.toJSON (
                [
                  "${pkgs.niri}/bin/niri"
                  "msg"
                  "action"
                  "spawn"
                  "--"
                ]
                ++ lib.splitString " " config.term
                ++ [
                  "--class"
                  "zellij-session"
                  "-e"
                  "zsh"
                  "-i"
                  "-c"
                  "review"
                ]
              )
            }
            // A PR's URL is appended: no picker, so no terminal; `review` opens or focuses the view.
            readonly property var reviewPr: ["${pkgs.niri}/bin/niri", "msg", "action", "spawn", "--", "review", "--pr"]
            // One of my PRs: its URL and branch are appended; `review` opens the session holding the branch.
            readonly property var reviewMine: ["${pkgs.niri}/bin/niri", "msg", "action", "spawn", "--", "review", "--mine"]
            // A URL is appended; through niri so the browser gets the session's environment.
            readonly property var openUrl: ["${pkgs.niri}/bin/niri", "msg", "action", "spawn", "--", "${pkgs.xdg-utils}/bin/xdg-open"]
            // An app from the start menu: its command is appended. Through niri, like the
            // bindings, so it gets the session's environment and not the bar's.
            readonly property var launch: ["${pkgs.niri}/bin/niri", "msg", "action", "spawn", "--"]
            // Prefixes an app that asks for a terminal, then one with a working directory.
            readonly property var termExec: ${builtins.toJSON config.termExec}
            readonly property var chdir: ["${pkgs.coreutils}/bin/env", "-C"]
            // The pill's data (`--json`) and its refresh, from the picker's own binary.
            readonly property string reviews: "${lib.getExe reviews}"
            readonly property bool reviewsEnabled: ${lib.boolToString config.work.enable}
            readonly property string systemdInhibit: "${pkgs.systemd}/bin/systemd-inhibit"
            readonly property string sleepBin: "${pkgs.coreutils}/bin/sleep"
            readonly property string df: "${pkgs.coreutils}/bin/df"
            // VPN profiles are invisible to Quickshell.Networking, which models
            // wifi and wired devices only, so WireGuard goes through nmcli.
            readonly property string nmcli: "${pkgs.networkmanager}/bin/nmcli"
            // The volume keys' feedback sound (audio.nix), tagged as an event
            // so Audio.streams does not list it.
            readonly property var volumeChime: ["${pkgs.pulseaudio}/bin/paplay", "--property=media.role=event", "${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga"]

            readonly property var glyph: ${builtins.toJSON glyphs}
            // The glyphs a bluetooth device's icon can be set to from its panel row.
            readonly property var btDeviceGlyphs: ["headphones", "headphonesBt", "headset", "earbuds", "speaker", "speakerBt", "mouse", "keyboard", "phone", "watch", "gamepad", "device", "bluetooth"]
            readonly property var appGlyph: ${builtins.toJSON appGlyphs}

            // Outline bounds, in em fractions, for the glyphs Qt measures wrong;
            // keyed by codepoint in lowercase hex. See `inkTable` above.
            readonly property var glyphInk: @glyphInk@
        }
      '';

      shellDir = pkgs.runCommandLocal "quickshell-bar" { } ''
        cp -r ${./qml} $out
        chmod -R u+w $out
        cp ${configQml} $out/Config.qml
        chmod u+w $out/Config.qml
        substituteInPlace $out/Config.qml --replace-fail '@glyphInk@' "$(cat ${inkTable})"
      '';

      # What tests/ runs the bar against: niri on its headless backend, the
      # input it injects, niri-workspaces and this shell. See "Tests" in AGENTS.md.
      testEnv = pkgs.symlinkJoin {
        name = "quickshell-test-env";
        paths = [
          (pkgs.niri.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./tests/niri-headless.patch ];
            doCheck = false;
          }))
          quickshell
          pkgs.wtype
          pkgs.wlrctl
          pkgs.dbus
          niriWorkspaces
          niriDisplays
        ];
        postBuild = "ln -s ${shellDir} $out/shell";
      };
    in
    {
      options.quickshellIpc = lib.mkOption {
        type = lib.types.str;
        default = "${quickshell}/bin/qs -c bar ipc call";
        description = "Command prefix for calls into the running bar's IpcHandlers.";
      };

      options.quickshellTestEnv = lib.mkOption {
        type = lib.types.package;
        default = testEnv;
        readOnly = true;
        description = "Headless niri, quickshell, input injectors and the shell, for tests/.";
      };

      config = {
        home.packages = [ quickshell ];

        xdg.configFile."quickshell/bar".source = shellDir;

        systemd.user.services.quickshell = {
          Unit = {
            Description = "quickshell bar";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            # The unit only names the quickshell package, and `-c bar` resolves the
            # shell through ~/.config at runtime, so editing QML left the unit text
            # identical and sd-switch restarted nothing. systemd ignores this key;
            # it is here so the shell's hash is part of the unit.
            X-Restart-Triggers = [ "${shellDir}" ];
          };
          Service = {
            ExecStart = "${quickshell}/bin/qs -c bar";
            Restart = "on-failure";
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };

        # The YubiKey pill's source (services/Yubikey.qml). Socket-activated, so
        # the bar connecting starts it. No libnotify: the pill is the notice.
        systemd.user.sockets.yubikey-touch-detector = {
          Unit.Description = "yubikey-touch-detector socket";
          Socket = {
            ListenStream = "%t/yubikey-touch-detector.socket";
            RemoveOnStop = true;
          };
          Install.WantedBy = [ "sockets.target" ];
        };
        systemd.user.services.yubikey-touch-detector = {
          Unit = {
            Description = "Detects when the YubiKey is waiting for a touch";
            Requires = [ "yubikey-touch-detector.socket" ];
          };
          Service = {
            # The patch reconnects to gpg-agent once a key was unplugged: the
            # old connection answers "Card removed" forever, which hid gpg touches.
            ExecStart = lib.getExe (
              pkgs.yubikey-touch-detector.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [ ./yubikey-touch-detector-reconnect.patch ];
              })
            );
            # gpg/gpgconf: the gpg detector runs `gpg --card-status`, the ssh one
            # finds gpg-agent's ssh socket through gpgconf.
            Environment = [
              "PATH=${lib.makeBinPath [ config.programs.gpg.package ]}"
              "YUBIKEY_TOUCH_DETECTOR_LIBNOTIFY=false"
            ];
          };
        };
      };
    };
}
