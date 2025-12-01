{
  lib,
  config,
  ...
}:
{
  options = {
    vicinae.enable = lib.mkEnableOption "Vicinae browser";
  };

  config = lib.mkIf config.vicinae.enable {
    programs.vicinae = {
      enable = true;
      systemd = {
        enable = true;
        autoStart = true;
      };
      # Configuration done within the app for now
    };
  };
}
