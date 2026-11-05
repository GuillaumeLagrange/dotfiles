{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/mapper/enc";
    fsType = "btrfs";
    options = [
      "subvol=root"
      "compress=zstd:1"
    ];
  };

  boot.initrd.luks.devices."enc".device = "/dev/disk/by-partlabel/snakewater-crypt";

  fileSystems."/nix" = {
    device = "/dev/mapper/enc";
    fsType = "btrfs";
    options = [
      "subvol=nix"
      "compress=zstd:1"
    ];
  };

  fileSystems."/var/log" = {
    device = "/dev/mapper/enc";
    fsType = "btrfs";
    options = [
      "subvol=log"
      "compress=zstd:1"
    ];
  };

  fileSystems."/home" = {
    device = "/dev/mapper/enc";
    fsType = "btrfs";
    options = [
      "subvol=home"
      "compress=zstd:1"
    ];
  };

  fileSystems."/swap" = {
    device = "/dev/mapper/enc";
    fsType = "btrfs";
    options = [ "subvol=swap" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/snakewater-esp";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
