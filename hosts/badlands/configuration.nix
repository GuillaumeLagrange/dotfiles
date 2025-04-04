# Edit this configuration file to define what should be installed on
{ pkgs, lib, ... }@inputs:

let
  userName = "guillaume";
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
  ];

  # Bootloader with secure-boot
  # https://github.com/nix-community/lanzaboote/blob/master/docs/QUICK_START.md
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/etc/secureboot";
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "btrfs" ];

  # Auto garbage collect
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  # Enable flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.extraOptions = ''
    trusted-users = root guillaume
  '';

  networking.hostName = "badlands";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Paris";

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
  powerManagement = {
    enable = true;
    powertop.enable = true;
  };

  services.logind = {
    lidSwitch = "suspend-then-hibernate";
    powerKey = "suspend-then-hibernate";
  };
  systemd.sleep.extraConfig = "HibernateDelaySec=3h";

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

    # Gnome
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  # Disable gnome keyring as gnome is mostly here as a fallback
  # Keyring cannot be unlocked through fprintd so we cannot avoid the popup on login
  # services.gnome.gnome-keyring.enable = lib.mkForce false;

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

  # Define a user account. Don't forget to set a password with ‘passwd’.
  programs.zsh.enable = true;
  users.users.${userName} = {
    isNormalUser = true;
    description = "Guillaume";
    extraGroups = [
      "networkmanager"
      "wheel"
      "i2c"
      "docker"
    ];
    shell = pkgs.zsh;
  };

  programs.nix-ld.enable = true;
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
    wget
    sbctl
    comma
    home-manager
    nh
    # iOS tethering
    libimobiledevice
    distrobox
  ];

  hardware.bluetooth.enable = true;
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

  virtualisation.docker.enable = true;

  system.stateVersion = "24.05";
}
