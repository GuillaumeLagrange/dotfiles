{
  pkgs,
  lib,
  config,
  ...
}:
let
  ssh_signing_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLfMTgL6YtQh1YfA3P//TuZk+VcZzRGiK3dbC0Y2HT0 guillaume@nixos";
in
{
  options = {
    headless.enable = lib.mkEnableOption "tools to work in a headless environment";
  };

  config = lib.mkIf config.headless.enable {
    home.packages = with pkgs; [
      gcc
      fswatch
      tig
      ripgrep
      fd
      zip
      unzip
      jq
      tree
      killall
      usbutils
      nh
      rustup
      git-absorb
      devenv

      # Nvim cross-project basics
      luajitPackages.luarocks
      stylua
      lua-language-server
      nixd
      nixfmt-rfc-style
      nodejs_22
      vscode-langservers-extracted
    ];

    xdg.configFile = {
      "nvim" = {
        source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim";
        recursive = true;
      };

      "tig/config" = {
        text = ''
          color cursor black green bold
          color title-focus black blue bold
          color title-blur black blue
        '';
      };
    };

    # Zsh
    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      history.size = 100000;
      syntaxHighlighting = {
        enable = true;
        highlighters = [ "main" ];
      };
      oh-my-zsh = {
        enable = true;
        theme = lib.mkDefault "bira";
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
        alias insomnia-gen="ssh cerberus 'source ~/.zshrc && cdr dev_tools/InsomniaConfig && cargo run --release -- --certs-path /home/guillaume/stockly/Main/StocklyContinuousDeployment/certificates' && scp cerberus:stockly/Main/dev_tools/InsomniaConfig/insomnia_collection.json ~/"

        function update_environment_from_tmux() {
          if [ -n "''${TMUX}" ]; then
            eval "$(${pkgs.tmux}/bin/tmux show-environment -s)"
          fi
        }
        add-zsh-hook preexec update_environment_from_tmux

        __tmux_fzf_get_session__() {
            session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null |
                fzf --exit-0 --height 10)
            echo "$session"
        }

        # Tmux session switcher (`tms foo` attaches to `foo` if exists, else creates it)
        tms() {
            [[ -n "$TMUX" ]] && change="switch-client" || change="attach-session"
            if [[ -n "$1" ]]; then
                if [[ "$1" == "-ask" ]]; then
                    read -r -p "New tmux session name: " session_name
                else
                    session_name="$1"
                fi
                tmux $change -t "$session_name" 2>/dev/null || \
                  (tmux new-session -d -s "$session_name" && \
                  tmux $change -t "$session_name");
                return
            fi
            session=$(eval __tmux_fzf_get_session__)
            tmux $change -t "$session" || echo "No sessions found."
        }

        # Tmux session killer
        tmk() {
            session=$(eval __tmux_fzf_get_session__)
            tmux kill-session -t "$session"
        }

        ${pkgs.fastfetch}/bin/fastfetch
      '';
    };
    home.shellAliases = {
      lg = "lazygit";
      lgl = "lazygit log";
      lgb = "lazygit branch";
      grst = "git reset";
      grst1 = "git reset HEAD~1";
    };

    programs.lazygit = {
      enable = true;
      settings = {
        gui.theme = {
          selectedLineBgColor = [ "reverse" ];
        };
      };
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

    home.file.".ssh/allowed_signers".text = "* ${ssh_signing_public_key}";
    programs.git = {
      enable = true;
      userEmail = "guillaume@glagrange.eu";
      userName = "Guillaume Lagrange";
      extraConfig = {
        commit.gpgsign = true;
        gpg.format = "ssh";
        gpg.ssh.allowedSignersFile = "~/.ssh/allowed_signers";
        user.signingkey = ssh_signing_public_key;
        log.showSignature = true;
        rebase.autosquash = true;
        absorb.autoStageIfNothingStaged = true;
        push.autoSetupRemote = true;
      };
      ignores = [
        ".envrc"
        ".direnv/*"
        "*.swp"
        ".pre-commit-config.yaml"
        ".taplo.toml"
        "Session.vim"
      ];
    };

    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
    };

    programs.tmux = {
      enable = true;
      newSession = true;
      mouse = true;
      keyMode = "vi";
      terminal = "screen-256color";
      baseIndex = 1;
      extraConfig = builtins.readFile ./tmux.conf;
      plugins = with pkgs; [
        tmuxPlugins.vim-tmux-navigator
        tmuxPlugins.gruvbox
        tmuxPlugins.tmux-fzf
        tmuxPlugins.fzf-tmux-url
        tmuxPlugins.resurrect
        {
          plugin = tmuxPlugins.continuum;
          extraConfig = "set -g @continuum-restore 'on'";
        }
      ];
    };

    programs.htop = {
      enable = true;
    };

    programs.fastfetch.enable = true;
  };
}
