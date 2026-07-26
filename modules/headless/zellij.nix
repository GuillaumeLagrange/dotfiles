{ lib, ... }:
{
  # Reflavour zellij's accent (the selected ribbon/tab and frame) to `accent`,
  # a colour from stylix's palette. Everything else in the theme is left
  # untouched so it stays coherent. Import the result into a home config, e.g.
  #   (self.lib.zellij.accentTheme config.lib.stylix.colors.withHashtag.base0D)
  flake.lib.zellij.accentTheme = accent: {
    programs.zellij.themes.stylix.themes.default = {
      ribbon_selected.background = lib.mkForce accent;
      frame_selected.base = lib.mkForce accent;
      table_title.base = lib.mkForce accent;
    };
  };

  flake.modules.homeManager.zellij =
    { pkgs, ... }:
    let
      zellijFzfGetSession = pkgs.writeShellScriptBin "zellij-fzf-get-session" ''
        sessions=$(${pkgs.zellij}/bin/zellij list-sessions --short 2>/dev/null)
        echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10
      '';

      zsmScript = pkgs.writeShellScriptBin "zsm" ''
        if [[ "$1" == "-h" || "$1" == "--help" ]]; then
          cat <<EOF
        zsm - A zellij session manager

        Usage:
          zsm [SESSION_NAME]

        Description:
          - When called with an argument, attaches to the specified session if it exists,
            or creates a new session with the given name.
          - When called without an argument, prompts the user to select an existing session.

        Parameters:
          SESSION_NAME  (optional) The name of the zellij session to create or attach to.

        Examples:
          zsm             # Select and attach to an existing session using fuzzy finder.
          zsm mysession   # Attach to 'mysession' or create a new session with this name.
        EOF
          exit 0
        fi

        if [[ -n "$ZELLIJ" ]]; then
          echo 'Already in a zellij session'
          exit 1
        fi

        if [[ -z "$1" ]]; then
          session=$(${zellijFzfGetSession}/bin/zellij-fzf-get-session)
        else
          session="$1"
        fi

        if [[ -n "$session" ]]; then
          ${pkgs.zellij}/bin/zellij attach --create "$session"
        else
          echo "No session selected"
        fi
      '';

      zskScript = pkgs.writeShellScriptBin "zsk" ''
        session=$(${zellijFzfGetSession}/bin/zellij-fzf-get-session)
        if [[ -n "$session" ]]; then
          ${pkgs.zellij}/bin/zellij delete-session --force "$session"
        fi
      '';

      muxName = pkgs.writeShellApplication {
        name = "mux-name";
        runtimeInputs = [ pkgs.git ];
        text = builtins.readFile ./mux-name.sh;
      };

      # Bound to a zellij keybind, so it runs with the zellij server's PATH rather
      # than an interactive shell's: every command it calls has to be listed here.
      zellijRenameCurrent = pkgs.writeShellApplication {
        name = "zellij-rename-current";
        runtimeInputs = [
          pkgs.zellij
          muxName
        ];
        text = builtins.readFile ./zellij-rename-current.sh;
      };

      zellijFzfUrl = pkgs.writeShellApplication {
        name = "zellij-fzf-url";
        runtimeInputs = [
          pkgs.zellij
          pkgs.fzf
          pkgs.jq
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.coreutils
          pkgs.xdg-utils
        ];
        text = builtins.readFile ./zellij-fzf-url.sh;
      };

    in
    {
      programs.zellij.enable = true;

      xdg.configFile."zellij/config.kdl".source = ./zellij.kdl;
      xdg.configFile."zellij/resurrect-wrap.sh" = {
        source = ./zellij-resurrect-wrap.sh;
        executable = true;
      };
      xdg.configFile."zellij/resurrect-launch.sh" = {
        source = ./zellij-resurrect-launch.sh;
        executable = true;
      };

      programs.zsh.initContent = ''
        # Keep SSH agent working across Zellij reattaches via a stable symlink
        if [ -n "$SSH_CONNECTION" ] && [ -n "$SSH_AUTH_SOCK" ]; then
          if [ -S "$SSH_AUTH_SOCK" ] && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/ssh_auth_sock" ]; then
            ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/ssh_auth_sock"
          fi
          export SSH_AUTH_SOCK="$HOME/.ssh/ssh_auth_sock"
        fi
      '';

      home.packages = [
        zellijFzfGetSession
        zsmScript
        zskScript
        zellijRenameCurrent
        zellijFzfUrl
      ];
    };
}
