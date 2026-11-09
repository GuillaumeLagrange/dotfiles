{ pkgs, config, ... }:
let
  zellijFzfGetSession = pkgs.writeShellScriptBin "zellij-fzf-get-session" ''
    sessions=$(${config.programs.zellij.package}/bin/zellij list-sessions --short 2>/dev/null)
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

    focus=""
    if [[ -z "$1" ]]; then
      sessions=$(${config.programs.zellij.package}/bin/zellij list-sessions --short 2>/dev/null)
      picked=$(echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10 \
        --expect=alt-enter --header $'enter      go to session\nalt-enter  duplicate here')
      { read -r key; read -r session; } <<< "$picked"
      if [[ "$key" != alt-enter ]]; then
        focus=--focus
      fi
    else
      session="$1"
    fi

    if [[ -z "$session" ]]; then
      echo "No session selected"
      exit 0
    fi

    exec ${pkgs.zellij-attach}/bin/zellij-attach $focus "$session"
  '';

  zskScript = pkgs.writeShellScriptBin "zsk" ''
    session=$(${zellijFzfGetSession}/bin/zellij-fzf-get-session)
    if [[ -n "$session" ]]; then
      ${config.programs.zellij.package}/bin/zellij delete-session --force "$session"
    fi
  '';

  # Run from zellij keybinds, with the zellij server's PATH: list every command they call.
  zellijRenameCurrent = pkgs.writeShellApplication {
    name = "zellij-rename-current";
    runtimeInputs = [
      config.programs.zellij.package
      pkgs.mux-name
    ];
    text = builtins.readFile ./zellij-rename-current.sh;
  };

  zellijCloseOtherTabs = pkgs.writeShellApplication {
    name = "zellij-close-other-tabs";
    runtimeInputs = [
      config.programs.zellij.package
      pkgs.jq
    ];
    text = builtins.readFile ./zellij-close-other-tabs.sh;
  };

  zellijCloseOtherPanes = pkgs.writeShellApplication {
    name = "zellij-close-other-panes";
    runtimeInputs = [
      config.programs.zellij.package
      pkgs.jq
    ];
    text = builtins.readFile ./zellij-close-other-panes.sh;
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
in
{
  _class = "homeManager";

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
    pkgs.mux-name
    zellijRenameCurrent
    zellijCloseOtherTabs
    zellijCloseOtherPanes
    zellijFzfUrl
    pkgs.zellij-attach
    pkgs.omp-panel
    ompFixit
  ];
}
