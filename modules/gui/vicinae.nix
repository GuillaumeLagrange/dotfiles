{
  flake.modules.homeManager.vicinae =
    { pkgs, config, ... }:
    {
      programs.vicinae = {
        enable = true;
        systemd = {
          enable = true;
          autoStart = true;
        };
      };

      # Native-messaging manifest bridging the Firefox extension to the daemon.
      # It must resolve to a read-only file: vicinae rewrites the manifest on
      # startup otherwise, and the extension docs recommend pinning it so that
      # rewrite is suppressed. A plain store symlink is read-only, which is
      # exactly what we want here (an out-of-store symlink would be writable
      # and defeat the point).
      home.file.".mozilla/native-messaging-hosts/com.vicinae.vicinae.json".text =
        builtins.toJSON {
          name = "com.vicinae.vicinae";
          description = "Vicinae browser link";
          type = "stdio";
          path = "${config.programs.vicinae.package}/libexec/vicinae/vicinae-browser-link";
          allowed_extensions = [ "firefox@vicinae.com" ];
        };
    };
}
