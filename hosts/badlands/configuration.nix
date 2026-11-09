{ pkgs, ... }:
{
  _class = "nixos";

  networking.hostName = "badlands";

  boot.supportedFilesystems = [ "btrfs" ];
  boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];

  zramSwap.memoryPercent = 150;

  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
  ];

  environment.systemPackages = with pkgs; [
    libimobiledevice
  ];
  services.usbmuxd.enable = true;

  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = [ "guillaume" ];

  system.stateVersion = "24.05";
}
