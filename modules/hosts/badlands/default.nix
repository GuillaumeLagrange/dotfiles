{ self, inputs, ... }:
{
  flake.modules.nixos.badlands =
    { pkgs, lib, ... }:
    {
      imports = with self.modules.nixos; [
        base
        home-manager
        stylix
        secure-boot
        gui
        codspeed
        ./_hardware.nix
      ];

      home-manager.users.guillaume.imports = with self.modules.homeManager; [ guillaume ];

      boot.loader.efi.canTouchEfiVariables = true;
      boot.supportedFilesystems = [ "btrfs" ];

      networking.hostName = "badlands";
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

      services.thermald.enable = true;
      services.power-profiles-daemon.enable = true;
      powerManagement = {
        enable = true;
        powertop.enable = true;
      };

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

      services.printing.enable = true;

      services.udev.packages = [
        pkgs.yubikey-personalization
      ];
      services.pcscd.enable = true;

      users.users.guillaume.extraGroups = [
        "networkmanager"
        "i2c"
      ];

      programs.hyprland.enable = false;
      programs.steam.enable = true;

      nixpkgs.config.allowUnfree = true;

      environment.etc."distrobox/distrobox.conf".text = ''
        container_additional_volumes="/nix/store:/nix/store:ro /etc/profiles/per-user:/etc/profiles/per-user:ro /etc/static/profiles/per-user:/etc/static/profiles/per-user:ro"
        container_init_hook="echo 'export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH\"' >> /etc/profile.d/fix-path.sh"
      '';

      environment.systemPackages = with pkgs; [
        vim
        git
        qemu
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

      hardware.graphics.enable = true;
      hardware.graphics.extraPackages = with pkgs; [
        intel-media-driver
      ];

      services.fprintd.enable = true;
      systemd.services.fprintd = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "simple";
      };

      services.usbmuxd.enable = true;
      services.avahi = {
        nssmdns4 = true;
        enable = true;
      };

      virtualisation.virtualbox.host.enable = true;
      users.extraGroups.vboxusers.members = [ "guillaume" ];
      boot.kernelParams = [ "kvm.enable_virt_at_load=0" ];

      services.tailscale.enable = true;

      system.stateVersion = "24.05";
    };

  flake.nixosConfigurations.badlands = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.badlands
      {
        nixpkgs.overlays = [ self.overlays.default ];
      }
    ];
  };
}
