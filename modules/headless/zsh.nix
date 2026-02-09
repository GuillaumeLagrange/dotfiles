{ pkgs, lib, ... }:
{
  config = {
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
          "globalias" # Auto expand shell aliases
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

    home.sessionVariables = {
      GLOBALIAS_FILTER_VALUES = "(l z ll ls la gco gca grbi gca! gc! gc grba grst grep)";
    };

  };
}
