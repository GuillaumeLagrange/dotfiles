set -eu

# Delete local branches whose upstream was deleted on the remote, which is what
# happens to a PR's branch once it is merged. Squash merges leave no trace in
# local history, so the gone upstream is the only sign the work landed.
# Lists them and asks before deleting anything.
#
# Usage: git gone [-n]   (-n: list only)

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

dry_run=
[ "${1:-}" = "-n" ] && dry_run=1

git fetch --prune --quiet

doomed=()
dates=()
subjects=()
width=0
held=()
# Fields split on \001: a tab is whitespace to `read`, so an empty worktree
# field would collapse and shift the rest.
while IFS=$'\001' read -r name track worktree date subject; do
  [ "$track" = "[gone]" ] || continue
  if [ -n "$worktree" ]; then
    held+=("$name  ($worktree)")
  else
    doomed+=("$name")
    dates+=("$date")
    subjects+=("$subject")
    [ ${#name} -gt "$width" ] && width=${#name}
  fi
done < <(git for-each-ref refs/heads \
  --format='%(refname:short)%01%(upstream:track)%01%(worktreepath)%01%(committerdate:relative)%01%(subject)')

if [ ${#held[@]} -gt 0 ]; then
  echo "kept, checked out in a worktree:"
  printf '  %s\n' "${held[@]}"
  echo
fi

if [ ${#doomed[@]} -eq 0 ]; then
  echo "no branch to delete"
  exit 0
fi

echo "upstream gone:"
for i in "${!doomed[@]}"; do
  printf '  %-*s  %-14s  %s\n' "$width" "${doomed[$i]}" "${dates[$i]}" "${subjects[$i]}"
done
[ -n "$dry_run" ] && exit 0

echo
read -r -p "delete these ${#doomed[@]} branches? [y/N] " answer
case "$answer" in
  y | Y) git branch -D "${doomed[@]}" ;;
  *) echo "nothing deleted" ;;
esac
