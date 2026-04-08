{
  pkgs,
  lib,
  config,
  ...
}:
let
  # Helper function to get sessions via fzf
  zellijFzfGetSession = pkgs.writeShellScriptBin "zellij-fzf-get-session" ''
    sessions=$(${pkgs.zellij}/bin/zellij list-sessions --short 2>/dev/null)
    echo "$sessions" | ${pkgs.fzf}/bin/fzf --exit-0 --height 10
  '';

  # Zellij session manager script (equivalent of tsm)
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

  # Zellij session killer script (equivalent of tsk)
  zskScript = pkgs.writeShellScriptBin "zsk" ''
    session=$(${zellijFzfGetSession}/bin/zellij-fzf-get-session)
    if [[ -n "$session" ]]; then
      ${pkgs.zellij}/bin/zellij delete-session --force "$session"
    fi
  '';
in
{
  options = {
    zellij.enable = lib.mkEnableOption "zellij and related configuration";
  };

  config = lib.mkIf config.zellij.enable {

    programs.zellij = {
      enable = true;
    };

    xdg.configFile."zellij/config.kdl".source = ./zellij.kdl;

    wayland.windowManager.sway.config.keybindings =
      let
        modifier = "Mod4";
      in
      {
        "${modifier}+bracketright" = "kill; exec ${config.term} -e zsh -i -c zsm";
      };

    wayland.windowManager.hyprland.settings.bind = [
      "$mainMod, bracketright, exec, ${config.term} -e zsh -i -c zsm"
    ];

    home.packages = [
      zellijFzfGetSession
      zsmScript
      zskScript
    ];
  };
}
