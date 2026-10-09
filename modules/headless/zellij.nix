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
    { pkgs, config, ... }:
    let
      zellijFzfGetSession = pkgs.writeShellScriptBin "zellij-fzf-get-session" ''
        sessions=$(${config.programs.zellij.package}/bin/zellij list-sessions --short 2>/dev/null)
        echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10
      '';

      # Attach to a session by name, creating it if needed. Shared by zsm and
      # omp-panel, which opens a window on a session through it.
      #
      # Panes inherit the zellij server's environment, and the server inherits
      # this process's — on creation and on resurrection alike, since both start a
      # server. So a session that wt knows is attached with its root in the
      # environment, which is the only way to set it for a whole session that adds
      # nothing to the zellij config: a layout or a --config file would replace
      # what it is passed rather than extend it. wt is looked up on PATH rather
      # than pinned, so this stays usable on a host without it.
      zellijAttach = pkgs.writeShellScriptBin "zellij-attach" ''
        session="$1"
        root=""
        if command -v wt > /dev/null; then
          root=$(wt path --exact "$session" 2>/dev/null) || root=""
        fi

        if [[ -n "$root" ]]; then
          WORKSPACE_ROOT="$root" exec ${config.programs.zellij.package}/bin/zellij attach --create "$session"
        else
          exec ${config.programs.zellij.package}/bin/zellij attach --create "$session"
        fi
      '';

      ompPanel = pkgs.callPackage ./omp-panel/_package.nix {
        zellij = config.programs.zellij.package;
        inherit (config) termExec;
        attach = "${zellijAttach}/bin/zellij-attach";
      };

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
            Enter switches to the window where the session is already open, or opens
            it here if there is none; Alt+Enter opens it here even when it is open elsewhere.

        Parameters:
          SESSION_NAME  (optional) The name of the zellij session to create or attach to.

        Examples:
          zsm             # Pick a session: switch to its window, or open it here.
          zsm mysession   # Attach to 'mysession' or create a new session with this name.
        EOF
          exit 0
        fi

        if [[ -n "$ZELLIJ" ]]; then
          echo 'Already in a zellij session'
          exit 1
        fi

        if [[ -z "$1" ]]; then
          sessions=$(${config.programs.zellij.package}/bin/zellij list-sessions --short 2>/dev/null)
          picked=$(echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10 \
            --expect=alt-enter --header $'enter      go to session\nalt-enter  duplicate here')
          { read -r key; read -r session; } <<< "$picked"

          # zellij titles the terminal "<session> | <pane>", so a window showing the
          # session is found by that prefix. niri is looked up on PATH: headless
          # hosts have none and always attach.
          if [[ -n "$session" && "$key" != alt-enter ]] && command -v niri > /dev/null; then
            window=$(niri msg -j windows 2>/dev/null | ${pkgs.jq}/bin/jq -r --arg s "$session" \
              'first(.[] | select(.title == $s or (.title | startswith($s + " | "))) | .id) // empty')
            if [[ -n "$window" ]]; then
              exec niri msg action focus-window --id "$window"
            fi
          fi
        else
          session="$1"
        fi

        if [[ -z "$session" ]]; then
          echo "No session selected"
          exit 0
        fi

        exec ${zellijAttach}/bin/zellij-attach "$session"
      '';

      zskScript = pkgs.writeShellScriptBin "zsk" ''
        session=$(${zellijFzfGetSession}/bin/zellij-fzf-get-session)
        if [[ -n "$session" ]]; then
          ${config.programs.zellij.package}/bin/zellij delete-session --force "$session"
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
          config.programs.zellij.package
          muxName
        ];
        text = builtins.readFile ./zellij-rename-current.sh;
      };

      # Bound to a zellij keybind: runs with the zellij server's PATH.
      zellijCloseOtherTabs = pkgs.writeShellApplication {
        name = "zellij-close-other-tabs";
        runtimeInputs = [
          config.programs.zellij.package
          pkgs.jq
        ];
        text = builtins.readFile ./zellij-close-other-tabs.sh;
      };

      zellijFzfUrl = pkgs.writeShellApplication {
        name = "zellij-fzf-url";
        runtimeInputs = [
          config.programs.zellij.package
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

      ompFixit = pkgs.writeShellApplication {
        name = "omp-fixit";
        runtimeInputs = [
          config.programs.zellij.package
          pkgs.jq
          pkgs.gawk
          pkgs.coreutils
          pkgs.util-linux
        ];
        text = builtins.readFile ./omp-fixit.sh;
      };

      review = pkgs.writeShellApplication {
        name = "review";
        runtimeInputs = [
          config.programs.zellij.package
          zellijAttach
          (pkgs.callPackage ./reviews/_package.nix { })
          pkgs.jq
          pkgs.gawk
          pkgs.gnugrep
          pkgs.coreutils
          pkgs.util-linux
        ];
        text = builtins.readFile ./reviews/review.sh;
      };

    in
    {
      programs.zellij = {
        enable = true;
        package = pkgs.unstable.zellij;
        layouts.guiom = ./zellij-layout-guiom.kdl;
      };

      xdg.configFile."zellij/config.kdl".source = ./zellij.kdl;

      home.shellAliases = {
        z = "zellij";
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
        muxName
        zellijRenameCurrent
        zellijCloseOtherTabs
        zellijFzfUrl
        zellijAttach
        ompPanel
        ompFixit
        review
      ];
    };
}
