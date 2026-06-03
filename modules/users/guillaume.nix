{ self, ... }:
{
  flake.modules.homeManager.guillaume = {
    imports = with self.modules.homeManager; [
      base
      terminal
      headless
      gui
      codspeed
      stylix
    ];
  };

  flake.modules.homeManager.guillaume-headless = {
    imports = with self.modules.homeManager; [
      base
      terminal
      headless
      stylix
    ];

    programs.zsh.oh-my-zsh.theme = "gnzh";

    # No display server on a headless box: keep stylix for CLI tools but drop
    # the GUI targets it auto-enables (they pull in gnome-shell / GTK builds).
    stylix.targets = {
      gnome.enable = false;
      gtk.enable = false;
      gnome-text-editor.enable = false;
      nixos-icons.enable = false;
    };

    # No dconf/dbus service on a headless box, so skip the dconf activation
    # (otherwise it fails with "ca.desrt.dconf was not provided").
    dconf.enable = false;
  };
}
