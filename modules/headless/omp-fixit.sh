usage() {
  cat <<EOF
omp-fixit - hand a prompt to an interactive omp, in its own tab of a background zellij session

Usage:
  omp-fixit [-s SESSION] [-c CONTEXT_FILE] NAME DIR PROMPT

  NAME     tab and omp session title (OMP_FIXIT, see ai/omp/extensions/fixit.ts)
  DIR      directory omp starts in
  PROMPT   the task; '-' reads it from stdin

Options:
  -s, --session SESSION     zellij session to run in (default: fixit)
  -c, --context FILE        a file describing the state the task was sent from; its path is
                            appended to the prompt

Attach to the session to watch or step in, or pick the omp in omp-panel.
EOF
}

session=fixit
context=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  -s | --session)
    session="$2"
    shift 2
    ;;
  -c | --context)
    context="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    usage >&2
    exit 2
    ;;
  *) break ;;
  esac
done
if [[ $# -ne 3 ]]; then
  usage >&2
  exit 2
fi
name="$1"
dir="$2"
prompt="$3"
if [[ "$prompt" == - ]]; then
  prompt=$(cat)
fi
if [[ -n "$context" ]]; then
  prompt+=$'\n\n'"State captured when this task was sent: $context"
fi

# Outside a pane: zellij refuses to create a session from inside one. Without OMPCODE: the pane's
# omp would take itself for a nested one and hide from omp-panel.
unset ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID OMPCODE

act() {
  zellij -s "$session" action "$@"
}

# `$@` every 100ms until it succeeds, for up to 5s
wait_for() {
  local what="$1"
  shift
  for _ in $(seq 50); do
    if "$@"; then
      return 0
    fi
    sleep 0.1
  done
  echo "omp-fixit: $what $session timed out after 5s" >&2
  return 1
}

shell_pane() {
  act list-panes --json 2>/dev/null | jq -er 'first(.[] | select(.is_plugin == false)) | "\(.id) \(.tab_id)"'
}

clients() {
  act list-clients 2>/dev/null | awk 'NR > 1' | wc -l
}

has_client() {
  [[ $(clients) -gt 0 ]]
}

cmd=(--cwd "$dir" -- env "OMP_FIXIT=$name" omp --auto-approve "$prompt")

if zellij attach --create-background "$session" >/dev/null 2>&1; then
  # A new session's first tab is sized 50x50: replace its shell once it's laid out (an in-place
  # pane opened before is lost).
  wait_for "waiting for the shell of" shell_pane >/dev/null
  read -r pane tab <<<"$(shell_pane)"
  act rename-tab --tab-id "$tab" "$name" >/dev/null
  act new-pane --in-place --close-replaced-pane --pane-id "terminal_$pane" --name "$name" "${cmd[@]}" >/dev/null
elif has_client; then
  act new-tab --no-focus --name "$name" "${cmd[@]}" >/dev/null
else
  # Any other tab takes its size from a client: with none attached, its layout fails and the
  # command runs without a pane, unseen by omp-panel. A temporary client sizes it; the size stays
  # after it leaves, until a real client shows the tab.
  script -q -c "stty rows 50 cols 160; exec zellij attach $(printf %q "$session")" /dev/null </dev/null >/dev/null 2>&1 &
  client=$!
  trap 'kill "$client" 2>/dev/null || true' EXIT
  wait_for "attaching a client to" has_client
  # focused, so the temporary client doesn't leave another omp's pane marked as seen in omp-panel
  act new-tab --name "$name" "${cmd[@]}" >/dev/null
fi
echo "$session"
