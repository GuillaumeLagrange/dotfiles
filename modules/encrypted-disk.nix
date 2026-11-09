# encrypted-disk: btrfs on LUKS, with a swapfile to hibernate to.
{
  flake.modules.nixos.encrypted-disk =
    { pkgs, ... }:
    {
      boot.initrd.systemd.enable = true;
      boot.initrd.luks.devices."enc" = {
        allowDiscards = true;
        bypassWorkqueues = true;
        # Allow unlocking with the TPM.
        crypttabExtraOpts = [ "tpm2-device=auto" ];
      };

      security.tpm2.enable = true;
      users.users.guillaume.extraGroups = [ "tss" ];
      environment.systemPackages = [ pkgs.tpm2-tools ];

      swapDevices = [ { device = "/swap/swapfile"; } ];
      boot.resumeDevice = "/dev/mapper/enc";
    };
}
