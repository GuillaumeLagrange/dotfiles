{
  flake.modules.homeManager.headless =
    {
      pkgs,
      pkgs-unstable,
      config,
      ...
    }:
    {
      home.packages = with pkgs; [
        btop
        fastfetch
        fd
        fnm
        fswatch
        gcc
        git-absorb
        gnumake
        jq
        just
        ripgrep
        rustup
        tig
        tree
        unzip
        zip

        # Codspeed to sort
        yubikey-manager

        # Nvim cross-project basics
        tree-sitter
        imagemagick
        lua-language-server
        yaml-language-server
        luajitPackages.luarocks
        nixd
        nixfmt-rfc-style
        pkgs-unstable.oxfmt
        stylua
        taplo
        vscode-langservers-extracted
        pkgs-unstable.copilot-language-server
        zellij

        (pkgs.callPackage ./_gitPushStack.nix { inherit pkgs; })
        (pkgs.callPackage ./_untar.nix { inherit pkgs; })
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

      home.shellAliases = {
        lg = "lazygit";
        lgl = "lazygit log";
        lgb = "lazygit branch";
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
        settings = {
          user.email = "guillaume@glagrange.eu";
          user.name = "Guillaume Lagrange";
          init.defaultBranch = "main";
          commit.gpgsign = true;
          tag.gpgsign = true;
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
