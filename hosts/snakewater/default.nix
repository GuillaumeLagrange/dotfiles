{ self, inputs, ... }:
{
  flake.modules.nixos.snakewater =
    { config, pkgs, ... }:
    {
      imports = with self.modules.nixos; [
        base
        home-manager
        stylix
        secure-boot
        gui
        ./_hardware.nix
      ];

      home-manager.users.guillaume = {
        imports = with self.modules.homeManager; [ guillaume ];
        # No refresh in the mode: niri then picks the highest one (240 Hz).
        monitors.mainHome.refreshRate = null;
      };

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
      # The default LTS kernel: NVIDIA's out-of-tree module lags behind linuxPackages_latest
      # (595.71 fails on 7.3, which dropped strncpy).
      boot.kernelPackages = pkgs.linuxPackages;
      boot.resumeDevice = "/dev/mapper/enc";
      # From `btrfs inspect-internal map-swapfile -r /swap/swapfile`; changes if the file is recreated.
      boot.kernelParams = [
        "resume_offset=533760"
        "kvm.enable_virt_at_load=0"
      ];

      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
        priority = 100;
      };

      # Same as granary: reclaim anon pages into zram rather than dropping file pages.
      boot.kernel.sysctl = {
        "vm.swappiness" = 180;
        "vm.page-cluster" = 0;
        "vm.watermark_scale_factor" = 125;
        "vm.watermark_boost_factor" = 0;
      };

      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.latest;
        # NVIDIA's recommended module for Turing and newer.
        open = true;
        modesetting.enable = true;
        # Saves VRAM across suspend/hibernate.
        powerManagement.enable = true;
      };
      hardware.graphics.enable = true;

      # Without it the driver keeps freed buffers around and niri grows to GBs of VRAM:
      # https://github.com/YaLTeR/niri/wiki/Nvidia
      environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text =
        builtins.toJSON {
          rules = [
            {
              pattern = {
                feature = "procname";
                matches = "niri";
              };
              profile = "Limit Free Buffer Pool On Wayland Compositors";
            }
          ];
          profiles = [
            {
              name = "Limit Free Buffer Pool On Wayland Compositors";
              settings = [
                {
                  key = "GLVidHeapReuseRatio";
                  value = 0;
                }
              ];
            }
          ];
        };

      services.sunshine = {
        enable = true;
        autoStart = true;
        # KMS capture, the only one that works under niri on NVIDIA.
        capSysAdmin = true;
        openFirewall = true;
        package = pkgs.sunshine.override { cudaSupport = true; };
      };

      networking.hostName = "snakewater";
      networking.networkmanager.enable = true;
      networking.nftables.enable = true;

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

      environment.enableDebugInfo = true;

      services.logind.settings.Login = {
        HandlePowerKey = "suspend";
        # Stop the user manager (and niri.service) on logout; the default 10s delay
        # leaves niri running, so an immediate GDM re-login fails.
        UserStopDelaySec = 0;
      };
      systemd.user.extraConfig = "DefaultTimeoutStopSec=10s";

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

      programs.steam = {
        enable = true;
        extest.enable = true;
      };

      nixpkgs.config.allowUnfree = true;

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

      security.sudo.extraConfig = ''
        Defaults pwfeedback
      '';

      services.avahi = {
        nssmdns4 = true;
        enable = true;
        # snakewater.local, what the ssh client config dials.
        publish = {
          enable = true;
          addresses = true;
        };
      };

      services.openssh = {
        enable = true;
        openFirewall = false;
        settings = {
          PasswordAuthentication = false;
          # Lets a forwarded gpg-agent socket replace the one left by the last session.
          StreamLocalBindUnlink = true;
        };
      };
      networking.firewall.extraInputRules = ''
        ip saddr 192.168.1.0/24 tcp dport 22 accept
      '';
      # Idle suspends it like the laptops: a magic packet wakes it for Sunshine.
      networking.interfaces.enp7s0.wakeOnLan.enable = true;
      users.users.guillaume.openssh.authorizedKeys.keys = [
        (inputs.nixpkgs.lib.trim (builtins.readFile ../../modules/headless/guiom_ssh.pub))
      ];

      services.tailscale.enable = true;
      services.flatpak.enable = true;

      system.stateVersion = "26.05";
    };

  flake.nixosConfigurations.snakewater = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.snakewater
      {
        nixpkgs.overlays = [ self.overlays.default ];
      }
    ];
  };
}
