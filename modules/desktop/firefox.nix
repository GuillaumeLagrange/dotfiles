{ pkgs, lib, ... }:
{
  _class = "homeManager";

  options.firefox = {
    mainProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Profile Mod+W opens with `firefox -P`; unset, firefox's last used one.";
    };
    altProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Profile Mod+Shift+W opens with `firefox -P`; unset, it opens a new instance.";
    };
  };

  # `firefox -P NAME` only knows the old profile manager's profiles.ini, which does not list
  # profiles made by the new one (kept in "Profile Groups/"). To open one with -P, add it by hand
  # to ~/.config/mozilla/firefox/profiles.ini, Path being its folder in that directory:
  #   [Profile1]
  #   Name=Perso
  #   IsRelative=1
  #   Path=69bb9o00.default
  # The NAME needn't match the new manager's; `firefox -P Perso` then runs alongside the others.
  # Do not reuse the entry with a StoreID: firefox points it at whichever profile ran last.
  config.programs.firefox = {
    enable = true;
    package = pkgs.unstable.firefox;
    # The pre-26.05 default: keeps the existing profile where it is.
    configPath = ".mozilla/firefox";
  };
}
