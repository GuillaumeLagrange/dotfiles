{ inputs, ... }:
{
  flake.modules.homeManager.quickshell =
    { pkgs, config, lib, ... }:
    let
      quickshell = inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;

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

      # The one compiled component, shared with the eww bar: a niri IPC tap that
      # keeps the layout model in memory and prints a snapshot line only when it
      # changes. See ../niri-state/AGENTS.md.
      niriState = pkgs.callPackage ../niri-state/_package.nix { };

      claudeUsage = pkgs.writeShellScriptBin "claude-usage-qs" ''
        export PATH="${lib.makeBinPath [ pkgs.jq ]}:$PATH"
        exec ${pkgs.bash}/bin/bash ${../bar-scripts/claude-usage.sh} "$@"
      '';

      # Pairing needs an agent to answer BlueZ's prompts, and QML cannot export
      # one. See bt-pair.py.
      btPair = pkgs.writers.writePython3Bin "bt-pair" {
        libraries = [ pkgs.python3Packages.dbus-fast ];
        flakeIgnore = [ "E501" "F722" "F821" ];
      } (builtins.readFile ./bt-pair.py);

      # Qt's `TextMetrics.tightBoundingRect` clamps a glyph's ink box to the
      # baseline, so a glyph drawn entirely above it (the tray's three dots)
      # reports a box that is too tall and centres too high. The real outline
      # bounds come from the font, in em fractions so they hold at any size, for
      # the ~2k glyphs where Qt is wrong; every other glyph keeps Qt's box.
      inkTable = pkgs.runCommand "glyph-ink.json" { nativeBuildInputs = [ pkgs.python3Packages.fonttools ]; } ''
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
        chevronUp = glyph "F0143";
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
        down = glyph "F0045";
        up = glyph "F005D";
        bluetooth = glyph "F00AF";
        bluetoothOff = glyph "F00B2";
        bluetoothOn = glyph "F00B1";
        headphones = glyph "F02CB";
        speaker = glyph "F04C3";
        mouse = glyph "F037D";
        keyboard = glyph "F030C";
        phone = glyph "F011C";
        watch = glyph "F0589";
        gamepad = glyph "F0297";
        device = glyph "F0625";
        idle = glyph "F06E";
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
        larrow = builtins.fromJSON ''"\u2039"'';
        rarrow = builtins.fromJSON ''"\u203a"'';
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
            readonly property string claudeUsage: "${claudeUsage}/bin/claude-usage-qs"
            readonly property string btPair: "${btPair}/bin/bt-pair"
            readonly property string screenrecord: ${builtins.toJSON config.screenrecordScreenTool}
            readonly property string systemdInhibit: "${pkgs.systemd}/bin/systemd-inhibit"
            readonly property string sleepBin: "${pkgs.coreutils}/bin/sleep"
            readonly property string df: "${pkgs.coreutils}/bin/df"
            // VPN profiles are invisible to Quickshell.Networking, which models
            // wifi and wired devices only, so WireGuard goes through nmcli.
            readonly property string nmcli: "${pkgs.networkmanager}/bin/nmcli"

            readonly property var glyph: ${builtins.toJSON glyphs}

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
    in
    {
      options.quickshellIpc = lib.mkOption {
        type = lib.types.str;
        default = "${quickshell}/bin/qs -c bar ipc call";
        description = "Command prefix for calls into the running bar's IpcHandlers.";
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
      };
    };
}
