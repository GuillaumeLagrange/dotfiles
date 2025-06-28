# VM version
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  unifiedBindMount = "/unified_bind_mount";
in
{
  imports = [ ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "ohci_pci"
    "ehci_pci"
    "ahci"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXROOT";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXBOOT";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # Key is expected to bee at /root/zfs_passfile
  fileSystems."/media" = {
    device = "tank/main/media";
    fsType = "zfs";
    options = [
      "zfsutil"
      "nofail"
    ];
  };

  fileSystems."/configs" = {
    device = "tank/main/configs";
    fsType = "zfs";
    options = [
      "zfsutil"
      "nofail"
    ];
  };

  # Bind mount to granuarly mount inside containers and keep them awayre that it's the same filesystem
  fileSystems."${unifiedBindMount}" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "size=20M"
      "mode=755"
    ];
  };

  # Series downloads bind mounts
  fileSystems."${unifiedBindMount}/series_downloads/series" = {
    device = "/media/series";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
    depends = [
      "/media"
      "${unifiedBindMount}"
    ];
  };

  fileSystems."${unifiedBindMount}/series_downloads/downloads" = {
    device = "/media/downloads";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
    depends = [
      "/media"
      "${unifiedBindMount}"
    ];
  };

  # Movies downloads bind mounts
  fileSystems."${unifiedBindMount}/movies_downloads/movies" = {
    device = "/media/movies";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
    depends = [
      "/media"
      "${unifiedBindMount}"
    ];
  };

  fileSystems."${unifiedBindMount}/movies_downloads/downloads" = {
    device = "/media/downloads";
    fsType = "none";
    options = [
      "bind"
      "nofail"
    ];
    depends = [
      "/media"
      "${unifiedBindMount}"
    ];
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 32768; # 32GB
    }
  ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
  # (the default) this is the recommended approach. When using systemd-networkd it's
  # still possible to use this option, but it's recommended to use it in conjunction
  # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
  networking.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp0s3.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
