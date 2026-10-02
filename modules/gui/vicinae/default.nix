{
  flake.modules.homeManager.vicinae =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      programs.vicinae = {
        enable = true;
        systemd = {
          enable = true;
          autoStart = true;
        };
      };

      # vicinae writes GUI changes in place to settings.json, so it links to the
      # repo copy. Nix-managed settings (stylix theme) go to nix.json, which
      # settings.json imports; vicinae never writes imported files.
      xdg.configFile."vicinae/settings.json".source = lib.mkForce (
        config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/modules/gui/vicinae/settings.json"
      );
      xdg.configFile."vicinae/nix.json".source =
        (pkgs.formats.json { }).generate "vicinae-settings"
          config.programs.vicinae.settings;

      # Native-messaging manifest bridging the Firefox extension to the daemon.
      # It must resolve to a read-only file: vicinae rewrites the manifest on
      # startup otherwise, and the extension docs recommend pinning it so that
      # rewrite is suppressed. A plain store symlink is read-only, which is
      # exactly what we want here (an out-of-store symlink would be writable
      # and defeat the point).
      home.file.".mozilla/native-messaging-hosts/com.vicinae.vicinae.json".text = builtins.toJSON {
        name = "com.vicinae.vicinae";
        description = "Vicinae browser link";
        type = "stdio";
        path = "${config.programs.vicinae.package}/libexec/vicinae/vicinae-browser-link";
        allowed_extensions = [ "firefox@vicinae.com" ];
      };
    };
}
