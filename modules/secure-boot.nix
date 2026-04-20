{ inputs, ... }:
{
  flake.modules.nixos.secure-boot =
    { lib, pkgs, ... }:
    {
      imports = [
        inputs.lanzaboote.nixosModules.lanzaboote
      ];

      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";
        autoGenerateKeys.enable = true;
        autoEnrollKeys = {
          enable = true;
          autoReboot = true;
        };
      };

      environment.systemPackages = with pkgs; [
        sbctl
      ];
    };
}
