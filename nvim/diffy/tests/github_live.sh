#!/usr/bin/env bash
# make test-gh (contract §11.4/§12.7): live GitHub scenarios against the
# real sandbox repo GuillaumeLagrange/diffy-tests. Opt-in only, never runs
# from `make test`. Pushes the standard history to a fresh, uniquely-named
# branch pair, opens a PR, runs the scenarios through the *real* `gh`
# transport (no fake), then closes the PR and deletes the branches -
# always, even on failure (the trap below).
set -uo pipefail

REPO="GuillaumeLagrange/diffy-tests"
RUN_ID="$(date +%s)-$$"
export DIFFY_TESTGH_BASE="test-gh-base-${RUN_ID}"
export DIFFY_TESTGH_HEAD="test-gh-head-${RUN_ID}"
DIFFY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DIFFY_TESTGH_WORK="$(mktemp -d)"
export DIFFY_TESTGH_REPO="$REPO"
PR_NUMBER=""

cleanup() {
  set +e
  if [ -n "$PR_NUMBER" ]; then
    gh pr close "$PR_NUMBER" --repo "$REPO" --delete-branch=false >/dev/null 2>&1
  fi
  if [ -d "$DIFFY_TESTGH_WORK/repo" ]; then
    git -C "$DIFFY_TESTGH_WORK/repo" push -q origin --delete "$DIFFY_TESTGH_BASE" >/dev/null 2>&1
    git -C "$DIFFY_TESTGH_WORK/repo" push -q origin --delete "$DIFFY_TESTGH_HEAD" >/dev/null 2>&1
  fi
  rm -rf "$DIFFY_TESTGH_WORK"
}
trap cleanup EXIT

echo "diffy: test-gh — building standard history in $DIFFY_TESTGH_WORK" >&2
nvim --headless --noplugin -u "$DIFFY_ROOT/tests/minimal_init.lua" -c "luafile $DIFFY_ROOT/tests/github_live_build.lua" -c "qa!"
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "diffy: test-gh — FAILED (build step)" >&2
  exit 1
fi

echo "diffy: test-gh — opening PR ${DIFFY_TESTGH_BASE}..${DIFFY_TESTGH_HEAD}" >&2
PR_URL=$(gh pr create --repo "$REPO" --base "$DIFFY_TESTGH_BASE" --head "$DIFFY_TESTGH_HEAD" \
  --title "diffy test-gh smoke run ${RUN_ID}" \
  --body "Automated smoke run from \`make test-gh\`. Safe to ignore/close.")
PR_NUMBER=$(basename "$PR_URL")
export DIFFY_TESTGH_PR="$PR_NUMBER"
echo "diffy: test-gh — PR #$PR_NUMBER" >&2

echo "diffy: test-gh — running live scenarios" >&2
nvim --headless --noplugin -u "$DIFFY_ROOT/tests/minimal_init.lua" -c "luafile $DIFFY_ROOT/tests/github_live_run.lua" -c "qa!"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  echo "diffy: test-gh — PASSED" >&2
else
  echo "diffy: test-gh — FAILED" >&2
fi
exit "$STATUS"
