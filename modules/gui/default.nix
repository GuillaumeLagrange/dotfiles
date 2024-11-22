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
    hyprland.enable = true;
    sway.enable = true;
    firefox.enable = true;
    waybar.enable = true;

    home.packages = with pkgs; [
      adwaita-icon-theme
      blueman
      calibre
      d-spy
      dbeaver-bin
      ddcutil
      discord
      gnome-themes-extra
      gnome-tweaks
      libreoffice
      networkmanagerapplet
      pavucontrol
      playerctl
      proton-pass
      protonvpn-gui
      qwerty-fr
      spotify
      telegram-desktop
      transmission-remote-gtk
      transmission_4-gtk
      vlc
      wdisplays
      wev
      wl-clipboard
    ];

    home.file = {
      ".config/swappy/config" = {
        text = builtins.readFile ./swappy.conf;
      };
    };

    gtk.iconTheme = {
      package = pkgs.adwaita-icon-theme;
      name = "adwaita-icon-theme";
    };

    programs.ssh = {
      enable = true;
      addKeysToAgent = "yes";
      matchBlocks = {
        charybdisRemote = lib.hm.dag.entryBefore [ "charybdis" ] {
          match = ''originalhost charybdis exec "[ $(${pkgs.wirelesstools}/bin/iwgetid --scheme)_ != Stockly_ ]"'';
          hostname = "charybdis.stockly.tech";
          port = 23;
          compression = true;
        };
        charybdis = {
          port = 22;
          hostname = "192.168.1.10";
          user = "guillaume";
          forwardAgent = true;
          identityFile = "~/.ssh/id_ed25519_monster";
        };
        cerberusRemote = lib.hm.dag.entryBefore [ "cerberus" ] {
          match = ''originalhost cerberus exec "[ $(${pkgs.wirelesstools}/bin/iwgetid --scheme)_ != Stockly_ ]"'';
          hostname = "cerberus.stockly.tech";
          port = 24;
          compression = true;
        };
        cerberus = {
          port = 22;
          hostname = "192.168.1.12";
          user = "guillaume";
          forwardAgent = true;
          identityFile = "~/.ssh/id_ed25519_monster";
        };
        nas = {
          hostname = "192.168.1.15";
          port = 22;
          user = "guillaume";
          identityFile = "~/.ssh/id_ed25519_nas";
        };
      };
      extraConfig = ''
        # Charybdis
        Host charybdis
            LocalForward 2524 localhost:2524   # Operations GRPC
            LocalForward 2526 localhost:2526   # Auths GRPC
            LocalForward 2527 localhost:2527   # Auths HTTP
            LocalForward 2530 localhost:2530   # Shipments GRPC
            LocalForward 2534 localhost:2534   # Files GRPC
            LocalForward 2535 localhost:2535   # Files HTTP
            LocalForward 2528 localhost:2528   # Backoffice GRCP
            LocalForward 2529 localhost:2529   # Backoffice HTTP
            LocalForward 2541 localhost:2541   # Backoffice Front
            LocalForward 2538 localhost:2538   # Consumer Backoffice GRCP
            LocalForward 2539 localhost:2539   # Consumer Backoffice HTTP
            LocalForward 2542 localhost:2542   # Consumer Backoffice Front
            LocalForward 2545 localhost:2545   # Meilisearch

            LocalForward 4003 localhost:4003   # Shipments GRPC 🚨 PROD

        # Cerberus
        Host cerberus
            LocalForward 1574 localhost:1574   # Operations GRPC
            LocalForward 1576 localhost:1576   # Auths GRPC
            LocalForward 1577 localhost:1577   # Auths HTTP
            LocalForward 1580 localhost:1580   # Shipments GRPC
            LocalForward 1584 localhost:1584   # Files GRPC
            LocalForward 1585 localhost:1585   # Files HTTP
            LocalForward 1578 localhost:1578   # Backoffice GRCP
            LocalForward 1579 localhost:1579   # Backoffice HTTP
            LocalForward 1591 localhost:1591   # Backoffice Front
            LocalForward 1588 localhost:1588   # Consumer Backoffice GRCP
            LocalForward 1589 localhost:1589   # Consumer Backoffice HTTP
            LocalForward 1592 localhost:1592   # Consumer Backoffice Front
            LocalForward 1595 localhost:1595   # Meilisearch

            LocalForward 4003 localhost:4003   # Shipments GRPC 🚨 PROD
      '';
    };

    services.ssh-agent.enable = true;

    programs.gpg.enable = true;
    services.gpg-agent = {
      enable = true;
      enableExtraSocket = true;
      pinentryPackage = pkgs.pinentry-gtk2;
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
            resumeCommand = "PATH=/usr/bin ${screenOnCommand}";
          }
          {
            timeout = screenOffTimeout;
            command = "if ${pkgs.procps}/bin/pgrep -x swaylock; then ${screenOffCommand}; fi";
            resumeCommand = "PATH=/usr/bin ${screenOnCommand}";
          }
          {
            timeout = suspendTimeout;
            command = "PATH=/usr/bin systemctl suspend";
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

        [app-name="NetworkManager Applet"]
        default-timeout=5000
      '';
    };

    programs.wpaperd = {
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
