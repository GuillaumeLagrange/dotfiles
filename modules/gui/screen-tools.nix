{
  flake.modules.homeManager.screen-tools =
    { pkgs, lib, ... }:
    let
      # Push recording state into the eww bar (replaces the old SIGRTMIN+8
      # waybar signal). Explicit state at each call site because the start push
      # happens before wl-screenrec is up, so pgrep would still read "off".
      barRecording = state: text:
        "${pkgs.eww}/bin/eww update 'screenrecord={\"recording\":${state},\"text\":\"${text}\"}' 2>/dev/null || true";
      barRecOn = barRecording "true" "⏺ REC";
      barRecOff = barRecording "false" "";

      screenshotTool = pkgs.writeShellScriptBin "screenshot_tool" ''
        ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.swappy}/bin/swappy -f -
      '';

      screenrecordStop = ''
        ${pkgs.killall}/bin/killall -s SIGINT wl-screenrec 2>/dev/null && \
          ${pkgs.libnotify}/bin/notify-send -t 2000 -a "Screen Recording" "Screenrecord stopped"
        ${barRecOff}
      '';

      screenrecordStart = extraArgs: ''
        file=/tmp/"screenrec-$(date +%s)".mp4
        echo "$file" > /tmp/screenrec-path

        ${pkgs.libnotify}/bin/notify-send -t 2000 -a "Screen Recording" "Screenrecord starting..."
        ${barRecOn}
        ${pkgs.wl-screenrec}/bin/wl-screenrec ${extraArgs} -f "$file"
        ${pkgs.wl-clipboard}/bin/wl-copy "file:/$file" -t text/uri-list
        ${barRecOff}
      '';

      screenrecordScreenTool = pkgs.writeShellScriptBin "screenrecord_screen" ''
        if ${pkgs.procps}/bin/pgrep -x wl-screenrec > /dev/null; then
          ${screenrecordStop}
        else
          ${screenrecordStart ""}
        fi
      '';

      screenrecordRegionTool = pkgs.writeShellScriptBin "screenrecord_region" ''
        if ${pkgs.procps}/bin/pgrep -x wl-screenrec > /dev/null; then
          ${screenrecordStop}
        else
          GEOMETRY=$(${pkgs.slurp}/bin/slurp -b '#00000090') || exit 1
          ${screenrecordStart ''-g "$GEOMETRY"''}
        fi
      '';

      screenrecordStopTool = pkgs.writeShellScriptBin "screenrecord_stop" ''
        ${screenrecordStop}
      '';
    in
    {
      options = {
        screenshotTool = lib.mkOption {
          type = lib.types.str;
          default = "${screenshotTool}/bin/screenshot_tool";
        };

        screenrecordScreenTool = lib.mkOption {
          type = lib.types.str;
          default = "${screenrecordScreenTool}/bin/screenrecord_screen";
        };

        screenrecordRegionTool = lib.mkOption {
          type = lib.types.str;
          default = "${screenrecordRegionTool}/bin/screenrecord_region";
        };

        screenrecordStopTool = lib.mkOption {
          type = lib.types.str;
          default = "${screenrecordStopTool}/bin/screenrecord_stop";
        };
      };
    };
}
