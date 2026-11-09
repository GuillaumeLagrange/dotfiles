# Attach to a zellij session by name, creating it if needed. With --focus, focus the
# window already showing it, or open one. A session wt knows starts with its
# WORKSPACE_ROOT.
{
  writeShellScriptBin,
  jq,
  zellij,
}:

writeShellScriptBin "zellij-attach" ''
  focus=""
  if [[ "$1" == --focus ]]; then
    focus=1
    shift
  fi
  session="$1"

  if [[ -n "$focus" ]] && command -v niri > /dev/null; then
    window=$(niri msg -j windows 2>/dev/null | ${jq}/bin/jq -r --arg s "$session" \
      'first(.[] | select(.title == $s or (.title | startswith($s + " | "))) | .id) // empty')
    if [[ -n "$window" ]]; then
      exec niri msg action focus-window --id "$window"
    fi
    if [[ ! -t 0 ]]; then
      exec niri msg action spawn -- xdg-terminal-exec --app-id=zellij-session "$0" "$session"
    fi
  fi

  if [[ -t 1 ]]; then
    printf '\033]2;%s\007' "$session"
  fi

  root=""
  if command -v wt > /dev/null; then
    root=$(wt path --exact "$session" 2>/dev/null) || root=""
  fi

  if [[ -n "$root" ]]; then
    WORKSPACE_ROOT="$root" exec ${zellij}/bin/zellij attach --create "$session"
  else
    exec ${zellij}/bin/zellij attach --create "$session"
  fi
''
