{ lanzaboote }:

{ lib, pkgs, ... }:

{
  imports = [
    lanzaboote.nixosModules.lanzaboote
  ];

  # Bootloader with secure-boot
  # https://github.com/nix-community/lanzaboote/blob/master/docs/QUICK_START.md
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = true;
    autoEnrollKeys = {
      enable = true;
      # Automatically reboot to enroll the keys in the firmware
      autoReboot = true;
    };
  };

  # Include sbctl for managing secure boot
  environment.systemPackages = with pkgs; [
    sbctl
  ];
}
