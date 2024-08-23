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
      zip
      tree
      killall

      # Nvim management
      luajitPackages.luarocks
      stylua
      lua-language-server
      nixd
      nixfmt-rfc-style
      nodejs_22
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
      plugins = [
        pkgs.tmuxPlugins.vim-tmux-navigator
        pkgs.tmuxPlugins.gruvbox
        pkgs.tmuxPlugins.fzf-tmux-url
      ];
    };

    programs.htop = {
      enable = true;
      settings = {
        hide_kernel_threads = true;
        hide_userland_threads = true;
        tree_view = 1;
        delay = 30;
      };
    };

    programs.fastfetch.enable = true;
  };
}
