{ pkgs, ... }:
{
  _class = "homeManager";

  # `firefox -P NAME` only knows the old profile manager's profiles.ini, which does not list
  # profiles made by the new one (kept in "Profile Groups/"). To open one with -P, add it by hand
  # to ~/.config/mozilla/firefox/profiles.ini, Path being its folder in that directory:
  #   [Profile1]
  #   Name=Perso
  #   IsRelative=1
  #   Path=69bb9o00.default
  # The NAME needn't match the new manager's; `firefox -P Perso` then runs alongside the others.
  programs.firefox = {
    enable = true;
    package = pkgs.unstable.firefox;
    # The pre-26.05 default: keeps the existing profile where it is.
    configPath = ".mozilla/firefox";
  };
}
