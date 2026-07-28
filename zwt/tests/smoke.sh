#!/usr/bin/env bash
# End-to-end smoke test for zwt against a throwaway workspace.
set -u

ROOT=$(mktemp -d /tmp/zwt-smoke.XXXXXX)
export ZWT_WORKSPACE="$ROOT/ws"
export XDG_STATE_HOME="$ROOT/state"
export XDG_CONFIG_HOME="$ROOT/config"
export XDG_RUNTIME_DIR="$ROOT/run"
mkdir -p "$ZWT_WORKSPACE" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
ZWT=/home/guillaume/dotfiles/zwt/target/debug/zwt

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*"; FAILED=1; }
ok()   { printf '  ok: %s\n' "$*"; }
FAILED=0

# Assert a command fails and says why.
expect_err() {
  pattern="$1"; shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then fail "expected '$*' to fail"; return; fi
  case "$out" in
    *"$pattern"*) ok "refused with '$pattern'" ;;
    *) fail "expected '$pattern' in: $out" ;;
  esac
}

# --- a throwaway multi-repo workspace -----------------------------------------
cd "$ZWT_WORKSPACE"
# Stands in for `use flake ./flake`: something a real direnv can load, so the
# session's own .envrc can be checked end to end.
printf 'export FROM_WORKSPACE=1\n' > .envrc
printf 'ignored-by-name\n' > .gitignore
mkdir -p other flake
for repo in app docs lib; do
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  printf 'node_modules/\n.envrc\n.env\ntarget/\n' > "$repo/.gitignore"
  printf '# %s\n' "$repo" > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  # Ignored files that hydration must carry over.
  printf 'export FROM_MAIN=1\n' > "$repo/.envrc"
  # One repo already reaches its parent; the others do not, and have to be
  # linked up by hydration.
  if [ "$repo" = app ]; then
    printf 'source_env ../.envrc\nexport FROM_MAIN=1\n' > "$repo/.envrc"
  fi
  mkdir -p "$repo/node_modules/pkg"
  printf 'x\n' > "$repo/node_modules/pkg/index.js"
  printf 'SECRET=1\n' > "$repo/.env"
done
# Each repo calls its main branch something different, and only `lib` has a
# remote: what a worktree forks from has to be resolved per repo.
git -C app branch -qm staging
git -C docs branch -qm master
mkdir -p "$ROOT/remote-lib"
git -C "$ROOT/remote-lib" init -q --bare -b main
git -C lib remote add origin "$ROOT/remote-lib"
git -C lib push -q origin main
git -C lib fetch -q origin
git -C lib remote set-head origin main
# A commit only the remote has, so forking from origin/main rather than the local
# branch is observable.
git -C lib switch -q --detach origin/main
printf 'remote-only\n' > lib/REMOTE.md
git -C lib add REMOTE.md
git -C lib commit -qm remote-only
git -C lib push -q origin HEAD:main
git -C lib switch -q main
git -C lib fetch -q origin

step "ls with no sessions"
"$ZWT" ls

step "the config file is read, and typos in it are not"
mkdir -p "$XDG_CONFIG_HOME/zwt"
printf 'workspace = "%s"\nrepos = ["app", "lib"]\n' "$ZWT_WORKSPACE" \
  > "$XDG_CONFIG_HOME/zwt/config.toml"
(unset ZWT_WORKSPACE; "$ZWT" ls > /dev/null) || fail "the config's workspace was not used"
printf 'workspace = "%s"\nrepo = ["app"]\n' "$ZWT_WORKSPACE" \
  > "$XDG_CONFIG_HOME/zwt/config.toml"
expect_err "unknown field \`repo\`" env -u ZWT_WORKSPACE "$ZWT" ls
printf 'workspace = "%s"\nrepos = ["app", "lib"]\n' "$ZWT_WORKSPACE" \
  > "$XDG_CONFIG_HOME/zwt/config.toml"

# A repo's post-checkout hook needs the toolchain an interactive shell's
# per-directory hooks install (fnm's node, direnv's flake), so the checkout has to
# go through $SHELL -i. This stand-in shell exports what such an rc file would.
step "the checkout runs through an interactive shell"
cat > "$ROOT/fakeshell" <<'SHELL'
#!/bin/sh
export FROM_SHELL_RC=1
shift            # -i
exec sh "$@"
SHELL
chmod +x "$ROOT/fakeshell"
git -C lib config core.hooksPath .hooks
mkdir -p lib/.hooks
cat > lib/.hooks/post-checkout <<HOOK
#!/bin/sh
printf 'FROM_SHELL_RC=%s\n' "\${FROM_SHELL_RC:-<unset>}" > "$ROOT/hookenv.txt"
HOOK
chmod +x lib/.hooks/post-checkout
SHELL="$ROOT/fakeshell" "$ZWT" new proj-4444 --repo lib > /dev/null
[ "$(cat "$ROOT/hookenv.txt" 2>/dev/null)" = "FROM_SHELL_RC=1" ] ||
  fail "the hook ran outside the shell: $(cat "$ROOT/hookenv.txt" 2>/dev/null)"
ok "the hook saw the shell's environment"
"$ZWT" rm proj-4444 --force > /dev/null
git -C lib config --unset core.hooksPath
rm -rf lib/.hooks

# A repo whose post-checkout hook fails, the way a pnpm-install hook does when
# the node it wants is not on PATH. git reports the hook's status as its own, so
# the checkout looks like a failure while being perfectly complete.
step "a failing post-checkout hook does not lose the worktree"
git -C app config core.hooksPath .hooks
mkdir -p app/.hooks
cat > app/.hooks/post-checkout <<'HOOK'
#!/bin/sh
echo "pretend pnpm install failed" >&2
exit 1
HOOK
chmod +x app/.hooks/post-checkout
out=$("$ZWT" new proj-5555 --repo app --repo docs 2>&1)
printf '%s\n' "$out"
HOOKED="$ZWT_WORKSPACE/sessions/proj-5555"
[ -e "$HOOKED/app/.git" ] || fail "the worktree was discarded over a hook failure"
[ -e "$HOOKED/docs/.git" ] || fail "a later member was skipped"
[ -f "$HOOKED/app/.envrc" ] || fail "hydration was skipped after the hook failed"
case "$out" in *"a git hook failed"*) ok "reported, kept, and carried on" ;;
  *) fail "the hook failure was not reported: $out" ;; esac
"$ZWT" ls | grep -q proj-5555 || fail "the session was not registered"
"$ZWT" rm proj-5555 --force > /dev/null
git -C app config --unset core.hooksPath
rm -rf app/.hooks

step "new (members given explicitly)"
"$ZWT" new proj-1234 --title "vitest 5 compat" --repo app --repo lib
SESSION="$ZWT_WORKSPACE/sessions/proj-1234"

step "mirror layout"
[ -e "$SESSION/app/.git" ] || fail "app is not a worktree"
[ -L "$SESSION/docs" ] || fail "docs is not a symlink"
[ -L "$SESSION/other" ] || fail "other is not a symlink"
[ -L "$SESSION/flake" ] || fail "flake is not a symlink"
[ -f "$SESSION/.envrc" ] && [ ! -L "$SESSION/.envrc" ] || fail ".envrc must be a real file"
[ -e "$SESSION/sessions" ] && fail "the sessions root must not be mirrored into itself"
ok "worktrees, symlinks and the generated .envrc are in place"

step "the session root exports itself, and is marked"
grep -q 'export WORKSPACE_ROOT="\$(expand_path \.)"' "$SESSION/.envrc" ||
  fail "the session .envrc does not export WORKSPACE_ROOT: $(cat "$SESSION/.envrc")"
grep -qF "source_env '$ZWT_WORKSPACE/.envrc'" "$SESSION/.envrc" ||
  fail "the session .envrc does not defer to the workspace's"
[ -f "$SESSION/.zwt/session.json" ] || fail "no session marker"
grep -q '"id": "proj-1234"' "$SESSION/.zwt/session.json" || fail "the marker has the wrong id"
grep -qF "\"workspace\": \"$ZWT_WORKSPACE\"" "$SESSION/.zwt/session.json" ||
  fail "the marker has the wrong workspace"
ok "generated .envrc and marker written"

step "a member's own .envrc is made to source the session's"
grep -q '^source_up_if_exists$' "$SESSION/lib/.envrc" ||
  fail "lib was left unable to see the session root"
head -1 "$SESSION/app/.envrc" | grep -q '^source_env \.\./\.envrc$' ||
  fail "app's own parent reference was not left alone"
ok "linked where needed, untouched where not"

# The whole point of the generated .envrc: WORKSPACE_ROOT is the session, in the
# root and in a member, with the workspace's own environment still loaded.
if command -v direnv > /dev/null; then
  step "direnv resolves WORKSPACE_ROOT to the session"
  for dir in "$SESSION" "$SESSION/app" "$SESSION/lib"; do
    got=$(direnv exec "$dir" sh -c 'printf "%s|%s" "$WORKSPACE_ROOT" "$FROM_WORKSPACE"' 2>/dev/null)
    [ "$got" = "$SESSION|1" ] || fail "in $dir direnv gave '$got', expected '$SESSION|1'"
  done
  ok "session root and members all see the session"
fi

step "members are detached at their own main branch"
[ "$(git -C "$SESSION/app" rev-parse --abbrev-ref HEAD)" = HEAD ] ||
  fail "app is on a branch: $(git -C "$SESSION/app" branch --show-current)"
[ "$(git -C "$SESSION/app" rev-parse HEAD)" = "$(git -C app rev-parse staging)" ] ||
  fail "app did not fork from its own main branch (staging)"
# lib has a remote whose tip the local branch does not have: origin wins, so the
# worktree does not start behind.
[ "$(git -C "$SESSION/lib" rev-parse HEAD)" = "$(git -C lib rev-parse origin/main)" ] ||
  fail "lib did not fork from origin/main"
[ -z "$(git -C app branch --list 'proj-*')" ] || fail "a branch was created for the session"
ok "detached at staging and origin/main, no branch invented"

step "hydration carries the environment and nothing else"
[ -f "$SESSION/app/.envrc" ] || fail ".envrc was not hydrated"
[ -f "$SESSION/app/.env" ] || fail ".env was not hydrated"
[ -e "$SESSION/app/node_modules" ] && fail "node_modules was copied; that is a hook's job now"
ok "environment files only"

step "sibling paths resolve as they do in the workspace"
rel=$(cd "$SESSION/app" && cd ../docs && git rev-parse --show-toplevel)
[ "$rel" = "$ZWT_WORKSPACE/docs" ] || fail "../docs resolved to '$rel'"
ok "../docs lands in the main checkout"

step "ls"
"$ZWT" ls
"$ZWT" ls --json | head -5

step "path"
p=$("$ZWT" path proj-1234)
[ "$p" = "$SESSION" ] || fail "path printed '$p'"
# From a symlinked repo: the resolved cwd is in the workspace, so only the path
# walked in through, plus the marker above it, can find the session.
p=$(cd "$SESSION/docs" && "$ZWT" path)
[ "$p" = "$SESSION" ] || fail "path from a symlinked repo printed '$p'"
ok "path resolves by key, and from inside a symlinked member"

step "sync repairs a stripped .envrc, marker and member link"
printf 'export TAMPERED=1\n' > "$SESSION/.envrc"
rm -rf "$SESSION/.zwt"
sed -i '/^source_up_if_exists$/d' "$SESSION/lib/.envrc"
"$ZWT" sync proj-1234 | tee "$ROOT/env.out"
grep -q "WORKSPACE_ROOT" "$ROOT/env.out" || fail "sync missed the tampered .envrc"
grep -q "session.json" "$ROOT/env.out" || fail "sync missed the missing marker"
grep -q "lib" "$ROOT/env.out" || fail "sync missed the unlinked member .envrc"
"$ZWT" sync proj-1234 --fix > /dev/null
grep -q 'export WORKSPACE_ROOT' "$SESSION/.envrc" || fail "--fix did not rewrite the .envrc"
[ -f "$SESSION/.zwt/session.json" ] || fail "--fix did not restore the marker"
grep -q '^source_up_if_exists$' "$SESSION/lib/.envrc" ||
  fail "--fix did not relink the member .envrc"
"$ZWT" sync proj-1234 | grep -q clean || fail "sync is not clean after --fix"
ok "all three repaired"

step "sync on a fresh session"
"$ZWT" sync proj-1234

step "sync detects a repo cloned after creation"
mkdir -p "$ZWT_WORKSPACE/tool"
git -C "$ZWT_WORKSPACE/tool" init -q -b main
git -C "$ZWT_WORKSPACE/tool" config user.email t@t.t
git -C "$ZWT_WORKSPACE/tool" config user.name t
printf 'x\n' > "$ZWT_WORKSPACE/tool/f"
git -C "$ZWT_WORKSPACE/tool" add -A && git -C "$ZWT_WORKSPACE/tool" commit -qm init
"$ZWT" sync proj-1234 | tee "$ROOT/sync.out"
grep -q "tool" "$ROOT/sync.out" || fail "sync missed the new repo"
"$ZWT" sync proj-1234 --fix > /dev/null
[ -L "$SESSION/tool" ] || fail "sync --fix did not add the symlink"
ok "new repo linked in place"

step "sync detects a removed repo"
rm -rf "$ZWT_WORKSPACE/other"
"$ZWT" sync proj-1234 --fix | tee "$ROOT/sync2.out"
[ -e "$SESSION/other" ] && fail "the dangling link survived"
ok "dangling link unlinked"

step "add swaps a symlink for a detached worktree"
"$ZWT" add docs --session proj-1234
[ -e "$SESSION/docs/.git" ] || fail "docs did not become a worktree"
[ "$(git -C "$SESSION/docs" rev-parse --abbrev-ref HEAD)" = HEAD ] ||
  fail "docs is on a branch"
[ "$(git -C "$SESSION/docs" rev-parse HEAD)" = "$(git -C docs rev-parse master)" ] ||
  fail "docs did not fork from its own main branch (master)"
[ -f "$SESSION/docs/.envrc" ] || fail "docs was not hydrated"
ok "docs joined, detached at master"

step "add refuses a name the workspace has no repo for"
expect_err "not a git repo" "$ZWT" add nope --session proj-1234
[ -e "$SESSION/nope" ] || [ -L "$SESSION/nope" ] && fail "a link to nothing was left behind"
ok "nothing was created for it"

step "add is refused twice"
expect_err "already a member" "$ZWT" add docs --session proj-1234

step "promote needs a branch to hand over"
expect_err "detached HEAD" "$ZWT" promote docs --session proj-1234

step "promote, once the work has a name"
git -C "$SESSION/docs" switch -qc proj-1234-docs
"$ZWT" promote docs --session proj-1234
[ -L "$SESSION/docs" ] || fail "docs is not a symlink again"
b=$(git -C "$ZWT_WORKSPACE/docs" branch --show-current)
[ "$b" = proj-1234-docs ] || fail "the main checkout is on '$b'"
ok "main checkout moved to '$b', path unchanged"
git -C docs switch -q master

step "a session deleted with rm -rf leaves no phantom worktrees"
"$ZWT" new proj-6666 --repo docs > /dev/null
rm -rf "$ZWT_WORKSPACE/sessions/proj-6666"
# The record survives the directory, and the registry entry is already gone, so
# nothing points at the mess but the sweep.
git -C docs worktree list | grep -q "proj-6666" || fail "expected a stale worktree record"
"$ZWT" sync --all --fix > "$ROOT/sweep.out"; cat "$ROOT/sweep.out"
grep -q "pruned" "$ROOT/sweep.out" || fail "the sweep did not prune the record"
git -C docs worktree list | grep -q "proj-6666" && fail "the record survived the sweep"
ok "record pruned"

step "rm survives a record a mirror symlink has taken over"
"$ZWT" new proj-7777 --repo lib > /dev/null
STALE="$ZWT_WORKSPACE/sessions/proj-7777"
# What a session recreated over a stale record looks like: git still points here,
# but the path is now a symlink to the main checkout.
rm -rf "$STALE/lib"
ln -s "$ZWT_WORKSPACE/lib" "$STALE/lib"
"$ZWT" rm proj-7777 --force
[ -e "$STALE" ] && fail "the session directory survived"
[ -d "$ZWT_WORKSPACE/lib/.git" ] || fail "the main lib checkout was removed"
git -C lib worktree list | grep -q proj-7777 && fail "the stale record was not pruned"
ok "record pruned, the symlink's target untouched"

step "rm is guarded"
printf 'dirty\n' > "$SESSION/app/README.md"
expect_err "still holds work" "$ZWT" rm proj-1234

step "rm --force"
"$ZWT" rm proj-1234 --force
[ -e "$SESSION" ] && fail "the session directory survived"
[ -d "$ZWT_WORKSPACE/docs" ] || fail "the main docs checkout was followed and deleted"
[ -f "$ZWT_WORKSPACE/app/README.md" ] || fail "the main app checkout was damaged"
git -C "$ZWT_WORKSPACE/app" worktree list
ok "session gone, workspace intact"

step "registry is empty again"
"$ZWT" ls

if [ "$FAILED" = 1 ]; then
  printf '\n\033[1;31mSMOKE FAILED\033[0m (workspace kept at %s)\n' "$ROOT"
  exit 1
fi
printf '\n\033[1;32mSMOKE OK\033[0m\n'
rm -rf "$ROOT"
