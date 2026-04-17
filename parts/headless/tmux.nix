{
  flake.modules.homeManager.headless-tmux =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      tmuxFzfGetSession = pkgs.writeShellScriptBin "tmux-fzf-get-session" ''
        sessions=$(${pkgs.tmux}/bin/tmux list-sessions -F "#{session_name}" 2>/dev/null)
        echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10
      '';

      tmuxAttachTmp = pkgs.writeShellScriptBin "tmux-attach-tmp" ''
        tmux new-session -t $(tmux-fzf-get-session) \; set destroy-unattached on
      '';

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

      tskScript = pkgs.writeShellScriptBin "tsk" ''
        session=$(${tmuxFzfGetSession}/bin/tmux-fzf-get-session)
        if [[ -n "$session" ]]; then
          ${pkgs.tmux}/bin/tmux kill-session -t "$session"
        fi
      '';

      tmuxWindowName = pkgs.writeShellScriptBin "tmux-window-name" (
        builtins.replaceStrings [ "@git@" ] [ "${pkgs.git}/bin/git" ] (
          builtins.readFile ./tmux-window-name.sh
        )
      );

      tmuxRename = pkgs.writeShellScriptBin "tmux-rename" (
        builtins.replaceStrings
          [
            "@tmux@"
            "@tmux-window-name@"
          ]
          [
            "${pkgs.tmux}/bin/tmux"
            "${tmuxWindowName}/bin/tmux-window-name"
          ]
          (builtins.readFile ./tmux-rename.sh)
      );

      tmuxRenameCurrent = pkgs.writeShellScriptBin "tmux-rename-current" (
        builtins.replaceStrings
          [
            "@tmux@"
            "@tmux-window-name@"
          ]
          [
            "${pkgs.tmux}/bin/tmux"
            "${tmuxWindowName}/bin/tmux-window-name"
          ]
          (builtins.readFile ./tmux-rename-current.sh)
      );
    in
    {
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

      wayland.windowManager.sway.config.keybindings = lib.mkIf pkgs.stdenv.isLinux (
        let
          modifier = "Mod4";
        in
        {
          "${modifier}+Backslash" = "kill; exec ${config.term} -e zsh -i -c tsm";
        }
      );

      wayland.windowManager.hyprland.settings.bind = lib.mkIf pkgs.stdenv.isLinux [
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

        # Auto-rename tmux window on directory change
        function tmux_rename_current_window() {
          if [ -n "''${TMUX}" ]; then
            ${tmuxRenameCurrent}/bin/tmux-rename-current > /dev/null 2>&1
          fi
        }
        add-zsh-hook chpwd tmux_rename_current_window
      '';

      home.packages = [
        tmuxFzfGetSession
        tsmScript
        tmuxAttachTmp
        tskScript
        tmuxWindowName
        tmuxRename
        tmuxRenameCurrent
      ];
    };
}
