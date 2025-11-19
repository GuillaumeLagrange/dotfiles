{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    gui.enable = lib.mkEnableOption "tools to work in a graphical environment";
  };

  imports = [
    ./hyprland.nix
    ./niri.nix
    ./sway.nix
    ./firefox.nix
    ./waybar.nix
    ./vicinae.nix
    ./options.nix
  ];

  config = lib.mkIf config.gui.enable {
    hyprland.enable = false;
    niri.enable = true;
    sway.enable = true;
    firefox.enable = true;
    waybar.enable = true;
    vicinae.enable = true;

    home.packages = with pkgs; [
      blueman
      btop
      calibre
      d-spy
      ddcutil
      discord
      gnome-themes-extra
      gnome-tweaks
      libreoffice
      lutris
      pavucontrol
      pomodoro-gtk
      playerctl
      proton-pass
      protonvpn-gui
      qwerty-fr
      slack
      spotify
      signal-desktop
      telegram-desktop
      transmission-remote-gtk
      transmission_4-gtk
      vlc
      wdisplays
      wev
      wl-clipboard
      wireguard-tools

      adwaita-icon-theme

      # codelldb debugger
      vscode-extensions.vadimcn.vscode-lldb.adapter
    ];

    home.file = {
      ".config/swappy/config" = {
        text = builtins.readFile ./swappy.conf;
      };
    };

    stylix.enable = true;

    gtk = {
      enable = true;
      iconTheme = {
        package = pkgs.adwaita-icon-theme;
        name = "Adwaita";
      };
    };
    services.network-manager-applet.enable = true;
    services.pasystray.enable = true;

    home.pointerCursor = {
      gtk.enable = true;
      x11.enable = true;
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
      size = 16;
    };

    programs.ssh = {
      enable = true;
      addKeysToAgent = "yes";
      matchBlocks = {
        gullywash = {
          hostname = "gullywash.glagrange.eu";
          port = 22;
          forwardAgent = true;
          addressFamily = "inet"; # Force IPV4
          user = "guillaume";
          remoteForwards = [
            {
              # gpgconf --list-dir agent-extra-socket on local machine
              host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
              # gpgconf --list-dir agent-socket on remote machine
              bind.address = "/run/user/1000/gnupg/S.gpg-agent";
            }
          ];
        };
      };
    };

    programs.gpg.enable = true;
    services.gpg-agent = {
      enable = true;
      enableSshSupport = true;
      enableExtraSocket = true;
      pinentry.package = pkgs.pinentry-qt;
    };

    programs.alacritty = {
      enable = true;
      settings = {
        mouse.hide_when_typing = true;
        env.TERM = "xterm-256color";
        window = {
          dynamic_title = false;
          startup_mode = "Maximized";
          padding = {
            x = 0;
            y = 2;
          };
        };
      };
    };

    programs.kitty = {
      enable = true;
      settings = {
        confirm_os_window_close = 0;
        enable_audio_bell = "no";
        window_alert_on_bell = "no";
        mouse_hide_wait = 0.5;
      };
    };

    programs.fuzzel = {
      enable = true;
    };

    services.cliphist.enable = true;

    services.swayidle = {
      enable = true;
      events = [
        {
          event = "before-sleep";
          command = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh";
        }
      ];
      timeouts =
        let
          lockTimeout = 60 * 10; # 10 minutes
          screenOffTimeout = 10;
          suspendTimeout = 2 * lockTimeout;
          screenOffCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms off' || ${pkgs.hyprland}/bin/hyprctl dispatch dpms off || ${pkgs.niri}/bin/niri msg action power-off-monitors";
          screenOnCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on' || ${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
        in
        [
          {
            timeout = lockTimeout;
            command = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh &";
          }
          {
            timeout = lockTimeout + screenOffTimeout;
            command = "if ${pkgs.procps}/bin/pgrep swaylock; then ${screenOffCommand}; fi";
            resumeCommand = "${screenOnCommand}";
          }
          {
            timeout = screenOffTimeout;
            command = "if ${pkgs.procps}/bin/pgrep swaylock; then ${screenOffCommand}; fi";
            resumeCommand = "${screenOnCommand}";
          }
          {
            timeout = suspendTimeout;
            command = "${pkgs.systemd}/bin/systemctl suspend-then-hibernate";
          }
        ];
    };

    systemd.user = {
      enable = true;
      startServices = true;
      services = {
        cliphist-wipe = {
          Unit = {
            Description = "Wipe cliphist at midnight";
          };
          Service = {
            ExecStart = "${pkgs.cliphist}/bin/cliphist wipe";
          };
        };
      };
      timers = {
        cliphist-wipe = {
          Unit = {
            Description = "Run cliphist wipe daily at midnight";
          };
          Install = {
            WantedBy = [ "timers.target" ];
          };
          Timer = {
            OnCalendar = "*-*-* 00:00:00";
            Persistent = true;
          };
        };
      };
    };

    programs.chromium.enable = true;

    programs.feh.enable = true;

    programs.vscode.enable = true;

    services.mako = {
      enable = true;
      settings = {
        default-timeout = 10000;

        "app-name=Slack" = {
          invisible = 1;
        };
      };
      # FIXME: Fix this
      # settings = ''
      #   [app-name="Firefox"]
      #   default-timeout=0
      #
      #   [app-name="Pomodoro"]
      #   default-timeout=0
      #
      #   [app-name="NetworkManager Applet"]
      #   default-timeout=5000
      # '';
    };

    services.wpaperd = {
      enable = true;
      settings = {
        default = {
          path = ./wallpapers;
          duration = "1h";
        };
      };
    };

    services.syncthing.enable = true;
  };
}
