# Attach to a zellij session by name, creating it if needed. With --focus, focus the
# window already showing it, or open one; run so without a terminal (the bar's launcher),
# it opens the session in a window of its own. A session wt knows starts with its
# WORKSPACE_ROOT, and every session on its colour's config (zellij-sessions).
{
  writeShellScriptBin,
  jq,
  zellij,
  zellij-sessions,
}:

writeShellScriptBin "zellij-attach" ''
  focus=""
  if [[ "$1" == --focus ]]; then
    focus=1
    shift
  fi
  session="$1"

  if command -v niri > /dev/null; then
    if [[ -n "$focus" ]]; then
      window=$(niri msg -j windows 2>/dev/null | ${jq}/bin/jq -r --arg s "$session" \
        'first(.[] | select(.title == $s or (.title | startswith($s + " | "))) | .id) // empty')
      if [[ -n "$window" ]]; then
        exec niri msg action focus-window --id "$window"
      fi
    fi
    if [[ -n "$focus" && ! -t 0 ]]; then
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
    export WORKSPACE_ROOT="$root"
  fi

  # zellij's check that a session is up can fail on a live one now and then, and
  # `attach --create` would then start a second server for it (0.45 let that one
  # take the name over). So --create is only passed for a session no listing shows,
  # and an attach that finds no session is tried again.
  listed() {
    local _
    for _ in 1 2 3 4 5; do
      if [[ $'\n'"$(${zellij}/bin/zellij list-sessions --short 2>/dev/null)"$'\n' == *$'\n'"$session"$'\n'* ]]; then
        return 0
      fi
    done
    return 1
  }
  create=()
  listed || create=(--create)
  # A live session keeps the config it was started on; this one is for starting or
  # resurrecting it.
  config=()
  cfg=$(${zellij-sessions}/bin/zellij-sessions config "$session" 2>/dev/null) || cfg=""
  [[ -z "$cfg" ]] || config=(--config "$cfg")
  exec 3>&1
  for _ in 1 2 3 4 5; do
    # stderr is read to tell that case apart; the terminal keeps stdout through fd 3.
    err=$(${zellij}/bin/zellij "''${config[@]}" attach "''${create[@]}" "$session" 2>&1 1>&3)
    status=$?
    if ((status == 0)) || [[ "$err" != *"No session with the name"* ]]; then
      break
    fi
  done
  [[ -z "$err" ]] || printf '%s\n' "$err" >&2
  exit "$status"
''
