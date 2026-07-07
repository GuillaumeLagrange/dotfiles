{ self, ... }:
{
  flake.modules.nixos.gui = {
    imports = with self.modules.nixos; [
      niri
      sway
    ];

    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };

    xdg.portal.enable = true;
  };

  flake.modules.homeManager.gui =
    { pkgs, config, ... }:
    {
      imports = with self.modules.homeManager; [
        monitors
        brightness
        screen-tools
        browsers
        audio
        lock
        firefox
        waybar
        vicinae
        niri
        sway
      ];

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
        proton-vpn
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
      ];

      home.file = {
        ".config/swappy/config" = {
          text = builtins.readFile ./swappy.conf;
        };
      };

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
        settings = {
          gullywash = {
            HostName = "gullywash.glagrange.eu";
            Port = 22;
            ForwardAgent = true;
            AddressFamily = "inet";
            User = "guillaume";
            RemoteForward = [
              {
                host.address = "/run/user/1000/gnupg/S.gpg-agent.extra";
                bind.address = "/run/user/1000/gnupg/S.gpg-agent";
              }
            ];
          };
          "*" = {
            AddKeysToAgent = "yes";
            SetEnv = {
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
        keybindings = {
          # Always emit the CSI-u sequence for Shift+Enter so Claude Code sees a
          # newline even inside tmux (which otherwise collapses it to plain Enter).
          "shift+enter" = "send_text all \\x1b[13;2u";
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
        events = {
          before-sleep = "${config.lock}";
        };
        timeouts =
          let
            lockTimeout = 60 * 10;
            screenOffTimeout = 10;
            suspendTimeout = 2 * lockTimeout;
            screenOffCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms off' || ${pkgs.niri}/bin/niri msg action power-off-monitors";
            screenOnCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on'";
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

      programs.vscode.enable = false;

      services.mako = {
        enable = true;
        settings = {
          default-timeout = 10000;

          "app-name=Slack" = {
            invisible = 1;
          };

          "mode=do-not-disturb" = {
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
}
