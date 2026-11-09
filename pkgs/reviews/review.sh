usage() {
  cat <<EOF
review - pick a pull request awaiting my review, one I reviewed lately, or one of mine, and open it in zellij

Usage:
  review [QUERY...]
  review --pr URL
  review --mine URL BRANCH

QUERY pre-fills the picker's filter. --pr skips the picker and opens URL as if it were picked in a
review tab; --mine as if it were picked in the "my PRs" tab.

A PR to review opens in the wt session "reviews" (create it with wt new): the PR's repo is turned
into a worktree there if it is still a mirror symlink or missing from the mirror, and a tab named
<repo>#<number> checks the PR out and opens it in diffy. Picking a PR whose tab exists goes to that tab.

One of my PRs opens in the wt session that has its branch checked out in a worktree, on the repo's
tab. When none has, it opens on the repo's tab of the main checkout's session (wt main), and the
branch is checked out in the main checkout unless it has uncommitted changes.
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage
  exit 0
fi

# Run from the bar, there is no terminal to print a failure in: it becomes a notification.
errors=""
if [[ ! -t 2 ]]; then
  errors=$(mktemp)
  exec 2>"$errors"
fi
finish() {
  local status=$?
  kill "${client:-}" 2>/dev/null || true
  if [[ -n "$errors" ]]; then
    if ((status != 0)); then
      notify-send -a review "review failed" "$(tail -n 5 -- "$errors")"
    fi
    rm -f -- "$errors"
  fi
}
trap finish EXIT

# https://github.com/<owner>/<repo>/pull/<number>
repo_of() {
  local repo=${1#https://github.com/*/}
  echo "${repo%%/*}"
}

case "${1:-}" in
  --pr)
    kind=review
    url=${2:?review: --pr needs a URL}
    repo=$(repo_of "$url")
    ;;
  --mine)
    kind=mine
    url=${2:?review: --mine needs a URL}
    branch=${3:?review: --mine needs a branch}
    repo=$(repo_of "$url")
    ;;
  *)
    out=$(mktemp)
    reviews --out "$out" "$@" || {
      rm -f -- "$out"
      exit 0
    }
    IFS=$'\t' read -r kind repo url branch <"$out"
    rm -f -- "$out"
    ;;
esac

act() {
  zellij -s "$session" action "$@"
}

# Without the session, list-clients prints the sessions that do exist instead: only rows under its
# own header are clients.
has_client() {
  act list-clients 2>/dev/null | awk 'NR == 1 && $1 != "CLIENT_ID" { exit } NR > 1 { n++ } END { exit !n }'
}

exists() {
  zellij list-sessions --no-formatting 2>/dev/null | awk -v s="$session" '$1 == s { f = 1 } END { exit !f }'
}

# A running server, not one zellij only keeps to resurrect.
live() {
  zellij list-sessions --no-formatting 2>/dev/null | awk -v s="$session" '$1 == s && !/EXITED/ { f = 1 } END { exit !f }'
}

shell_pane() {
  act list-panes --json 2>/dev/null | jq -er 'first(.[] | select(.is_plugin == false)) | "\(.id) \(.tab_id)"'
}

# The tab of a repo, by the last word of its name as wt matches it (mux-name puts an icon before
# it), or a review tab of the repo (<repo>#<number>) in the reviews session.
repo_tab() {
  act list-tabs --json 2>/dev/null |
    jq -er --arg repo "$repo" 'first(.[] | select(.name | [splits("\\s+")] | map(select(. != "")) | (last // "") | . == $repo or startswith($repo + "#")) | .tab_id)'
}

if [[ "$kind" == mine ]]; then
  # The wt session holding the branch in a worktree, if any.
  session=$(wt ls --json | jq -r --arg repo "$repo" --arg branch "$branch" \
    'first(.[] | select(any(.members[]; .repo == $repo and .branch == $branch)) | .id) // empty')
  if [[ -n "$session" ]]; then
    root=$(wt path --exact "$session")
    members=1
  else
    session=$(wt main)
    root=$(wt main --path)
    checkout=1
  fi
  dir="$root/$repo"
  if [[ ! -d "$dir" ]]; then
    echo "review: no checkout of $repo in $root" >&2
    exit 1
  fi
else
  session=reviews
  root=$(wt path --exact "$session") || {
    echo "review: no wt session $session, create it with wt new" >&2
    exit 1
  }

  # A mirror symlink, or a repo the mirror lacks (cloned after the session was made), becomes a
  # worktree; wt refuses a name the workspace has no repo for.
  if [[ -L "$root/$repo" || ! -e "$root/$repo" ]]; then
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
fi

# Uncommitted work: a submodule merely at another commit than recorded is not, since
# `git submodule update` after the checkout puts it back; edits inside one are.
dirty() {
  ! git -C "$dir" diff --quiet --ignore-submodules=all ||
    ! git -C "$dir" diff --cached --quiet ||
    ! git -C "$dir" submodule --quiet foreach --recursive 'git diff --quiet && git diff --cached --quiet'
}

# Before the tab opens, so its shell starts on the branch. Uncommitted changes leave the checkout
# alone: the tab still opens, to deal with them.
if [[ -n "${checkout:-}" && "$(git -C "$dir" branch --show-current)" != "$branch" ]]; then
  if dirty; then
    notify-send -u critical -a review "$repo: uncommitted changes" "$branch is not checked out in $dir"
  elif ! (cd -- "$dir" && gh pr checkout "$url" && git submodule --quiet update --init --recursive) >&2; then
    notify-send -u critical -a review "$repo: checkout failed" "$branch is not checked out in $dir"
  fi
fi

# Outside a pane: zellij refuses to start a session from inside one, and actions then target the
# session rather than the pane's.
pane_env=()
if [[ -n "${ZELLIJ:-}" ]]; then
  pane_env=(ZELLIJ="$ZELLIJ" ZELLIJ_SESSION_NAME="$ZELLIJ_SESSION_NAME" ZELLIJ_PANE_ID="$ZELLIJ_PANE_ID")
fi
unset ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID

open_review_tab() {
  if [[ -n "${created:-}" ]]; then
    # A fresh session's lone shell tab becomes the PR's, rather than staying beside it.
    read -r pane tab_id <<<"$startup"
    act rename-tab-by-id "$tab_id" "$tab" >/dev/null
    act new-pane --in-place --close-replaced-pane --pane-id "terminal_$pane" --name "$tab" "${cmd[@]}" >/dev/null
  elif act query-tab-names | grep -qxF -- "$tab"; then
    act go-to-tab-name "$tab" >/dev/null
  else
    # Another PR of the repo shares its worktree: its tab is closed once the new one exists, so the
    # session never runs out of tabs, which would end it.
    stale=$(act list-tabs --json | jq -r --arg repo "$repo#" '.[] | select(.name | startswith($repo)) | .tab_id')
    act new-tab --name "$tab" "${cmd[@]}" >/dev/null
    for id in $stale; do
      act close-tab-by-id "$id" >/dev/null
    done
  fi
}

open_repo_tab() {
  local id lone=""
  # wt tabs already replaced a wt session's startup tab with the members'.
  if [[ -n "${created:-}" && -z "${members:-}" ]]; then
    read -r _ lone <<<"$startup"
  fi
  if id=$(repo_tab); then
    act go-to-tab-by-id "$id" >/dev/null
  else
    act new-tab --cwd "$dir" --name "$(mux-name "$dir")" >/dev/null
    # A fresh session's lone shell tab goes once the repo's exists, so the session never empties.
    if [[ -n "$lone" ]]; then
      act close-tab-by-id "$lone" >/dev/null
    fi
  fi
}

# A tab takes its size from a client: with none attached its layout fails. A temporary client
# sizes it, and the size stays until a real client shows the tab. Started again whenever it has
# exited: zellij lists a fresh server before it takes clients, and a first client can drop out.
temporary_client() {
  for _ in $(seq 100); do
    if ! kill -0 "${client:-}" 2>/dev/null; then
      (TERM=xterm-256color exec script -q -c "stty rows 50 cols 160; exec zellij attach $(printf %q "$session")" /dev/null </dev/null >/dev/null 2>&1) &
      client=$!
    fi
    has_client && return 0
    sleep 0.1
  done
  echo "review: no zellij client came up on $session" >&2
  exit 1
}

if ! has_client; then
  if ! exists; then
    created=1
  fi
  # The server is started on its own first, as wt does: forked by the temporary client, it could
  # die with that client when it is killed. It starts in the session's root with it in its
  # environment, as zellij-attach does. Panes inherit the server's TERM, unset when run from the bar.
  if ! live; then
    (cd -- "$root" && WORKSPACE_ROOT="$root" TERM=xterm-256color zellij attach --create-background "$session") >/dev/null || {
      echo "review: could not start zellij session $session" >&2
      exit 1
    }
    for _ in $(seq 100); do
      live && break
      sleep 0.1
    done
    # The client that created it can still be listed for a moment, which temporary_client would
    # take for one that sizes the tabs.
    for _ in $(seq 50); do
      has_client || break
      sleep 0.1
    done
  fi
  temporary_client
  # The startup tab's shell, which a fresh session's first tab replaces. Kept from here: zellij can
  # answer a later query with nothing.
  startup=""
  for _ in $(seq 100); do
    startup=$(shell_pane) && break
    sleep 0.1
  done
  # The members' tabs, as attaching with wt lays them out; done before a tab is picked.
  if [[ -n "${members:-}" ]]; then
    # The client can still drop out between being listed and wt asking for it; the last try's
    # error is the one reported.
    for try in 1 2 3 4 5; do
      temporary_client
      if ((try < 5)); then
        wt tabs "$session" >/dev/null 2>&1 && break
      else
        wt tabs "$session" >/dev/null
      fi
    done
  fi
  temporary_client
fi

if [[ "$kind" == mine ]]; then
  open_repo_tab
else
  open_review_tab
fi
# What follows execs, which skips the EXIT trap.
trap - EXIT
finish

if [[ ${#pane_env[@]} -gt 0 ]]; then
  exec env "${pane_env[@]}" zellij action switch-session "$session"
fi

# A window already showing the session is focused rather than attached to a second time, and run
# without a terminal (a PR clicked in the bar), the session opens in a window of its own.
exec zellij-attach --focus "$session"
