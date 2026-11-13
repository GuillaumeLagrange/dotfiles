{ pkgs, ... }:
{
  _class = "homeManager";

  home.packages = [
    pkgs.passwords
    pkgs.unstable.proton-pass-cli
  ];

  # pass-cli keeps its key in the kernel keyring by default, wiped on reboot;
  # gnome-keyring keeps it. `passwords` sets it too, for when it is spawned by niri.
  home.sessionVariables.PROTON_PASS_LINUX_KEYRING = "dbus";

  xdg.desktopEntries.passwords = {
    name = "Passwords";
    comment = "Copy a login from Proton Pass or 1Password";
    icon = "dialog-password";
    exec = "${pkgs.passwords}/bin/passwords pick";
  };
}
