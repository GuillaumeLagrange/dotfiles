# The daemon behind the bar's launcher panel (pkgs/launcher): its config and its user service.
# The panel is the bar's (quickshell/qml/popups/Launcher.qml); niri.nix binds the keys.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  home = config.home.homeDirectory;
  # pass-cli keeps its local key in the kernel keyring by default, which the greetd session is
  # denied (NoStorageAccess(AccessDenied)) and a reboot clears. gnome-keyring, unlocked at login,
  # keeps it. One wrapper, so the shell's pass-cli and the launcher's read the same key.
  passCli = pkgs.symlinkJoin {
    name = "pass-cli";
    paths = [ pkgs.unstable.proton-pass-cli ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = "wrapProgram $out/bin/pass-cli --set PROTON_PASS_LINUX_KEYRING dbus";
  };
  settings = {
    terminal = [ "xdg-terminal-exec" ];
    modes = {
      apps = null;
      windows = null;
      emoji = {
        emoji_test = "${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt";
        annotations = [
          "${pkgs.cldr-annotations}/share/unicode/cldr/common/annotations/en.xml"
          "${pkgs.cldr-annotations}/share/unicode/cldr/common/annotationsDerived/en.xml"
        ];
      };
      clipboard = {
        max_entries = 1000;
        max_age_days = 30;
        secret_clear_seconds = 30;
      };
      browser = {
        profiles_ini = [
          "${home}/.config/mozilla/firefox/profiles.ini"
          "${home}/.mozilla/firefox/profiles.ini"
        ];
        firefox = "${config.programs.firefox.finalPackage}/bin/firefox";
      };
      passwords = {
        proton.command = "${passCli}/bin/pass-cli";
        # The setgid wrapper the app's CLI integration checks for.
        onepassword = if config.work.enable then { command = "/run/wrappers/bin/op"; } else null;
      };
      sessions = null;
      power.systemctl = "${pkgs.systemd}/bin/systemctl";
      files = {
        roots = [ home ];
        exclude = [
          ".cache"
          ".local/share/Steam"
          ".local/share/containers"
          ".local/share/Trash"
          ".mozilla"
          ".config/mozilla"
        ];
        max = 300000;
      };
    }
    // lib.optionalAttrs config.work.enable {
      reviews.command = lib.getExe pkgs.reviews;
    };
  };
  configFile = (pkgs.formats.json { }).generate "launcher.json" settings;
in
{
  _class = "homeManager";

  # pass-cli login is a one-time step in a terminal.
  home.packages = [ passCli ];

  xdg.configFile."launcher/config.json".source = configFile;

  systemd.user.services.launcher = {
    Unit = {
      Description = "The bar launcher's daemon: sources, matching, clipboard history";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      X-Restart-Triggers = [ "${configFile}" ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.launcher} daemon";
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
