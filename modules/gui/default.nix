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
    ./sway.nix
    ./firefox.nix
    ./waybar.nix
  ];

  config = lib.mkIf config.gui.enable {
    hyprland.enable = false;
    sway.enable = true;
    firefox.enable = true;
    waybar.enable = true;

    home.packages = with pkgs; [
      blueman
      btop
      calibre
      d-spy
      dbeaver-bin
      ddcutil
      discord
      gnome-themes-extra
      gnome-tweaks
      libreoffice
      lutris
      networkmanagerapplet
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

      # codelldb debugger
      vscode-extensions.vadimcn.vscode-lldb.adapter
    ];

    home.file = {
      ".config/swappy/config" = {
        text = builtins.readFile ./swappy.conf;
      };
    };

    gtk = {
      enable = true;
      iconTheme = {
        package = pkgs.adwaita-icon-theme;
        name = "Adwaita";
      };
    };

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
        nas = {
          hostname = "192.168.1.15";
          port = 22;
          user = "guillaume";
          identityFile = "~/.ssh/id_ed25519_nas";
        };
        gullywash = {
          hostname = "192.168.1.191";
          port = 22;
          forwardAgent = true;
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
      pinentryPackage = pkgs.pinentry-qt;
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

    programs.wofi = {
      enable = true;
      settings = {
        allow_images = true;
        key_up = "Ctrl-p";
        key_down = "Ctrl-n";
      };
      style = ''
        window {
          margin: 0px;
          border: 1px solid #928374;
          background-color: #282828;
        }

        #input {
          margin: 5px;
          border: none;
          color: #ebdbb2;
          background-color: #1d2021;
        }

        #inner-box {
          margin: 5px;
          border: none;
          background-color: #282828;
        }

        #outer-box {
          margin: 5px;
          border: none;
          background-color: #282828;
        }

        #scroll {
          margin: 0px;
          border: none;
        }

        #text {
          margin: 5px;
          border: none;
          color: #ebdbb2;
        }

        #entry:selected {
          background-color: #1d2021;
          border-radius: 4px;
        }
      '';
    };

    services.cliphist.enable = true;

    services.swayidle = {
      enable = true;
      timeouts =
        let
          lockTimeout = 60 * 10; # 10 minutes
          screenOffTimeout = 10;
          suspendTimeout = 2 * lockTimeout;
          screenOffCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms off'";
          screenOnCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on'";
        in
        [
          {
            timeout = lockTimeout;
            command = "${(import ./lock.nix { inherit pkgs; })}/bin/lock.sh &";
          }
          {
            timeout = lockTimeout + screenOffTimeout;
            command = "if ${pkgs.procps}/bin/pgrep -x swaylock; then ${screenOffCommand}; fi";
            resumeCommand = "${screenOnCommand}";
          }
          {
            timeout = screenOffTimeout;
            command = "if ${pkgs.procps}/bin/pgrep -x swaylock; then ${screenOffCommand}; fi";
            resumeCommand = "${screenOnCommand}";
          }
          {
            timeout = suspendTimeout;
            command = "${pkgs.systemd}/bin/systemctl suspend";
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
      defaultTimeout = 10000;
      extraConfig = ''
        [app-name="Firefox"]
        default-timeout=0

        [app-name="Pomodoro"]
        default-timeout=0

        [app-name="NetworkManager Applet"]
        default-timeout=5000
      '';
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
