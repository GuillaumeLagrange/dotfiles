# Edit this configuration file to define what should be installed on
{ pkgs, lib, ... }:

let
  userName = "guillaume";
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../common.nix
    ./oneleet.nix
  ];

  # Bootloader
  # Secure boot is handled in secure_boot.nix
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "btrfs" ];

  nix.optimise.automatic = true;

  networking.hostName = "badlands";

  # Enable networking
  networking.networkmanager.enable = true;
  # Allow wireguard to use systemd-resolved
  services.resolved.enable = true;

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  # Laptop power management
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;
  powerManagement = {
    enable = true;
    powertop.enable = true;
  };

  # Auto-switch power profiles based on AC status
  services.udev.extraRules = ''
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="1", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced"
    SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ATTR{online}=="0", RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set power-saver"
  '';

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandlePowerKey = "suspend-then-hibernate";
  };
  systemd.sleep.extraConfig = "HibernateDelaySec=24h";

  services.xserver = {
    # Enable X11 as a fallback
    enable = true;
    xkb = {
      layout = "qwerty-fr";
      extraLayouts."qwerty-fr" =
        let
          qwerty-fr = pkgs.qwerty-fr;
        in
        {
          description = qwerty-fr.meta.description;
          languages = [ "eng" ];
          symbolsFile = "${qwerty-fr}/share/X11/xkb/symbols/us_qwerty-fr";
        };
    };

  };

  services.displayManager.sddm = {
    enable = true;
    # To use Wayland (Experimental for SDDM)
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;
  environment.plasma6.excludePackages = with pkgs.kdePackages; [
    plasma-browser-integration
    konsole
    elisa
  ];

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Yubikey management
  services.udev.packages = [
    pkgs.yubikey-personalization
  ];
  services.pcscd.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Additional groups for badlands-specific hardware
  users.users.guillaume.extraGroups = [
    "networkmanager"
    "i2c"
  ];

  programs.hyprland.enable = false;
  programs.niri.enable = true;
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
  };
  xdg.portal = {
    enable = true;
  };
  programs.steam.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile.
  environment.systemPackages = with pkgs; [
    vim
    git
    comma
    qemu
    # iOS tethering
    libimobiledevice
    distrobox

    perf
  ];

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  hardware.bluetooth = {
    enable = true;
    settings = {
      Policy = {
        ReconnectAttempts = 0;
      };
    };
  };
  hardware.i2c.enable = true;
  hardware.keyboard.qmk.enable = true;

  # Enable OpenGL
  hardware.graphics.enable = true;

  # Fingerprint reader
  services.fprintd.enable = true;
  # Start the driver at boot
  systemd.services.fprintd = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig.Type = "simple";
  };

  # Installed at OS level to benefit from browser plugin integration
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    # Certain features, including CLI integration and system authentication support,
    # require enabling PolKit integration on some desktop environments (e.g. Plasma).
    polkitPolicyOwners = [ userName ];
  };

  # iOS tethering
  services.usbmuxd.enable = true;

  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = [ "guillaume" ];
  # Temporary work around: https://github.com/NixOS/nixpkgs/issues/363887#issuecomment-2536693220
  boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];

  # Enable oneleet
  programs.oneleet.enable = true;

  system.stateVersion = "24.05";
}
