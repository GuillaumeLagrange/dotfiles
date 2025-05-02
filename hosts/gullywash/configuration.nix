# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./nginx.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "zfs" ];

  networking.hostName = "gullywash";
  networking.networkmanager.enable = true;
  # Necessary for ZFS, value is not important because disks won't be shared across the network
  networking.hostId = "deadbeef";
  networking.enableIPv6 = false;

  time.timeZone = "Europe/Paris";

  programs.zsh.enable = true;
  users.users.guillaume = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICB1BgyotMSfKqSwUoeMKJcC6d+y468PRjPrcnvMxZBW cardno:29_644_001"
    ];
    shell = pkgs.zsh;
  };

  programs.nix-ld.enable = true;
  environment.systemPackages = with pkgs; [
    neovim
    wget
    zfs

    home-manager
    docker-compose
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      StreamLocalBindUnlink = true;
    };
  };
  programs.gnupg.agent = {
    enable = true;
  };

  virtualisation.docker.enable = true;

  system.stateVersion = "24.11"; # Don't touch this ever
}
