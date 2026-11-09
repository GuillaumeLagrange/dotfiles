{
  pkgs,
  config,
  lib,
  ...
}:
{
  _class = "homeManager";

  programs.vicinae = {
    enable = true;
    package = pkgs.unstable.vicinae;
    systemd = {
      enable = true;
      autoStart = true;
    };
  };

  # Linked to the repo copy, which vicinae writes in place; nix.json holds stylix's
  # settings and is imported by it.
  xdg.configFile."vicinae/settings.json".source = lib.mkForce (
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/modules/desktop/vicinae/settings.json"
  );
  xdg.configFile."vicinae/nix.json".source =
    (pkgs.formats.json { }).generate "vicinae-settings"
      config.programs.vicinae.settings;

  home.file.".mozilla/native-messaging-hosts/com.vicinae.vicinae.json".text = builtins.toJSON {
    name = "com.vicinae.vicinae";
    description = "Vicinae browser link";
    type = "stdio";
    path = "${config.programs.vicinae.package}/libexec/vicinae/vicinae-browser-link";
    allowed_extensions = [ "firefox@vicinae.com" ];
  };
}
