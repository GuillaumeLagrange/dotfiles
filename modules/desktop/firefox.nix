{ pkgs, ... }:
{
  _class = "homeManager";

  programs.firefox = {
    enable = true;
    package = pkgs.unstable.firefox;
    # The pre-26.05 default: keeps the existing profile where it is.
    configPath = ".mozilla/firefox";
  };
}
