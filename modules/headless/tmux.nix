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
    ];
  };
}
