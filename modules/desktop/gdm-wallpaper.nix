# A NixOS module putting `image` behind GDM's login box. Not imported by the group:
# hosts take it with `(import ../../modules/desktop/gdm-wallpaper.nix ./x.jpg)`.
# The login screen loads no extension, only gnome-shell's theme resource from its data
# dir. Rather than rebuild gnome-shell, the greeter alone gets GNOME_SHELL_DATADIR
# pointing at a copy of that dir whose theme has the image.
image:
{ config, pkgs, ... }:
let
  gresource = "${pkgs.glib.dev}/bin/gresource";
  dataDir = pkgs.runCommand "gnome-shell-gdm-data" { } ''
    src=${pkgs.gnome-shell}/share/gnome-shell
    mkdir -p $out theme
    ln -s $src/* $out/
    rm $out/gnome-shell-theme.gresource

    cd theme
    echo '<gresources><gresource prefix="/">' > theme.xml
    for f in $(${gresource} list $src/gnome-shell-theme.gresource) /org/gnome/shell/theme/gdm-wallpaper.jpg; do
      mkdir -p ".$(dirname "$f")"
      echo "<file>''${f#/}</file>" >> theme.xml
    done
    echo '</gresource></gresources>' >> theme.xml
    for f in $(${gresource} list $src/gnome-shell-theme.gresource); do
      ${gresource} extract $src/gnome-shell-theme.gresource "$f" > ".$f"
    done
    cp ${image} org/gnome/shell/theme/gdm-wallpaper.jpg

    # High contrast keeps its plain background.
    for css in org/gnome/shell/theme/gnome-shell-{dark,light}.css; do
      cat >> $css <<'EOF'
    #lockDialogGroup {
      background-image: url("resource:///org/gnome/shell/theme/gdm-wallpaper.jpg");
      background-size: cover;
      background-repeat: no-repeat;
    }
    EOF
    done

    ${pkgs.glib.dev}/bin/glib-compile-resources --sourcedir=. \
      --target=$out/gnome-shell-theme.gresource theme.xml
  '';
in
{
  _class = "nixos";

  # The greeter's session, not the users' (`gdm-password`).
  security.pam.services.gdm-launch-environment.rules.session.gdm-wallpaper = {
    order = 10350;
    control = "required";
    modulePath = "${config.security.pam.package}/lib/security/pam_env.so";
    settings.conffile = pkgs.writeText "gdm-wallpaper-env-conf" ''
      GNOME_SHELL_DATADIR DEFAULT="${dataDir}"
    '';
    settings.readenv = 0;
  };
}
