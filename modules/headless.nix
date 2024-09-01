{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    headless.enable = lib.mkEnableOption "tools to work in a headless environment";
  };

  config = lib.mkIf config.headless.enable {
    home.packages = with pkgs; [
      gcc
      fswatch
      lazygit
      ripgrep
      fd
      zip
      unzip
      jq
      tree
      killall
      usbutils

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
        source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.config/home-manager/nvim";
      };
    };

    # Zsh
    programs.zsh = {
      enable = true;
      autosuggestion.enable = true;
      history.size = 100000;
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
        alias insomnia-gen="ssh charybdis 'source ~/.zshrc && cdr dev_tools/InsomniaConfig && cargo run --release -- --certs-path /home/guillaume/stockly/Main/StocklyContinuousDeployment/certificates' && scp charybdis:stockly/Main/dev_tools/InsomniaConfig/insomnia_collection.json ~/"
      '';
    };
    home.shellAliases = {
      lg = "lazygit";
      grst = "git reset";
      grst1 = "git reset HEAD~1";
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
      enable = true;
      userEmail = "guillaume@glagrange.eu";
      userName = "Guillaume Lagrange";
      extraConfig = {
        push = {
          autoSetupRemote = true;
        };
      };
      ignores = [
        ".envrc"
        ".direnv/*"
        "*.swp"
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
      extraConfig = "set -ag terminal-overrides \",xterm-256color:RGB\"";
      plugins = [
        pkgs.tmuxPlugins.vim-tmux-navigator
        pkgs.tmuxPlugins.gruvbox
        pkgs.tmuxPlugins.fzf-tmux-url
      ];
    };

    programs.htop = {
      enable = true;
    };

    programs.fastfetch.enable = true;
  };
}
