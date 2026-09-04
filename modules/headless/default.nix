{ self, ... }:
{
  flake.modules.homeManager.headless =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = with self.modules.homeManager; [
        claude
        tmux
        zellij
        zsh
        wt
      ];

      home.packages =
        with pkgs;
        [
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
          nh
          pkgs.unstable.prek
          ripgrep
          rustup
          sccache
          tig
          tree
          unzip
          zip

          yubikey-manager
        ]
        ++ lib.optionals stdenv.isLinux [
          killall
          pciutils
          usbutils
          yubioath-flutter
        ]
        ++ [
          # Config is managed out-of-store via xdg.configFile."nvim" → ~/dotfiles/nvim,
          # so neovim is installed as a plain package rather than through
          # programs.neovim (whose generated init.lua would collide with the symlink).
          pkgs.unstable.neovim-unwrapped
          tree-sitter
          harper
          imagemagick
          lua-language-server
          yaml-language-server
          luajitPackages.luarocks
          nixd
          nixfmt
          pkgs.unstable.oxfmt
          stylua
          taplo
          vscode-langservers-extracted
          pkgs.unstable.copilot-language-server
          zellij
          dua

          (pkgs.writeShellApplication {
            name = "git-push-stack";
            runtimeInputs = [ pkgs.git ];
            text = builtins.readFile ./git-push-stack.sh;
          })

          (pkgs.writeShellApplication {
            name = "untar";
            runtimeInputs = [
              pkgs.gnutar
              pkgs.gzip
              pkgs.bzip2
              pkgs.xz
              pkgs.zstd
            ];
            text = builtins.readFile ./untar.sh;
          })
        ];

      xdg.configFile = {
        "nvim" = {
          source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim";
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
        vi = "nvim";
        vim = "nvim";
        lg = "lazygit";
        lgl = "lazygit log";
        lgb = "lazygit branch";
        cdg = "[ -d \"$(git rev-parse --show-toplevel 2>/dev/null)\" ] && cd $(git rev-parse --show-toplevel)";
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
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        nfu = "nix flake update && nh os switch -a && gcam 'chore: update flake' ";
        scu = "systemctl --user";
        sc = "sudo systemctl";
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

      programs.fzf =
        let
          # Ignore build artifacts and caches rather than everything in .gitignore,
          # so generated-but-interesting files stay reachable.
          excludes = [
            ".git"
            ".jj"
            ".svn"
            ".hg"
            ".direnv"
            ".cache"
            ".venv"
            "venv"
            ".tox"
            ".mypy_cache"
            ".ruff_cache"
            ".pytest_cache"
            "__pycache__"
            "node_modules"
            ".pnpm-store"
            ".yarn"
            ".next"
            ".nuxt"
            ".svelte-kit"
            ".turbo"
            ".parcel-cache"
            "bower_components"
            "target"
            "build"
            "dist"
            "out"
            ".gradle"
            ".m2"
            ".terraform"
            ".angular"
            ".cargo"
            "vendor"
            "result"
            "result-*"
            "*.egg-info"
          ];
          fd =
            type:
            lib.concatStringsSep " " (
              [
                "${pkgs.fd}/bin/fd"
                "--type"
                type
                "--hidden"
                "--follow"
                "--no-ignore-vcs"
              ]
              ++ map (e: "--exclude ${lib.escapeShellArg e}") excludes
            );
        in
        {
          enable = true;
          changeDirWidgetCommand = fd "d";
          fileWidgetCommand = fd "f";
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
          diff.lfstext.textconv = "cat";
          alias.steal = "!${
            pkgs.writeShellApplication {
              name = "git-steal";
              runtimeInputs = [
                pkgs.git
                pkgs.gawk
              ];
              text = builtins.readFile ./git-steal.sh;
            }
          }/bin/git-steal";
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
          ".claude/worktrees"
        ];
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
        "$HOME/.local/bin"
      ];

      # sccache caches compiled crates in a shared dir keyed by content, so
      # deps rebuilt from scratch in each worktree hit the cache instead of
      # recompiling. It disables incremental compilation (CARGO_INCREMENTAL=0
      # is set automatically), which sccache cannot cache anyway.
      home.sessionVariables = {
        RUSTC_WRAPPER = "sccache";
        SCCACHE_CACHE_SIZE = "100G";
      };
    };
}
