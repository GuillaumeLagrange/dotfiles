{ pkgs, ... }:
{
  _class = "nixos";

  networking.hostName = "granary";
  networking.nftables.enable = true;

  boot.supportedFilesystems = [ "btrfs" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # From `btrfs inspect-internal map-swapfile -r /swap/swapfile`; changes if the file is recreated.
  boot.kernelParams = [
    "resume_offset=533760"
    "kvm.enable_virt_at_load=0"
  ];

  services.intel-lpmd = {
    enable = true;
    config.pantherLake = true;
  };

  services.logind.settings.Login = {
    UserStopDelaySec = 0;
  };
  systemd.user.extraConfig = "DefaultTimeoutStopSec=10s";

  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
  ];

  programs.steam.extest.enable = true;

  environment.systemPackages = with pkgs; [
    libimobiledevice
    lutris
  ];

  services.usbmuxd.enable = true;

  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = [ "guillaume" ];

  services.flatpak.enable = true;

  system.stateVersion = "26.05";
}
