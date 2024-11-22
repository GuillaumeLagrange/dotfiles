{
  pkgs,
  lib,
  config,
  ...
}:
{
  options = {
    tmux.enable = lib.mkEnableOption "tmux and related configuration";
  };

  config = lib.mkIf config.tmux.enable {

    programs.tmux = {
      enable = true;
      newSession = true;
      mouse = true;
      keyMode = "vi";
      terminal = "screen-256color";
      baseIndex = 1;
      extraConfig = builtins.readFile ./tmux.conf;
      plugins = with pkgs; [
        tmuxPlugins.vim-tmux-navigator
        tmuxPlugins.gruvbox
        tmuxPlugins.tmux-fzf
        tmuxPlugins.fzf-tmux-url
        tmuxPlugins.resurrect
        {
          plugin = tmuxPlugins.continuum;
          extraConfig = "set -g @continuum-restore 'on'";
        }
      ];
    };

    programs.zsh.initExtra = ''
      # Make attaching and detaching tmux sessions over ssh play nice with ssh-agent
      function update_environment_from_tmux() {
        if [ -n "''${TMUX}" ]; then
          eval "$(${pkgs.tmux}/bin/tmux show-environment -s)"
        fi
      }
      add-zsh-hook preexec update_environment_from_tmux

      __tmux_fzf_get_session__() {
          session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null |
              fzf --exit-0 --height 10)
          echo "$session"
      }

      # Tmux session manager
      tsm() {
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
      cat <<EOF
        tsm - A tmux session manager

        Usage:
          tsm [SESSION_NAME]

        Description:
          - When called with an argument, attaches to the specified session if it exists,
            or creates a new session with the given name.
          - When called without an argument, prompts the user to select an existing session
            The selected session will be opened as an ephemeral session, sharing the windows
            and pane with the main session, but with a decoupled focus.
            This session is killed on detach.

        Parameters:
          SESSION_NAME  (optional) The name of the tmux session to create or attach to.

        Examples:
          tsm             # Select and attach to an existing session using fuzzy finder.
          tsm mysession   # Attach to 'mysession' or create a new session with this name.
      EOF
                return
            fi


        [[ -n "$TMUX" ]] && echo 'Already in a tmux session' && return

        # Call with an argument to create a permanent session, or to attach an existing one
        if [[ -n "$1" ]]; then
            tmux new-session -A -s $1
            return
        fi

        # Call without an argument to select an existing session to attach to
        # The created session will be an ephemeral session, to allow opening a single sessions
        # multiple time without coupling which window/pane is focused
        session=$(eval __tmux_fzf_get_session__)
        if [[ -n "$session" ]]; then
          tmux new-session -t $session \; set-option destroy-unattached
        else
          echo "No session selected"
        fi
      }

      # Tmux session killer
      tsk() {
        session=$(eval __tmux_fzf_get_session__)
        if [[ -n "$session" ]]; then
          tmux kill-session -t "$session"
        fi
      }
    '';
  };
}
