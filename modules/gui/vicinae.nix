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
      # settings = {
      #   faviconService = "twenty";
      #   keybinding = "vim";
      #   theme.name = "vicinae-dark";
      #   window = {
      #     csd = true;
      #     opacity = 0.95;
      #     rounding = 10;
      #   };
      # };
    };
  };
}
