{ pkgs, lib, ... }:
{
  _class = "nixos";

  programs.niri.enable = true;
  # Swapped-out compositor pages stall niri's main loop.
  systemd.user.services.niri.serviceConfig.MemorySwapMax = 0;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  services.gnome.gcr-ssh-agent.enable = false;
  i18n.inputMethod.enable = false;

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  xdg.portal.enable = true;

  hardware.graphics.enable = true;

  services.xserver = {
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

  services.resolved.enable = true;
  services.power-profiles-daemon.enable = true;
  services.printing.enable = true;
  services.tailscale.enable = true;
  services.avahi = {
    nssmdns4 = true;
    enable = true;
  };

  hardware.bluetooth = {
    enable = true;
    settings = {
      General = {
        AlwaysPairable = true;
      };
      Policy = {
        ReconnectAttempts = 0;
      };
    };
  };
  hardware.i2c.enable = true;
  hardware.keyboard.qmk.enable = true;

  services.udev.packages = [
    pkgs.yubikey-personalization
  ];
  services.pcscd.enable = true;

  users.users.guillaume.extraGroups = [
    "networkmanager"
    "i2c"
  ];

  security.sudo.extraConfig = ''
    Defaults pwfeedback
  '';

  programs.steam.enable = true;

  nixpkgs.config.allowUnfree = true;

  environment.enableDebugInfo = true;

  environment.etc."distrobox/distrobox.conf".text = ''
    container_additional_volumes="/nix/store:/nix/store:ro /etc/profiles/per-user:/etc/profiles/per-user:ro /etc/static/profiles/per-user:/etc/static/profiles/per-user:ro"
    clean_path=1
  '';

  environment.systemPackages = with pkgs; [
    vim
    git
    qemu
    distrobox
    perf
  ];

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = lib.mkDefault 50;
    priority = 100;
  };
  # ArchWiki's values for swap on zram.
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.watermark_boost_factor" = 0;
  };
}
