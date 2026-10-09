usage() {
  cat <<EOF
review - pick a pull request awaiting my review and open it in its own tab of the reviews session

Usage:
  review [QUERY...]

QUERY pre-fills the picker's filter. The session is the wt session "$session" (create it with
wt new): the PR's repo is turned into a worktree there if it is still a mirror symlink, and a tab
named <repo>#<number> checks the PR out and opens it in diffy. Picking a PR whose tab exists goes to
that tab.
EOF
}

session=reviews

act() {
  zellij -s "$session" action "$@"
}

# Without the session, list-clients prints the sessions that do exist instead: only rows under its
# own header are clients.
has_client() {
  act list-clients 2>/dev/null | awk 'NR == 1 && $1 != "CLIENT_ID" { exit } NR > 1 { n++ } END { exit !n }'
}

running() {
  zellij list-sessions --no-formatting 2>/dev/null | awk -v s="$session" '$1 == s && !/EXITED/ { f = 1 } END { exit !f }'
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage
  exit 0
fi

root=$(wt path --exact "$session") || {
  echo "review: no wt session $session, create it with wt new" >&2
  exit 1
}

out=$(mktemp)
reviews --out "$out" "$@" || {
  rm -f -- "$out"
  exit 0
}
IFS=$'\t' read -r repo url <"$out"
rm -f -- "$out"

if [[ ! -e "$root/$repo" ]]; then
  echo "review: $repo is not in the $session session ($root)" >&2
  exit 1
fi
if [[ -L "$root/$repo" ]]; then
  (cd -- "$root" && wt add "$repo")
fi

tab="$repo#${url##*/}"

# The checkout runs in an interactive zsh so direnv loads the repo on cd, and the pane falls back
# to a shell once nvim exits or a step fails. Diffy opens in a tab of its own: the startup tab, an
# empty [No Name], is closed behind it.
# shellcheck disable=SC2016
cmd=(--cwd "$root" -- zsh -i -c
  'cd -- "$1" && git fetch --all && gh pr checkout --force "$2" && nvim -c "Diffy branch" -c "1tabclose"; exec zsh -i'
  zsh "$repo" "$url")

# Outside a pane: zellij refuses to start a session from inside one, and actions then target the
# reviews session rather than the pane's.
pane_env=()
if [[ -n "${ZELLIJ:-}" ]]; then
  pane_env=(ZELLIJ="$ZELLIJ" ZELLIJ_SESSION_NAME="$ZELLIJ_SESSION_NAME" ZELLIJ_PANE_ID="$ZELLIJ_PANE_ID")
fi
unset ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID

shell_pane() {
  act list-panes --json 2>/dev/null | jq -er 'first(.[] | select(.is_plugin == false)) | "\(.id) \(.tab_id)"'
}

open_tab() {
  if [[ -n "${created:-}" ]]; then
    # A fresh session's lone shell tab becomes the PR's, rather than staying beside it.
    for _ in $(seq 50); do
      shell_pane >/dev/null && break
      sleep 0.1
    done
    read -r pane tab_id <<<"$(shell_pane)"
    act rename-tab-by-id "$tab_id" "$tab" >/dev/null
    act new-pane --in-place --close-replaced-pane --pane-id "terminal_$pane" --name "$tab" "${cmd[@]}" >/dev/null
  elif act query-tab-names | grep -qxF -- "$tab"; then
    act go-to-tab-name "$tab" >/dev/null
  else
    act new-tab --name "$tab" "${cmd[@]}" >/dev/null
  fi
}

# The session is ephemeral: a resurrectable one left from before is deleted rather than
# resurrected, and one this starts never serializes. Serialization is fixed by the options of the
# client that creates the server (`--create-background` drops them), so it is started by a client.
if zellij list-sessions --no-formatting 2>/dev/null | grep -q "^$session .*(EXITED"; then
  zellij delete-session "$session" >/dev/null
fi

if ! has_client; then
  if ! running; then
    created=1
  fi
  # A tab takes its size from a client: with none attached its layout fails. A temporary client
  # sizes it, and the size stays until a real client shows the tab. The server starts in the wt
  # session's root with it in its environment, as zellij-attach does.
  (cd -- "$root" && WORKSPACE_ROOT="$root" exec script -q -c "stty rows 50 cols 160; exec zellij attach --create $session options --session-serialization false" /dev/null </dev/null >/dev/null 2>&1) &
  client=$!
  trap 'kill "$client" 2>/dev/null || true' EXIT
  for _ in $(seq 50); do
    has_client && break
    sleep 0.1
  done
fi
open_tab
kill "${client:-}" 2>/dev/null || true
trap - EXIT

if [[ ${#pane_env[@]} -gt 0 ]]; then
  exec env "${pane_env[@]}" zellij action switch-session "$session"
fi

# zellij titles the terminal "<session> | <pane>": a window already showing the session is focused
# rather than attached to a second time. niri is looked up on PATH: headless hosts have none.
if command -v niri >/dev/null; then
  window=$(niri msg -j windows 2>/dev/null | jq -r --arg s "$session" \
    'first(.[] | select(.title == $s or (.title | startswith($s + " | "))) | .id) // empty')
  if [[ -n "$window" ]]; then
    exec niri msg action focus-window --id "$window"
  fi
fi

exec zellij-attach "$session"
