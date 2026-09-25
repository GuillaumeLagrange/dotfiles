{ self, inputs, ... }:
{
  flake.modules.nixos.granary =
    { pkgs, ... }:
    {
      imports = with self.modules.nixos; [
        base
        home-manager
        stylix
        secure-boot
        gui
        codspeed
        inputs.nixos-hardware.nixosModules.framework-intel-core-ultra-series3
        inputs.intel-lpmd.nixosModules.default
        ./_hardware.nix
      ];

      home-manager.users.guillaume = {
        imports = with self.modules.homeManager; [ guillaume ];
        monitors.laptop = {
          resolution = "2880x1920";
          scale = 1.5;
        };
      };

      # The secure-boot module forces this off in favour of lanzaboote.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.supportedFilesystems = [ "btrfs" ];

      # Required for TPM2 unlocking in the initrd.
      boot.initrd.systemd.enable = true;
      boot.initrd.luks.devices."enc" = {
        allowDiscards = true;
        bypassWorkqueues = true;
        crypttabExtraOpts = [ "tpm2-device=auto" ];
      };

      security.tpm2.enable = true;

      swapDevices = [ { device = "/swap/swapfile"; } ];
      boot.resumeDevice = "/dev/mapper/enc";
      boot.kernelPackages = pkgs.linuxPackages_latest;
      # From `btrfs inspect-internal map-swapfile -r /swap/swapfile`; changes if the file is recreated.
      boot.kernelParams = [
        "resume_offset=533760"
        "kvm.enable_virt_at_load=0"
      ];

      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 150;
        priority = 100;
      };

      networking.hostName = "granary";
      networking.networkmanager.enable = true;
      services.resolved.enable = true;

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

      services.power-profiles-daemon.enable = true;
      powerManagement.enable = true;
      services.thermald.enable = true;
      services.intel-lpmd = {
        enable = true;
        config.pantherLake = true;
      };

      environment.enableDebugInfo = true;

      services.logind.settings.Login = {
        HandleLidSwitch = "suspend-then-hibernate";
        HandlePowerKey = "suspend-then-hibernate";
        # Stop the user manager (and niri.service) on logout; the default 10s delay
        # leaves niri running, so an immediate GDM re-login fails.
        UserStopDelaySec = 0;
      };
      systemd.sleep.settings.Sleep.HibernateDelaySec = "24h";

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

      services.displayManager.gdm.enable = true;
      services.desktopManager.gnome.enable = true;
      services.gnome.gcr-ssh-agent.enable = false;

      # Disable the IBus notification on niri
      i18n.inputMethod.enable = false;

      services.printing.enable = true;

      services.udev.packages = [
        pkgs.yubikey-personalization
      ];
      services.pcscd.enable = true;

      users.users.guillaume.extraGroups = [
        "networkmanager"
        "i2c"
        "tss"
      ];

      programs.hyprland.enable = false;
      programs.steam.enable = true;

      nixpkgs.config.allowUnfree = true;

      environment.etc."distrobox/distrobox.conf".text = ''
        container_additional_volumes="/nix/store:/nix/store:ro /etc/profiles/per-user:/etc/profiles/per-user:ro /etc/static/profiles/per-user:/etc/static/profiles/per-user:ro"
        clean_path=1
      '';

      environment.systemPackages = with pkgs; [
        vim
        git
        qemu
        libimobiledevice
        distrobox
        perf
        tpm2-tools
      ];

      boot.binfmt.emulatedSystems = [
        "aarch64-linux"
      ];

      hardware.bluetooth = {
        enable = true;
        settings = {
          # No default pairing agent runs (the quickshell bar pairs through
          # bt-pair's own agent), and without one BlueZ leaves the adapter
          # non-bondable, so a pairing would not store its keys.
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

      hardware.graphics.enable = true;
      hardware.graphics.extraPackages = with pkgs; [
        intel-media-driver
      ];

      services.fprintd.enable = true;
      systemd.services.fprintd = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "simple";
      };

      security.sudo.extraConfig = ''
        Defaults pwfeedback
      '';

      services.usbmuxd.enable = true;
      services.avahi = {
        nssmdns4 = true;
        enable = true;
      };

      virtualisation.virtualbox.host.enable = true;
      users.extraGroups.vboxusers.members = [ "guillaume" ];

      services.tailscale.enable = true;

      system.stateVersion = "26.05";
    };

  flake.nixosConfigurations.granary = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.granary
      {
        nixpkgs.overlays = [ self.overlays.default ];
      }
    ];
  };
}
