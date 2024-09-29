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
  ];

  config = lib.mkIf config.gui.enable {
    hyprland.enable = true;
    sway.enable = true;
    firefox.enable = true;

    home.packages = with pkgs; [
      telegram-desktop
      discord
      spotify
      qwerty-fr
      wev
      wl-clipboard
      playerctl
      proton-pass
      protonvpn-gui
      transmission_4-gtk
      transmission-remote-gtk
      adwaita-icon-theme
      calibre
      gnome-themes-extra
      wdisplays
      pavucontrol
      dbeaver-bin
      networkmanagerapplet
      blueman
      ddcutil
      libreoffice
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
          identityFile = "~/.ssh/id_ed25519_charybdis";
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
            LocalForward 2545 localhost:2545   # Meilisearch

            LocalForward 4003 localhost:4003   # Shipments GRPC 🚨 PROD

      '';
    };

    services.ssh-agent.enable = true;

    programs.gpg.enable = true;
    services.gpg-agent = {
      enable = true;
      enableExtraSocket = true;
    };

    programs.alacritty = {
      enable = true;
      settings = {
        mouse.hide_when_typing = true;
        env.TERM = "xterm-256color";
        window = {
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

    programs.waybar = {
      enable = true;
      style = builtins.readFile ./style.css;
      settings = {
        mainBar = {
          layer = "top";
          position = "bottom";
          height = 22;
          output = [ "*" ];
          modules-left = [
            "hyprland/submap"
            "hyprland/workspaces"
            "hyprland/window"
            "sway/workspaces"
            "sway/window"
            "sway/mode"
          ];
          modules-center = [ ];
          modules-right = [
            "mpris"
            "tray"
            "disk"
            "cpu"
            "memory"
            "battery"
            "pulseaudio"
            "clock"
          ];

          "hyprland/workspaces" = {
            all-outputs = false;
            show-special = true;
          };

          "hyprland/window" = {
            separate-outputs = true;
          };

          "mpris" = {
            "format" = " {player_icon} {status_icon} {dynamic} ";
            "ignored-players" = [ ];
            "player-icons" = {
              "default" = " ";
              "spotify" = " ";
              "firefox" = " ";
            };
            "status-icons" = {
              "paused" = " ";
              "playing" = " ";
            };
            "dynamic-order" = [
              "title"
              "artist"
              "position"
              "length"
            ];
            "dynamic-len" = 70;
            "interval" = 1;
          };

          "tray" = {
            icon-size = 14;
            spacing = 8;
            show-passive-items = true;
          };

          "disk" = {
            "format" = "{free}";
          };

          "pulseaudio" = {
            "format" = "{icon} {volume}%";
            "format-bluetooth" = " {icon} {volume}%";
            "format-muted" = "󰝟  {volume}%";
            "format-icons" = {
              "default" = [
                "󰕿 "
                "󰖀 "
                "󰕾 "
              ];
            };
            "scroll-step" = 1;
            "on-click" = "pavucontrol";
          };

          "battery" = {
            "format" = "{icon} {capacity}%";
            "format-charging" = "󱐋 {icon} {capacity}%";
            "format-icons" = [
              "󰂎"
              "󱊡"
              "󱊢"
              "󱊣"
            ];
          };

          "clock" = {
            "format" = "  {:L%B %d, %R}";
            "format-alt" = "  {:L%H:%M} ";
            "tooltip-format" = "<tt><small>{calendar}</small></tt>";
            # "locale" = "en_GB";
            "calendar" = {
              "mode" = "year";
              "mode-mon-col" = 2;
              "weeks-pos" = "left";
              "on-scroll" = 1;
              "on-click-right" = "mode";
              "format" = {
                "months" = "<span color='#ffead3'><b>{}</b></span>";
                "days" = "<span color='#ecc6d9'><b>{}</b></span>";
                "weeks" = "<span color='#99ffdd'><b>W{}</b></span>";
                "weekdays" = "<span color='#ffcc66'><b>{}</b></span>";
                "today" = "<span color='#ff6699'><b><u>{}</u></b></span>";
              };
            };
            "actions" = {
              "on-click-right" = "mode";
              "on-click-left" = "mode";
            };
          };
        };
      };
    };

    programs.chromium.enable = true;

    programs.vscode = {
      enable = false;
    };

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
  };
}
