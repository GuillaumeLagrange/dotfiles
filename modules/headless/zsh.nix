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
        initContent = lib.mkMerge [
          #zsh
          ''
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

            # WORKSPACE_ROOT belongs to the session a pane is in, not to the
            # directory it stands in, so `cd ~` must not send cdr back to the
            # workspace. The multiplexer normally hands it down: zellij fixes a
            # pane's environment when the server starts, and zwt attaches with a
            # layout that sets it. A session attached any other way (`zellij
            # attach`, the session-manager plugin, the welcome screen) starts a
            # server that never saw it, and lands here instead — the session name
            # is the registry key, so the value can be looked up.
            if [[ -n "$ZELLIJ_SESSION_NAME" && ! -f "''${WORKSPACE_ROOT:-/nonexistent}/.zwt/session.json" ]] &&
                 (( $+commands[zwt] )); then
              _zwt_root=$(zwt path --exact "$ZELLIJ_SESSION_NAME" 2>/dev/null)
              [[ -d "$_zwt_root" ]] && export WORKSPACE_ROOT="$_zwt_root"
              unset _zwt_root
            fi

            # A new pane starts in the *resolved* cwd of the one it was opened
            # from: zellij reads it from the process, and there is nothing to tell
            # it otherwise (no OSC 7 support, and `default_cwd` overrides the cwd
            # wholesale). Inside a session that lands us in the workspace, where
            # `../<repo>` reaches the main checkout rather than the session, so
            # walk back in through the mirror symlink that leads here.
            if [[ -f "''${WORKSPACE_ROOT:-/nonexistent}/.zwt/session.json" && "$PWD" != $WORKSPACE_ROOT* ]]; then
              for _zwt_link in "$WORKSPACE_ROOT"/*(@N); do
                _zwt_target=''${_zwt_link:A}
                if [[ "$PWD" == "$_zwt_target" || "$PWD" == "$_zwt_target"/* ]]; then
                  builtin cd -- "$_zwt_link''${PWD#$_zwt_target}"
                  break
                fi
              done
              unset _zwt_link _zwt_target
            fi

            # The root everything is navigated relative to: a session directory
            # when one encloses us, else whatever re-pointed WORKSPACE_ROOT (a
            # session we are a pane of, a container, the workspace itself), else
            # $HOME.
            #
            # The walk uses $PWD rather than the resolved path on purpose. A
            # session reaches the repos it does not own through symlinks, so the
            # resolved path of one of those leads out of the session while the
            # path we walked in through still points at it.
            workspace_root() {
              local dir=$PWD
              while [[ -n "$dir" && "$dir" != "/" ]]; do
                if [[ -f "$dir/.zwt/session.json" ]]; then
                  print -r -- "$dir"
                  return
                fi
                dir=''${dir:h}
              done
              print -r -- "''${WORKSPACE_ROOT:-$HOME}"
            }

            cdr() {
              cd "$(workspace_root)/$@"
            }
            compdef '_files -W "$(workspace_root)" -/' cdr

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
          ''

          # `fnm env` gives this shell its own multishell directory and prepends it
          # to PATH. direnv's precmd hook then restores the PATH it captured when it
          # first loaded the directory — in a nested shell, one built around the
          # *parent's* multishell directory — so this shell's node vanishes and
          # `node -v` disagrees with `fnm current`. fnm only re-prepends on chpwd,
          # so nothing fixes it until you cd somewhere.
          #
          # mkAfter puts this past direnv's hook, so it is registered last and runs
          # last. It does nothing once PATH is already right.
          (lib.mkAfter
            # zsh
            ''
              _fnm_keep_on_path() {
                [[ -n "$FNM_MULTISHELL_PATH" ]] || return
                case ":$PATH:" in
                  *":$FNM_MULTISHELL_PATH/bin:"*) ;;
                  *) export PATH="$FNM_MULTISHELL_PATH/bin:$PATH" ;;
                esac
              }
              autoload -U add-zsh-hook
              add-zsh-hook precmd _fnm_keep_on_path
            ''
          )
        ];
      };

      home.sessionVariables = {
        GLOBALIAS_FILTER_VALUES = "(l z ll ls la gco gca grbi gca! gc! gc grba grst grep 1 2 3 4 5 6 7 8 9 bazel)";
      };
    };
}
