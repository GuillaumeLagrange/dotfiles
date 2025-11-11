{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Helper function to get sessions
  tmuxFzfGetSession = pkgs.writeShellScriptBin "tmux-fzf-get-session" ''
    sessions=$(${pkgs.tmux}/bin/tmux list-sessions -F "#{session_name}" 2>/dev/null)
    echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10
  '';

  # Tmux session manager script
  tsmScript = pkgs.writeShellScriptBin "tsm" ''
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
          cat <<EOF
    tsm - A tmux session manager

    Usage:
      tsm [SESSION_NAME]

    Description:
      - When called with an argument, attaches to the specified session if it exists,
        or creates a new session with the given name.
      - When called without an argument, prompts the user to select an existing session.

    Parameters:
      SESSION_NAME  (optional) The name of the tmux session to create or attach to.

    Examples:
      tsm             # Select and attach to an existing session using fuzzy finder.
      tsm mysession   # Attach to 'mysession' or create a new session with this name.
    EOF
          exit 0
        fi

        if [[ -n "$TMUX" ]]; then
          echo 'Already in a tmux session'
          exit 1
        fi

        if [[ -z "$1" ]]; then
          session=$(${tmuxFzfGetSession}/bin/tmux-fzf-get-session)
        else
          session="$1"
        fi

        if [[ -n "$session" ]]; then
          ${pkgs.tmux}/bin/tmux new-session -A -s "$session"
        else
          echo "No session selected"
        fi
  '';

  # Tmux session killer script
  tskScript = pkgs.writeShellScriptBin "tsk" ''
    session=$(${tmuxFzfGetSession}/bin/tmux-fzf-get-session)
    if [[ -n "$session" ]]; then
      ${pkgs.tmux}/bin/tmux kill-session -t "$session"
    fi
  '';

  tmuxStart = pkgs.writeShellScriptBin "tmux-start" ''
    tmux start-server
    echo "Tmux server started"
  '';

  # Automatically rename windows based on repository paths
  tmuxRename = pkgs.writeShellScriptBin "tmux-rename" ''
    set -euo pipefail

    # Get the session name (default to current session)
    SESSION="''${1:-$(${pkgs.tmux}/bin/tmux display-message -p '#S')}"

    # Base path to check for repositories (default to ~/codspeed)
    BASE_PATH="''${2:-$HOME/codspeed}"

    # Expand the base path
    BASE_PATH=$(eval echo "$BASE_PATH")

    echo "Renaming windows in session '$SESSION' based on repos in '$BASE_PATH'"

    # Get list of windows in the session
    ${pkgs.tmux}/bin/tmux list-windows -t "$SESSION" -F "#{window_index}" | while read -r window_index; do
      # Get the current path of the first pane in the window
      pane_path=$(${pkgs.tmux}/bin/tmux display-message -t "$SESSION:$window_index.0" -p "#{pane_current_path}")

      # Check if the path starts with the base path
      if [[ "$pane_path" == "$BASE_PATH"* ]]; then
        # Remove the base path and extract the repo name (first directory after base path)
        relative_path="''${pane_path#$BASE_PATH/}"
        repo_name=$(echo "$relative_path" | cut -d'/' -f1)

        # Only rename if we found a valid repo name
        if [[ -n "$repo_name" ]] && [[ "$repo_name" != "$relative_path" || ! "$relative_path" =~ / ]]; then
          current_name=$(${pkgs.tmux}/bin/tmux display-message -t "$SESSION:$window_index" -p "#{window_name}")
          if [[ "$current_name" != "$repo_name" ]]; then
            echo "  Window $window_index: '$current_name' -> '$repo_name'"
            ${pkgs.tmux}/bin/tmux rename-window -t "$SESSION:$window_index" "$repo_name"
          else
            echo "  Window $window_index: '$current_name' (already correct)"
          fi
        fi
      else
        current_name=$(${pkgs.tmux}/bin/tmux display-message -t "$SESSION:$window_index" -p "#{window_name}")
        echo "  Window $window_index: '$current_name' (not in $BASE_PATH, skipping)"
      fi
    done

    echo "Done!"
  '';
in
{
  options = {
    tmux.enable = lib.mkEnableOption "tmux and related configuration";
  };

  config = lib.mkIf config.tmux.enable {

    programs.tmux = {
      enable = true;
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

    wayland.windowManager.sway.config.keybindings =
      let
        modifier = "Mod4";
      in
      {
        "${modifier}+Backslash" = "kill; exec ${config.term} -e zsh -i -c tsm";
      };

    wayland.windowManager.hyprland.settings.bind = [
      "$mainMod, Backslash, exec, ${config.term} -e zsh -i -c tsm"
    ];

    programs.zsh.initContent = ''
      # Make attaching and detaching tmux sessions over ssh play nice with ssh-agent
      function update_environment_from_tmux() {
        if [ -n "''${TMUX}" ]; then
          eval "$(${pkgs.tmux}/bin/tmux show-environment -s)"
        fi
      }
      add-zsh-hook preexec update_environment_from_tmux
    '';

    home.packages = [
      tmuxFzfGetSession
      tsmScript
      tskScript
      tmuxStart
      tmuxRename
    ];
  };
}
