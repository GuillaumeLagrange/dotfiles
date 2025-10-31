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
    services.vicinae = {
      enable = true;
      autoStart = true;
      # Configuration done within the app for now
    };
  };
}
