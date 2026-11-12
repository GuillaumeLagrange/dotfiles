{
  pkgs,
  config,
  lib,
  ...
}:
{
  _class = "homeManager";

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

    initContent = lib.mkMerge [
      #zsh
      ''
        # nix tools before system ones, set here because macOS's path_helper reorders
        # PATH after .zshenv; after them inside a distrobox container.
        if [ -n "$CONTAINER_ID" ]; then
          export PATH="$PATH:$HOME/.nix-profile/bin"
          export PATH="$PATH:$HOME/go/bin"
        else
          export PATH="$HOME/.nix-profile/bin:$PATH"
          export PATH="$HOME/go/bin:$PATH"
        fi

        bindkey '^e' autosuggest-accept

        autoload -Uz add-zsh-hook
        _osc133_precmd() { print -n "\e]133;D;$?\a\e]133;A\a" }
        _osc133_preexec() { print -n "\e]133;C\a" }
        add-zsh-hook precmd _osc133_precmd
        add-zsh-hook preexec _osc133_preexec

        zmodload zsh/zselect
        copy-buffer-to-clipboard() {
          [[ -n "$BUFFER" ]] || return
          local encoded
          encoded=$(print -rn -- "$BUFFER" \
            | ${pkgs.coreutils}/bin/base64 \
            | ${pkgs.coreutils}/bin/tr -d '\n')
          printf '\e]52;c;%s\a' "$encoded" > /dev/tty
          region_highlight+=("0 ''${#BUFFER} standout")
          zle -R
          zselect -t 12
          region_highlight[-1]=()
          zle -R
        }
        zle -N copy-buffer-to-clipboard
        bindkey '^[w' copy-buffer-to-clipboard

        # A function, not an alias, so ssh keeps zsh's _ssh completion: kitten's own
        # completer errors out on oh-my-zsh's anchored matchers (r:|=*, l:|=*).
        if [[ "$TERM" == "xterm-kitty" ]]; then
          ssh() { kitten ssh "$@" }
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

      ''
      #zsh
      ''

        # Pick a worktree of the repo and cd into it; ctrl-x removes it. Replaces
        # oh-my-zsh's `gwt` alias.
        unalias gwt 2> /dev/null
        gwt () {
          command git rev-parse --git-dir >/dev/null 2>&1 || {
            echo "gwt: not inside a git repository" >&2
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

        _git-steal() {
          _arguments ':branch:__git_branch_names'
        }

        # oh-my-zsh's `gcm` fails when another worktree holds the branch; steal it.
        unalias gcm 2> /dev/null
        gcm () {
          local branch
          branch=$(git_main_branch) || return
          command git steal "$branch"
        }


        eval "$(${pkgs.fnm}/bin/fnm env --use-on-cd --version-file-strategy recursive --shell zsh)"
      ''

      # Put this shell's node back on PATH after direnv's hook restores a PATH from a
      # parent shell's fnm. mkAfter: runs after direnv's hook.
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
}
