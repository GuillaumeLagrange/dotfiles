{ pkgs, ... }:
{
  _class = "homeManager";

  programs.zsh.initContent =
    # zsh
    ''
      # A zellij session attached without wt (zellij attach, the session manager) lacks
      # its WORKSPACE_ROOT: look it up by session name.
      if [[ -n "$ZELLIJ_SESSION_NAME" && ! -f "''${WORKSPACE_ROOT:-/nonexistent}/.wt/session.json" ]] &&
           (( $+commands[wt] )); then
        _wt_root=$(wt path --exact "$ZELLIJ_SESSION_NAME" 2>/dev/null)
        [[ -d "$_wt_root" ]] && export WORKSPACE_ROOT="$_wt_root"
        unset _wt_root
      fi

      # New panes open in the resolved cwd, outside the session: step back in through
      # the session's symlink to it.
      if [[ -f "''${WORKSPACE_ROOT:-/nonexistent}/.wt/session.json" && "$PWD" != $WORKSPACE_ROOT* ]]; then
        for _wt_link in "$WORKSPACE_ROOT"/*(@N); do
          _wt_target=''${_wt_link:A}
          if [[ "$PWD" == "$_wt_target" || "$PWD" == "$_wt_target"/* ]]; then
            builtin cd -- "$_wt_link''${PWD#$_wt_target}"
            break
          fi
        done
        unset _wt_link _wt_target
      fi

      # The enclosing wt session, else WORKSPACE_ROOT, else $HOME. Walks $PWD, not the
      # resolved path, which leaves the session through its symlinks.
      workspace_root() {
        local dir=$PWD
        while [[ -n "$dir" && "$dir" != "/" ]]; do
          if [[ -f "$dir/.wt/session.json" ]]; then
            print -r -- "$dir"
            return
          fi
          dir=''${dir:h}
        done
        print -r -- "''${WORKSPACE_ROOT:-$HOME}"
      }

      # cd relative to the workspace root, falling back to a fuzzy match of the first
      # component, and name the zellij tab after the repo.
      cdr() {
        local root=$(workspace_root)
        if (( $# == 0 )) || [[ -d "$root/$1" ]]; then
          cd "$root/$@" || return
        else
          local first=''${1%%/*} rest= pick
          [[ "$1" == */* ]] && rest=/''${1#*/}
          local -a matches=( "$root"/*''${(b)first}*(-/N:t) )
          if (( $#matches == 1 )); then
            pick=$matches[1]
          else
            pick=$(print -rl -- "$root"/*(-/N:t) | ${pkgs.fzf}/bin/fzf --query="$first" \
              --prompt='repo> ' --height='40%' --reverse) || return
          fi
          cd "$root/$pick$rest" || return
        fi
        if [[ -n "$ZELLIJ" ]] && (( $+commands[mux-name] )); then
          zellij action rename-tab "$(mux-name "$PWD")"
        fi
      }
      compdef '_files -W "$(workspace_root)" -/' cdr
    '';
}
