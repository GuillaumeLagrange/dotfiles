# Noctalia Greeter under greetd: its own wlroots compositor shows the login box on every
# screen, each at its preferred mode and scale, and opens on my password with the last
# session picked. nixos-unstable's module needs options stable lacks, so this is its
# setup, minus the polkit rule for Noctalia's appearance sync, which I do not run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  package = pkgs.unstable.noctalia-greeter;
  c = config.home-manager.users.guillaume.lib.stylix.colors.withHashtag;
  wallpaper = config.greeter.wallpaper;
  user = config.services.greetd.settings.default_session.user;

  settings = (pkgs.formats.toml { }).generate "greeter.toml" {
    user.default = "guillaume";
    keyboard = {
      layout = "qwerty-fr";
      options = "ctrl:nocaps";
    };
    cursor = {
      theme = "Adwaita";
      size = 24;
      path = "${pkgs.adwaita-icon-theme}/share/icons";
    };
    appearance = {
      scheme = "Synced";
      theme_mode = "dark";
      font_family = "Inter";
      hide_logo = true;
      scheme_selector_position = "hidden";
      # The bar's colours: stylix's gruvbox, orange accent.
      palette = {
        primary = c.base09;
        on_primary = c.base00;
        secondary = c.base0D;
        on_secondary = c.base00;
        tertiary = c.base0B;
        on_tertiary = c.base00;
        error = c.base08;
        on_error = c.base00;
        surface = c.base00;
        on_surface = c.base06;
        surface_variant = c.base01;
        on_surface_variant = c.base04;
        outline = c.base02;
        shadow = "#000000";
        hover = c.base09;
        on_hover = c.base00;
      };
    }
    // lib.optionalAttrs (wallpaper != null) {
      wallpaper = {
        path = "${wallpaper}";
        fill_mode = "crop";
      };
    };
  };
in
{
  _class = "nixos";

  services.greetd = {
    enable = true;
    # qwerty-fr is not in the stock xkeyboard-config.
    settings.default_session.command = "${pkgs.coreutils}/bin/env XKB_CONFIG_ROOT=${config.services.xserver.xkb.dir} ${lib.getExe' package "noctalia-greeter-session"}";
  };

  # Type=idle holds the greeter back up to 5 s while other boot jobs run.
  systemd.services.greetd.serviceConfig.Type = lib.mkForce "simple";

  # The session picker remembers the last one in sync.toml, next to greeter.toml.
  systemd.tmpfiles.settings."10-noctalia-greeter" = {
    "/var/lib/noctalia-greeter".d = {
      inherit user;
      group = "greeter";
      mode = "0750";
    };
    "/var/lib/noctalia-greeter/greeter.toml"."L+".argument = "${settings}";
  };

  # Users' names and avatars.
  services.accounts-daemon.enable = true;

  fonts.packages = [ pkgs.inter ];

  # The password unlocks the keyring; a fingerprint cannot, and pam_fprintd would
  # wait for a finger before the password prompt.
  security.pam.services.greetd.fprintAuth = false;
}
