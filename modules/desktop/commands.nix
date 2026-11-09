# Commands the desktop's parts share. Not a module: parts take it with
#   commands = import ./commands.nix { inherit pkgs lib config; };
{
  pkgs,
  lib,
  config,
}:
let
  quickshell = pkgs.unstable.quickshell;

  barRecording = state: text: ''
    ${quickshell}/bin/qs -c bar ipc call recorder set ${state} ${lib.escapeShellArg text} 2>/dev/null || true
  '';
  barRecOn = barRecording "true" "${builtins.fromJSON ''"\uf111"''} REC";
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

  lockWallpaper = "${config.xdg.cacheHome}/hyprlock-wallpaper";

  lockScript = pkgs.writeShellScriptBin "lock.sh" ''
    ${pkgs.procps}/bin/pkill -u "$USER" -USR1 dunst

    ${pkgs.playerctl}/bin/playerctl -i spotify pause

    ${pkgs.coreutils}/bin/mkdir -p "${config.xdg.cacheHome}"
    ${pkgs.coreutils}/bin/ln -sfn "$(${pkgs.findutils}/bin/find ${./wallpapers} -type f | ${pkgs.coreutils}/bin/shuf -n 1)" "${lockWallpaper}"

    ${pkgs.hyprlock}/bin/hyprlock

    ${pkgs.procps}/bin/pkill -u "$USER" -USR2 dunst
  '';
in
{
  inherit lockScript lockWallpaper;
  lock = "${lockScript}/bin/lock.sh";

  terminal = lib.getExe config.programs.kitty.package;

  quickshellIpc = "${quickshell}/bin/qs -c bar ipc call";

  screenshot = "${screenshotTool}/bin/screenshot_tool";
  screenrecordScreen = "${screenrecordScreenTool}/bin/screenrecord_screen";
  screenrecordRegion = "${screenrecordRegionTool}/bin/screenrecord_region";
}
