{
  flake.modules.homeManager.gui =
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
          libnotify
          libreoffice
          pavucontrol
          playerctl
          pomodoro-gtk
          proton-pass
          protonvpn-gui
          qwerty-fr
          signal-desktop
          slack
          spotify
          telegram-desktop
          transmission-remote-gtk
          transmission_4-gtk
          vlc
          wdisplays
          wev
          wireguard-tools
          wl-clipboard

          adwaita-icon-theme

          obsidian

          # codelldb debugger
          vscode-extensions.vadimcn.vscode-lldb.adapter
        ];

        home.file = {
          ".config/swappy/config" = {
            text = builtins.readFile ./swappy.conf;
          };
        };

        stylix.enable = true;

        xdg.terminal-exec = {
          enable = true;
          settings.default = [ config.termDesktopEntry ];
        };

        gtk = {
          enable = true;
          iconTheme = {
            package = pkgs.adwaita-icon-theme;
            name = "Adwaita";
          };
        };
        services.network-manager-applet.enable = true;

        home.pointerCursor = {
          gtk.enable = true;
          x11.enable = true;
          package = pkgs.bibata-cursors;
          name = "Bibata-Modern-Classic";
          size = 16;
        };

        programs.ssh = {
          enable = true;
          enableDefaultConfig = false;
          matchBlocks = {
            gullywash = {
              hostname = "gullywash.glagrange.eu";
              port = 22;
              forwardAgent = true;
              addressFamily = "inet"; # Force IPV4
              user = "guillaume";
              remoteForwards = [
                {
                  host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
                  bind.address = "/run/user/1000/gnupg/S.gpg-agent";
                }
              ];
            };
            "*" = {
              addKeysToAgent = "yes";
              setEnv = {
                TERM = "xterm-256color";
              };
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

        programs.kitty = {
          enable = true;
          settings = {
            confirm_os_window_close = 0;
            enable_audio_bell = "no";
            window_alert_on_bell = "no";
            mouse_hide_wait = 0.5;
          };
        };

        programs.ghostty = {
          enable = true;
          settings = {
            title = "Ghostty";
            confirm-close-surface = false;
            mouse-hide-while-typing = true;
            keybind = [
              "ctrl+tab=esc:[27;5;9~"
              "ctrl+shift+tab=esc:[27;6;9~"
              "alt+one=unbind"
              "alt+two=unbind"
              "alt+three=unbind"
              "alt+four=unbind"
              "alt+five=unbind"
              "alt+six=unbind"
              "alt+seven=unbind"
              "alt+eight=unbind"
              "alt+nine=unbind"
              "alt+zero=unbind"
            ];
          };
        };

        services.swayidle = {
          enable = true;
          events = [
            {
              event = "before-sleep";
              command = "${config.lock}";
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
                command = "${config.lock} &";
              }
              {
                timeout = lockTimeout + screenOffTimeout;
                command = "if ${pkgs.procps}/bin/pgrep hyprlock; then ${screenOffCommand}; fi";
                resumeCommand = "${screenOnCommand}";
              }
              {
                timeout = screenOffTimeout;
                command = "if ${pkgs.procps}/bin/pgrep hyprlock; then ${screenOffCommand}; fi";
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
    };
}
