{
  pkgs,
  config,
  lib,
  ...
}:
let
  commands = import ./commands.nix { inherit pkgs lib config; };
in
{
  _class = "homeManager";

  # What core leaves off for a home without a screen.
  dconf.enable = true;
  stylix.targets = {
    gnome.enable = true;
    gtk.enable = true;
    gnome-text-editor.enable = true;
    nixos-icons.enable = true;
  };

  home.packages = with pkgs; [
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
    unstable.proton-pass
    unstable.proton-vpn
    qwerty-fr
    signal-desktop
    (symlinkJoin {
      name = "spotify";
      paths = [ spotify ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/spotify --unset DISPLAY
      '';
    })
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

  xdg.desktopEntries.obsidian = {
    name = "Obsidian";
    comment = "Knowledge base";
    icon = "obsidian";
    categories = [ "Office" ];
    mimeType = [ "x-scheme-handler/obsidian" ];
    settings.StartupWMClass = "md.Obsidian";
    exec = "${
      pkgs.writeShellApplication {
        name = "obsidian-focus";
        runtimeInputs = [
          pkgs.jq
          pkgs.obsidian
        ];
        text = ''
          if [[ $# -eq 0 ]] && command -v niri > /dev/null; then
            window=$(niri msg -j windows 2>/dev/null | jq -r \
              'first(.[] | select(.app_id // "" | ascii_downcase == "md.obsidian.obsidian") | .id) // empty')
            if [[ -n "$window" ]]; then
              exec niri msg action focus-window --id "$window"
            fi
          fi
          exec obsidian "$@"
        '';
      }
    }/bin/obsidian-focus %u";
  };

  xdg.terminal-exec = {
    enable = true;
    settings.default = [ "kitty.desktop" ];
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
      snakewater = {
        HostName = "snakewater.local";
        ForwardAgent = true;
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
      # Backgrounded: swayidle -w would stall until unlock.
      before-sleep = "${pkgs.procps}/bin/pgrep hyprlock || { ${commands.lock} & ${pkgs.coreutils}/bin/sleep 1; }";
    };
    timeouts =
      let
        lockTimeout = 60 * 10;
        screenOffTimeout = 10;
        suspendTimeout = 2 * lockTimeout;
        screenOffCommand = "${pkgs.niri}/bin/niri msg action power-off-monitors";
      in
      [
        {
          timeout = lockTimeout;
          command = "${commands.lock} &";
        }
        {
          timeout = lockTimeout + screenOffTimeout;
          command = "if ${pkgs.procps}/bin/pgrep hyprlock; then ${screenOffCommand}; fi";
        }
        {
          timeout = screenOffTimeout;
          command = "if ${pkgs.procps}/bin/pgrep hyprlock; then ${screenOffCommand}; fi";
        }
        {
          timeout = suspendTimeout;
          command = "${pkgs.systemd}/bin/systemctl is-active --quiet caffeine.service || ${pkgs.systemd}/bin/systemctl suspend-then-hibernate";
        }
      ];
  };

  programs.chromium.enable = true;

  programs.feh.enable = true;

  programs.vscode.enable = false;

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
}
