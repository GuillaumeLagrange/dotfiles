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

  tmuxAttachTmp = pkgs.writeShellScriptBin "tmux-attach-tmp" ''
    tmux new-session -t $(tmux-fzf-get-session) \; set destroy-unattached on
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

        # Transparently start the server if it's not running
        ${pkgs.tmux}/bin/tmux start-server

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

  # Automatically rename windows based on git root or current directory
  tmuxRename = pkgs.writeShellScriptBin "tmux-rename" ''
    set -euo pipefail

    # Get the session name (default to current session)
    SESSION="''${1:-$(${pkgs.tmux}/bin/tmux display-message -p '#S')}"

    echo "Renaming windows in session '$SESSION' based on git repos or current directory"

    # Get list of windows in the session
    ${pkgs.tmux}/bin/tmux list-windows -t "$SESSION" -F "#{window_index}" | while read -r window_index; do
      # Get the current path of the first pane in the window
      pane_path=$(${pkgs.tmux}/bin/tmux display-message -t "$SESSION:$window_index.0" -p "#{pane_current_path}")

      # Try to find git root from the pane's current path
      git_root=$(cd "$pane_path" 2>/dev/null && ${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo "")

      # Use git root if found, otherwise use the pane's current path
      display_path="''${git_root:-$pane_path}"

      # Convert to use ~ if it's under $HOME
      if [[ "$display_path" == "$HOME"* ]]; then
        display_path="~''${display_path#$HOME}"
      fi

      # Get the current window name
      current_name=$(${pkgs.tmux}/bin/tmux display-message -t "$SESSION:$window_index" -p "#{window_name}")

      # Rename the window if different
      if [[ "$current_name" != "$display_path" ]]; then
        echo "  Window $window_index: '$current_name' -> '$display_path'"
        ${pkgs.tmux}/bin/tmux rename-window -t "$SESSION:$window_index" "$display_path"
      else
        echo "  Window $window_index: '$current_name' (already correct)"
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
      terminal = "tmux-256color";
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
      tmuxAttachTmp
      tskScript
      tmuxRename
    ];
  };
}
