{
  pkgs,
  config,
  lib,
  ...
}:

{
  # Nix configuration
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  nix.extraOptions = ''
    trusted-users = root guillaume
  '';

  # Enable nix-ld for dynamic libraries
  programs.nix-ld.enable = true;

  # Time zone configuration
  time.timeZone = "Europe/Paris";

  # Enable zsh globally
  programs.zsh.enable = true;

  # Define the main user account
  users.users.guillaume = {
    isNormalUser = true;
    description = "Guillaume";
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
  };

  # Enable Docker virtualization
  virtualisation.docker.enable = true;

  # Common system packages
  environment.systemPackages = with pkgs; [
    wget
    home-manager
  ];

  # Enable nix-index database with comma
  programs.nix-index-database.comma.enable = true;

  # Clean up nix store automatically
  nix.optimise.automatic = true;
  programs.nh = {
    enable = true;
    clean = {
      enable = true;
      dates = "weekly";
      extraArgs = "--keep 5";
    };
  };

  # Hardware configuration common to both Intel systems
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
