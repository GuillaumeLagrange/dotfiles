set -eu

# Check out a branch that another worktree is holding.
#
# git allows a branch in one worktree at a time and offers no way to release it
# from elsewhere: the holder has to check out something else. Detaching it does
# exactly that and nothing more — same commit, same files, same untracked
# changes — so the branch becomes free without disturbing the work there.
#
# Usage: git steal <branch>

# git exports GIT_DIR (and friends) to `!` aliases, pointing at the worktree the
# alias was invoked from, and that beats `git -C`: leaving it set makes the
# detach below land on us instead of the holder. Aliases already run from the top
# level of the current worktree, so plain discovery finds the same repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

branch="${1:?usage: git steal <branch>}"

here=$(git rev-parse --show-toplevel)
holder=$(git worktree list --porcelain | awk -v want="branch refs/heads/$branch" '
  /^worktree / { path = substr($0, 10) }
  $0 == want   { print path; exit }
')

if [ -n "$holder" ] && [ "$holder" != "$here" ]; then
  echo "detaching $holder (it was holding $branch)" >&2
  git -C "$holder" switch --detach
fi

git switch "$branch"
