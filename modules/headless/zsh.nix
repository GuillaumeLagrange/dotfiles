{
  flake.modules.homeManager.zsh =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
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
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [ "systemd" ];
        };

        # FIXME: This is a macos specific issue
        initContent = ''
          # Prepend nix-profile to PATH so nix-managed tools take priority over
          # system ones (macOS path_helper in /etc/zprofile reorders PATH after
          # ~/.zshenv, so we must fix it here in .zshrc).
          #
          # Inside a distrobox container ($CONTAINER_ID set by distrobox-enter)
          # append instead, so container-installed tooling shadows the nix
          # profile rather than the other way around.
          if [ -n "$CONTAINER_ID" ]; then
            export PATH="$PATH:$HOME/.nix-profile/bin"
            export PATH="$PATH:$HOME/go/bin"
          else
            export PATH="$HOME/.nix-profile/bin:$PATH"
            export PATH="$HOME/go/bin:$PATH"
          fi

          bindkey '^e' autosuggest-accept

          if [[ "$TERM" == "xterm-kitty" ]]; then
            alias ssh="kitten ssh"
          fi

          export PNPM_HOME="${config.home.homeDirectory}/.local/share/pnpm"
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

            if [ -n "$CODSPEED_PROFILE" ]; then
              echo -n "🐰 $CODSPEED_PROFILE "
            fi
          }

          # Fuzzy-pick a worktree of the current repo and cd into it. The
          # displayed line carries the path in a trailing tab-delimited field so
          # fzf matches on branch/path text while the exact path (which may
          # contain spaces) survives extraction. ctrl-x removes the highlighted
          # worktree and closes the picker.
          wt () {
            command git rev-parse --git-dir >/dev/null 2>&1 || {
              echo "wt: not inside a git repository" >&2
              return 1
            }
            local selection dir
            selection=$(command git worktree list --porcelain | ${pkgs.gawk}/bin/awk '
              /^worktree / { path = substr($0, 10) }
              /^branch /   { ref = substr($0, 8); sub("refs/heads/", "", ref) }
              /^detached/  { ref = "(detached)" }
              /^bare/      { ref = "(bare)" }
              /^$/         { if (path != "") printf "%s [%s]\t%s\n", path, ref, path; path=""; ref="" }
              END          { if (path != "") printf "%s [%s]\t%s\n", path, ref, path }
            ' | ${pkgs.fzf}/bin/fzf --exit-0 --select-1 --query="$*" \
                  --delimiter='\t' --with-nth=1 --accept-nth=2 \
                  --prompt='worktree> ' --height='40%' --reverse \
                  --header='enter: cd  •  ctrl-x: remove' \
                  --bind='ctrl-x:execute-silent(git worktree remove {2})+abort') || return
            dir=$selection
            [ -n "$dir" ] && cd "$dir"
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

      home.sessionVariables = {
        GLOBALIAS_FILTER_VALUES = "(l z ll ls la gco gca grbi gca! gc! gc grba grst grep 1 2 3 4 5 6 7 8 9 bazel)";
      };
    };
}
