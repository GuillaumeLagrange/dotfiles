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

  imports = [
    ./tmux.nix
  ];

  config = lib.mkIf config.headless.enable {
    tmux.enable = true;

    home.packages = with pkgs; [
      devenv
      fd
      fswatch
      gcc
      git-absorb
      gnumake
      jq
      killall
      nh
      ripgrep
      rustup
      tig
      tree
      unzip
      usbutils
      zip

      # Codspeed to sort
      yubioath-flutter
      yubikey-manager

      granted
      git-lfs

      # Nvim cross-project basics
      lua-language-server
      luajitPackages.luarocks
      nixd
      nixfmt-rfc-style
      nodejs_22
      stylua
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

        # Auto use poetry env
        function vim() {
          if [[ -f "pyproject.toml" ]] && poetry env info --path &>/dev/null; then
            poetry run vim "$@"
          else
            command vim "$@"
          fi
        }

        if [[ "$TERM" == "xterm-kitty" ]]; then
          alias ssh="kitten ssh"
        fi

        ${pkgs.fastfetch}/bin/fastfetch
        ${pkgs.fortune}/bin/fortune | ${pkgs.cowsay}/bin/cowsay | ${pkgs.lolcat}/bin/lolcat
      '';
    };
    home.shellAliases = {
      lg = "lazygit";
      lgl = "lazygit log";
      lgb = "lazygit branch";
      # Git aliases
      cdr = "[ -d \"$(git rev-parse --show-toplevel 2>/dev/null)\" ] && cd $(git rev-parse --show-toplevel)";
      grbim = "git rebase -i $(git_main_branch)";
      grbiom = "git rebase -i origin/$(git_main_branch)";
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
        # gpg.format = "ssh";
        gpg.ssh.allowedSignersFile = "~/.ssh/allowed_signers";
        # user.signingkey = ssh_signing_public_key;
        user.signingkey = "F2D858FB8D9616ED";
        # log.showSignature = true;
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
        ".nvim.lua"
      ];
    };

    programs.neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
    };

    programs.htop = {
      enable = true;
    };

    programs.fastfetch.enable = true;
  };
}
