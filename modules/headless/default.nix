{
  pkgs,
  pkgs-unstable,
  lib,
  config,
  ...
}:
{
  options = {
    headless.enable = lib.mkEnableOption "tools to work in a headless environment";
  };

  imports = [
    ./tmux.nix
  ];

  config = lib.mkIf config.headless.enable {
    tmux.enable = true;

    home.packages = with pkgs; [
      btop
      devenv
      fastfetch
      fd
      fnm
      fswatch
      gcc
      git-absorb
      gnumake
      jq
      just
      killall
      nh
      pciutils
      ripgrep
      rustup
      tig
      tree
      unzip
      usbutils
      zip

      # Codspeed to sort
      yubikey-manager
      yubioath-flutter

      # Nvim cross-project basics
      imagemagick
      lua-language-server
      luajitPackages.luarocks
      nixd
      nixfmt-rfc-style
      # nodePackages_latest.prettier # Markdown formatting
      stylua
      taplo
      vscode-langservers-extracted
      pkgs-unstable.copilot-language-server

      (pkgs.callPackage ./gitPushStack.nix {
        inherit pkgs lib config;
      })

      (pkgs.callPackage ./untar.nix {
        inherit pkgs;
      })

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
          "npm"
          "docker"
          "rust"
          "systemd"
        ];
      };
      initContent = ''
        bindkey '^ ' autosuggest-accept

        if [[ "$TERM" == "xterm-kitty" ]]; then
          alias ssh="kitten ssh"
        fi

        export PNPM_HOME="/home/guillaume/.local/share/pnpm"
        case ":$PATH:" in
          *":$PNPM_HOME:"*) ;;
          *) export PATH="$PNPM_HOME:$PATH" ;;
        esac

        function virtualenv_prompt_info() {
          if [ -n "$CONTAINER_ID" ]; then
            echo -n "📦 $CONTAINER_ID "
          fi

          if [ -n "$CODSPEED_RUNNER_MODE" ]; then
            echo -n "🐇 $CODSPEED_RUNNER_MODE "
          fi

          if [ -n "$CODSPEED_CONFIG_NAME" ]; then
            echo -n "🐰 $CODSPEED_CONFIG_NAME "
          fi
        }

        # Override oh-my-zsh to look for `GIT_MAIN_BRANCH` env var first
        git_main_branch () {
          command git rev-parse --git-dir &> /dev/null || return
          local ref
          for ref in refs/{heads,remotes/{origin,upstream}}/{''${GIT_MAIN_BRANCH:-main},trunk,mainline,default,stable,master}
          do
                  if command git show-ref -q --verify $ref
                  then
                          echo ''${ref:t}
                          return 0
                  fi
          done
          echo master
          return 1
        }


        eval "$(${pkgs.fnm}/bin/fnm env --use-on-cd --version-file-strategy recursive --shell zsh)"
      '';
    };

    home.shellAliases = {
      nfu = "nix flake update && nh os switch -a && nh home switch && gcam 'chore: update flake' ";
      lg = "lazygit";
      lgl = "lazygit log";
      lgb = "lazygit branch";
      # Git aliases
      cdr = "[ -d \"$(git rev-parse --show-toplevel 2>/dev/null)\" ] && cd $(git rev-parse --show-toplevel)";
      grbim = "git rebase -i $(git_main_branch)";
      "grbim!" = "git rebase --autosquash -i $(git_main_branch)";
      grbiom = "git rebase -i origin/$(git_main_branch)";
      "grbiom!" = "git rebase --autosquash -i origin/$(git_main_branch)";
      grst = "git reset";
      grst1 = "git reset HEAD~1";
      gunwip = ''
        while git rev-list --max-count=1 --format="%s" HEAD | grep -q "\--wip--"; do
          git reset HEAD~1
        done
      '';
      dc = "docker-compose";
      tarc = "tar -czf";
    };

    programs.lazygit = {
      enable = true;
      settings = {
        gui.theme = {
          selectedLineBgColor = [ "reverse" ];
        };
      };
    };
    programs.lazydocker.enable = true;

    programs.bash.enable = true;

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.gh = {
      enable = true;
      settings.aliases = {
        co = "pr checkout";
        pv = "pr view -w";
        pc = "pr create -w";
        rv = "repo view -w";
      };
    };

    programs.fzf = {
      enable = true;
      changeDirWidgetCommand = "${pkgs.fd}/bin/fd --type d --hidden --follow --exclude .git";
      fileWidgetCommand = "${pkgs.fd}/bin/fd --type f --hidden --follow --exclude .git";
    };

    programs.atuin = {
      enable = true;
      enableZshIntegration = true;
      settings = {
        enter_accept = true;
        filter_mode = "host";
        filter_mode_shell_up_key_binding = "session";
      };
    };

    programs.z-lua = {
      enable = true;
      enableAliases = true;
    };

    programs.git = {
      enable = true;
      lfs.enable = true;
      userEmail = "guillaume@glagrange.eu";
      userName = "Guillaume Lagrange";
      extraConfig = {
        init.defaultBranch = "main";
        commit.gpgsign = true;
        user.signingkey = "F2D858FB8D9616ED";
        absorb.autoStageIfNothingStaged = true;
        absorb.oneFixupPerCommit = true;
        absorb.maxStack = 50;
        push.autoSetupRemote = true;
        rebase.updateRefs = true;
        diff.lfstext.textconv = "cat"; # Codspeed
      };
      ignores = [
        ".envrc"
        ".direnv/*"
        "*.swp"
        ".pre-commit-config.yaml"
        ".taplo.toml"
        "Session.vim"
        ".nvim.lua"
        ".claude/settings.local.json"
      ];
    };

    programs.neovim = {
      enable = true;
      package = pkgs-unstable.neovim-unwrapped;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
    };

    programs.gpg = {
      enable = true;
      publicKeys = [
        { source = ./guiom.pub.gpg; }
      ];
    };

    programs.htop = {
      enable = true;
    };

    programs.fastfetch.enable = true;

    home.sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.local/bin" # uv tools
    ];
  };
}
