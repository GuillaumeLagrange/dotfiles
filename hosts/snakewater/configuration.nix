{
  config,
  pkgs,
  lib,
  ...
}:
{
  _class = "nixos";

  networking.hostName = "snakewater";
  networking.nftables.enable = true;

  boot.supportedFilesystems = [ "btrfs" ];
  # LTS: NVIDIA's module lags behind linuxPackages_latest. From unstable so the driver (same package set) is current.
  boot.kernelPackages = pkgs.unstable.linuxPackages;
  # From `btrfs inspect-internal map-swapfile -r /swap/swapfile`; changes if the file is recreated.
  boot.kernelParams = [
    "resume_offset=533760"
    "kvm.enable_virt_at_load=0"
  ];

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.latest;
    open = true;
    modesetting.enable = true;
    powerManagement.enable = true;
  };

  # Keeps niri from holding GBs of VRAM: https://github.com/YaLTeR/niri/wiki/Nvidia
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
    capSysAdmin = true;
    openFirewall = true;
    package = pkgs.sunshine.override { cudaSupport = true; };
    settings = {
      # Unset, Sunshine picks wlr-screencopy (a copy through niri each frame) and drops CAP_SYS_ADMIN.
      capture = "kms";
      encoder = "nvenc";
      output_name = "DP-4";
      global_prep_cmd =
        let
          dell = "Dell Inc. DELL S2421HS 45WFW83";
          dellOutput =
            action:
            pkgs.writeShellScript "dell-${action}" ''${pkgs.niri}/bin/niri msg output "${dell}" ${action}'';
        in
        builtins.toJSON [
          {
            do = "${dellOutput "off"}";
            undo = "${dellOutput "on"}";
          }
        ];
    };
  };
  # CAP_SYS_NICE gives Sunshine's EGL context high GPU priority, keeping capture ahead of a busy game.
  security.wrappers.sunshine.capabilities = lib.mkForce "cap_sys_admin,cap_sys_nice+p";

  services.logind.settings.Login = {
    HandlePowerKey = "suspend";
    UserStopDelaySec = 0;
  };
  systemd.user.extraConfig = "DefaultTimeoutStopSec=10s";

  services.udev.extraRules = ''
    ATTRS{name}=="*Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
  '';

  programs.steam = {
    extest.enable = true;
    extraPackages = [ pkgs.libsecret ];
  };

  environment.systemPackages = with pkgs; [
    lutris
  ];

  services.avahi.publish = {
    enable = true;
    addresses = true;
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      StreamLocalBindUnlink = true;
    };
  };
  networking.firewall.extraInputRules = ''
    ip saddr 192.168.1.0/24 tcp dport 22 accept
  '';
  networking.interfaces.enp7s0.wakeOnLan.enable = true;
  users.users.guillaume.openssh.authorizedKeys.keys = [
    (lib.trim (builtins.readFile ../guiom_ssh.pub))
  ];

  services.flatpak.enable = true;

  system.stateVersion = "26.05";
}
