{ config, pkgs, ... }:
{
  imports = [
    ./options.nix
    ./hyprland.nix
  ];
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "guillaume";
  home.homeDirectory = "/home/guillaume";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "23.11"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    wev
    wl-clipboard
    fswatch
    telegram-desktop
    lazygit
    gcc
    luajitPackages.luarocks
    stylua
    lua-language-server
    nixd
    nixfmt-rfc-style
    ripgrep
    zip
    nodejs_22
    discord
    tree
    _1password-gui
    spotify
    fd
    playerctl

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;
    ".config/swappy/config" = {
      text = builtins.readFile ./swappy.conf;
    };

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  xdg.configFile = {
    "nvim" = {
      source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.config/home-manager/nvim";
    };
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. If you don't want to manage your shell through Home
  # Manager then you have to manually source 'hm-session-vars.sh' located at
  # either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh or
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/glagrange/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  home.shellAliases = {
    lg = "lazygit";
    grst = "git reset";
    grst1 = "git reset HEAD~1";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Zsh
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    oh-my-zsh = {
      enable = true;
      theme = "bira";
      plugins = [
        "git"
        "sudo"
        "npm"
        "docker"
        "rust"
        "systemd"
      ];
    };

    initExtra = ''
      bindkey '^ ' autosuggest-accept
      alias insomnia-gen="ssh charybdis 'source ~/.zshrc && cdr dev_tools/InsomniaConfig && cargo run --release -- --certs-path /home/glagrange/stockly/Main/StocklyContinuousDeployment/certificates' && scp charybdis:stockly/Main/dev_tools/InsomniaConfig/insomnia_collection.json ~/"
    '';
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.gh.enable = true;

  programs.fzf = {
    enable = true;
    tmux.enableShellIntegration = true;
  };

  programs.z-lua = {
    enable = true;
    enableAliases = true;
  };

  programs.git = {
    userEmail = "guillaume@glagrange.eu";
    userName = "Guillaume Lagrange";
  };

  # Nvim
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
  };

  wayland.windowManager.sway = {
    enable = true;
    extraConfig = builtins.readFile ./sway.config;
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
          "hyprland/mode"
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
          "format" = "  {:L%H:%M} ";
          "tooltip-format" = "<tt><small>{calendar}</small></tt>";
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
            "on-click-forward" = "tz_up";
            "on-click-backward" = "tz_down";
            "on-scroll-up" = "shift_up";
            "on-scroll-down" = "shift_down";
          };
        };
      };
    };
  };

  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        startup_mode = "Maximized";
        padding = {
          x = 0;
          y = 2;
        };
        opacity = 0.95;
      };
    };
  };

  programs.tmux = {
    enable = true;
    newSession = true;
    mouse = true;
    keyMode = "vi";
    plugins = [
      pkgs.tmuxPlugins.vim-tmux-navigator
      pkgs.tmuxPlugins.gruvbox
      pkgs.tmuxPlugins.fzf-tmux-url
    ];
  };

  programs.wofi.enable = true;

  # TODO: Include wallpapers in home-manager repo to make this pure
  # programs.wpaperd = {
  #   enable = true;
  #   settings = {
  #     default = {
  #       path = ~/documents/wallpapers;
  #       duration = "1h";
  #     };
  #   };
  # };

  services.cliphist.enable = true;

  services.swayidle = {
    enable = true;
    timeouts =
      let
        lockTimeout = 60 * 10; # 10 minutes
        screenOffTimeout = 10;
        suspendTimeout = 2 * lockTimeout;
        screenOffCommand = "swaymsg 'output * dpms off'";
        screenOnCommand = "swaymsg 'output * dpms on'";
      in
      [
        {
          timeout = lockTimeout;
          command = "PATH=/usr/bin ~/scripts/lock.sh&";
        }
        {
          timeout = lockTimeout + screenOffTimeout;
          command = "export PATH=/usr/bin && if pgrep -x swaylock; then ${screenOffCommand}; fi";
          resumeCommand = "PATH=/usr/bin ${screenOnCommand}";
        }
        {
          timeout = screenOffTimeout;
          command = "export PATH=/usr/bin && if pgrep -x swaylock; then ${screenOffCommand}; fi";
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

  programs.fastfetch.enable = true;
}
