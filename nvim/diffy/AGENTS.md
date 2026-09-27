# diffy — agent guide

`diff-plugin.md` is the contract: features, UX, architecture, test rules and phases. This file holds what the
contract doesn't: verified behaviour of nvim, git and GitHub, gotchas, and how to work in this directory.
Refine it during implementation. When a fact here turns out wrong, fix it here; when behaviour is decided,
it goes in the contract, not here.

## Working here

- Never edit `~/obsidian/Guiom/Dev/Improved nvim diff.md` (the original spec). It is read-only context.
- `~/.config/nvim` is an out-of-store symlink to `~/dotfiles/nvim` (`modules/headless/default.nix`): edits are
  live, no Home Manager rebuild. Plugins are loaded with `vim.pack.add` in `nvim/plugin/*.lua`.
- Follow contract §11 for every test: fails-without check, outcome assertions, no banned test shapes.
- Environment: nvim 0.12.5, git 2.54, `gh` authenticated (scopes `repo`, `read:org`, `gist`).

## Existing config diffy touches

- fugitive, rhubarb and gitsigns are installed (`nvim/plugin/git.lua`); diffview was removed in phase 8.
- diffchar.vim is installed (`nvim/init.lua`) and active because the user's `diffopt` has no `inline:`. Its
  `BufWinEnter`/`OptionSet diff` handlers keep per-tab state (`t:DChar`) and crash with `E716 Key not present`
  when a buffer is swapped into a window that is still in diff mode. Reproduced only with the real config on
  multi-hunk files; diffpair.lua turns diff off before every swap. The test harness doesn't load it.
- `nvim/ftplugin/rust.lua` refuses to attach rust-analyzer to `fugitive://` and `octo://` buffers, so blob
  sides never get LSP. That is expected (contract §3, real-file rule).
- `nvim/lua/session.lua` (`close_ephemeral_buffers`) and `nvim/lua/utils/init.lua` (`close_octo_buffers`) list
  diffview/octo buffer patterns; phase 8 swaps them for `diffy://`.

## nvim facts (verified on 0.12.5)

- `:tabnew` creates a listed `[No Name]` buffer that outlives the tab once its window is repointed. Open the tab
  directly on a scratch buffer with `:tab sbuffer N` instead.
- Reproducing bugs under the user's real config in a child: `child.restart({ '--cmd', 'set rtp^=~/.config/nvim
  packpath^=~/.local/share/nvim/site', '-u', '~/.config/nvim/init.lua' })`, then `set termguicolors` and give
  `Normal` a bg (diffchar raises E420 otherwise). `child.get_screenshot()` errors with that colorscheme; read the
  screen with `vim.fn.screenstring(row, col)`.
- `nvim_win_add_ns` does not exist. `vim.api.nvim__ns_set(ns, { wins = { win } })` (not `vim.fn.nvim__ns_set` -
  that raises "Tried to call API function with vim.fn") works: extmarks, virt_lines and signs in that
  namespace render only in the listed windows. Experimental API (`nvim__` prefix).
- virt_lines on one side of a scrollbound diff shift that window and break alignment. The same number of empty
  virt_lines on the counterpart line of the other window restores it.
- Default `diffopt` here: `internal,filler,closeoff,indent-heuristic,inline:char,linematch:40`.
  `vim.text.diff(…, { result_type = 'indices' })` without `linematch` pairs lines differently from nvim's diff
  view; with `linematch = 40` it matches. Counterpart lines straight from nvim: in each window,
  `row(l) = l + Σ diff_filler(k)` for `k ≤ l`, and equal rows are counterparts. Prefer this; it can't drift.
- `--noplugin` blocks automatic `plugin/**/*.{vim,lua}` sourcing for *every* rtp entry, even ones added to
  `'runtimepath'` from inside the `-u` init file itself. A test init loaded under `--noplugin` must explicitly
  `vim.cmd('runtime plugin/x.lua')` for anything that ships a `plugin/` file (fugitive, diffy's own).
- `:bwipeout!` on an unlisted scratch buffer (`nvim_create_buf(false, true)`, `buftype=nofile`, no alternate)
  closes its window too, firing `WinClosed` for it — it doesn't just leave the window showing an empty buffer.
- A `WinClosed`/`BufWipeout` callback that synchronously force-closes *other* windows of the same tab can race
  a still-in-progress native multi-window closer (`:tabclose`, `:qa`): nvim reports a spurious "E444: Cannot
  close last window" as if it were operating on the wrong (now-renumbered) tab. Deferring the cleanup with
  `vim.schedule` avoids it — by the time it runs, the native command has already finished.
- `vim.system(cmd, { env = {...} })` *merges* `env` into the inherited environment; it does not replace it.
- `nvim_set_current_win`/`nvim_win_set_buf` do not fire `WinEnter`/`BufEnter` (unlike `:wincmd`/mouse/real key
  input, which do). Anything gating on focus (log collapse/expand) must be exercised in tests with real
  key-driven window movement (`type_keys('<C-w>j')`), not the raw API, or the autocmd never runs.
- `FugitiveFind(object, dir)`/`fugitive#Find` treat a *string* `dir` argument as the `.git` directory literally
  (no path-to-gitdir resolution) - pass `vim.fn.FugitiveExtractGitDir(repo_root)`, not the worktree root itself.
- `string.find(s, pat, init, true)` (`plain=true`) searches for `pat` as a literal substring - Lua-pattern
  escapes like `%.` are *not* interpreted and become part of the literal string being searched for (so
  `s:find('%.%.', 1, true)` looks for the four characters `%.%.`, never matches `..`). Use the plain
  substring (`s:find('..', 1, true)`) or drop `plain`.
- `BufWinEnter`'s callback runs with the *affected* window as
  `vim.api.nvim_get_current_win()` even when a background (non-focused) window's
  buffer was changed via `nvim_win_set_buf(win, buf)` - reverting to the real current
  window once the callback returns. There is no buffer-agnostic, window-scoped variant
  of the autocmd itself, so window-scoping it means checking this inside the callback.
- `nvim_win_set_buf(win, buf)` fires `BufWinEnter` only when `buf` actually differs from
  what the window already shows; setting the same buffer again is a silent no-op (no
  autocmd) - useful for a handler that reacts to a buffer change and then redundantly
  re-applies the same buffer without causing a refire loop.
- `v:exiting` is already non-`nil` (`0` on a normal `:qa`) by the time `VimLeavePre`
  fires, not just `VimLeave` - use it inside a `VimLeavePre` callback to tell a real
  exit apart from an ordinary `:tabclose`/`:q` that merely closes one tab.
- `:0cquit` (what mini.test's `child.stop()`/`child.restart()` use to close a child)
  **does** fire `VimLeavePre`/`VimLeave` - it is not a stand-in for a hard kill. To
  simulate nvim being killed (no graceful shutdown autocmds at all), send `SIGKILL` to
  the real OS pid (`vim.fn.getpid()` inside the target process) instead.
- `vim.json.decode(str)` turns a JSON `null` into the `vim.NIL` userdata sentinel, not
  Lua `nil` - `field == nil` on it is `false`, and an arithmetic/comparison op on it
  raises "attempt to compare userdata with number" *inside* a `vim.schedule` callback
  (invisible: no `vim.notify`, no test failure, the async chain just silently never
  reaches its `cb()` - only `:messages` shows the traceback). Pass `{luanil = {object =
  true, array = true}}` to convert JSON `null` to real Lua `nil` recursively instead.
  Matters for any GraphQL field that can legitimately be null (a comment's `line` once
  GitHub can no longer track it, `originalStartLine` on a single-line comment, etc).
- A worktree cannot check out a branch another worktree of the same repo already has
  checked out (`git worktree add <path> <branch>` fails: "already used by worktree at
  ..."). To add a worktree for a branch the *primary* clone currently has checked out,
  detach the primary clone first (`git checkout --detach`), add the worktree at that
  branch name, do the work, then restore the primary clone's branch afterward.
- `git bundle create <file> <refs>...` only carries exactly the refs named (and their
  reachable objects) - a bundle of `refs/remotes/origin/X` does *not* give you a local
  branch `X` on unbundling. Reconstruct one with `git init` + `git fetch <bundle>
  refs/remotes/origin/X:refs/heads/X` (one refspec per branch needed), then `git
  checkout X` - fully offline, no working `origin` remote required for this step (only
  for anything that later reads the remote URL, e.g. `git remote get-url origin`, which
  still needs a `git remote add origin <url>` even though it's never fetched from).

## git facts

- An unstaged rename is `D old` + `? new` until the new path is intent-to-add (`git add -N`); then
  `git diff -M` and `status --porcelain=v2` report it as `R`. Diffy does not fake it (contract §5).
- Rename staged plus an extra unstaged edit: porcelain v2 `2 RM`; the unstaged diff shows only `M new`.
- Stable shas for fixtures: pin `GIT_AUTHOR_{NAME,EMAIL,DATE}`, `GIT_COMMITTER_{NAME,EMAIL,DATE}` and set
  `GIT_CONFIG_GLOBAL=/dev/null`.
- `git log -z --pretty=format:…` separates commit records with a bare NUL and does not add one before the
  first or after the last record. `git diff -z --name-status`/`--numstat` instead NUL-*terminates* every
  token (including the last), and a rename/copy record's path field is empty with the old/new paths as two
  further NUL-terminated tokens - the two `-z` shapes need different splitting logic.
  `--date-order` on `git log` guarantees a merge commit is listed before both its parents (plain reverse
  chronological order happens to too, given monotonically increasing commit dates, but isn't guaranteed to).
- A conflicted path's plain `git diff` (worktree vs index, no revs) reports it *twice*
  in `--name-status`/`--numstat`: once as `U`, once as a spurious `M` (git's own
  auto-merge attempt) with the same path. Dedupe by keeping only the `U` row.
- `git diff -M <a> <b> -- <pathspec>...` only detects a rename between two names if
  *both* the old and new name are given as pathspecs (or none at all) - restricting to
  only the new name loses the pairing and reports a plain `A`, even for adjacent
  commits where the unrestricted diff would show `R`.

## GitHub facts (measured on the sandbox; the fake GitHub must reproduce them)

Validation of review threads:
- Accepted: changed lines, and context lines up to ±3 around a hunk, of the `merge-base...commitOID` diff. Both
  sides, multi-line ranges (even spanning several hunks), renamed/added/deleted files, and file-level threads
  (path only, no line → `subjectType FILE`).
- Rejected with "Line could not be resolved": lines outside hunks+context, including lines brought in by merging
  the base branch. Unknown path: "Path could not be resolved".
- One invalid thread fails the whole `addPullRequestReview`. Validate everything locally first.
- A renamed file's old path is accepted at head and stored as-is; at an intermediate commit it is normalised to
  the new path. Always send the new path.

Pending reviews:
- One pending review per user per PR. While it exists, REST `POST pulls/{n}/comments` fails with 422.
- `reviews(states: PENDING)` returns only the viewer's own.
- Threads passed to `addPullRequestReview` anchor at its `commitOID`. `addPullRequestReviewThread` has no commit
  argument and anchors at head. Deprecated `addPullRequestReviewComment(commitOID, position)` still works and
  records `originalCommit` = that commit; GitHub moves its `commit` to head immediately when trackable.
- `position` = 1-based index of the diff line below the file's first `@@` header of `merge-base...commitOID`,
  where later `@@` headers count as lines. Verified with one hunk (pos 3 → L9) and two (pos 18 → L20).
- `addPullRequestReviewThreadReply` with a pending review id adds a PENDING reply (`replyTo` set).
  `updatePullRequestReviewComment` works on pending comments. Resolve/unresolve is immediate and independent
  of any pending review.
- A submitted review keeps `commit` = the `commitOID` it was created with.
- You can't approve or request changes on your own PR, so those events can't be exercised on the sandbox.
- Verified live (phase 7B, `make test-gh` PR #7-#12): pushing a single
  new-side thread on the PR head via `addPullRequestReview(threads:[...])`
  works exactly per the sandbox facts above; `resolveReviewThread`/
  `unresolveReviewThread` and `submitPullRequestReview` behave as
  documented; `:Diffy review pull`'s import round-trips cleanly.
- `make test-gh` (PRs #14-#21) runs tests/test_github_write.lua and the `:Diffy pr` refusals of
  test_github_read.lua live, one fresh PR per case (`tests/helpers/github_live.lua`): all green with the
  fake's assertions unchanged, so no fake/GitHub disagreement found. Legacy `addPullRequestReviewComment`
  on Q2 at the position computed from `git diff -U3 merge-base Q2` lands on R20, as expected.
- `model.anchor_valid` (the client-side validity check) must be fed hunks
  from a `-U0` diff, not `-U3`: it adds the ±3 context window itself, so a
  wider diff double-counts context and lets through lines GitHub actually
  rejects. `model.diff_position`, by contrast, needs the real `-U3` diff
  (it walks GitHub's own rendered diff-line numbering).

Where comments point:
- Between pushes the API does not remap: comment `line == originalLine` and `commit` = the commit it was written
  on, `isOutdated=false`, even when head has since changed that line.
- On the next push GitHub remaps everything: trackable comments get `commit` = new head and a shifted `line`
  (`originalLine` kept); untrackable ones get `line = null`, `isOutdated = true`, `commit` unchanged. Force-pushes
  behave the same.
- **Correction to the contract's own §9.4 wording**: `diffSide`/`startDiffSide` are
  **thread**-level GraphQL fields (`PullRequestReviewThread`), not comment-level -
  `PullRequestReviewComment` has no `side`/`diffSide` field at all (confirmed via
  schema introspection). `line`/`originalLine`/`startLine`/`originalStartLine`/
  `commit`/`originalCommit`/`diffHunk`/`pullRequestReview` *are* comment-level, as the
  contract says. Since every comment in one thread shares one side, read `diffSide`
  once from the thread node and pair it with the *comment*-level line fields.
- Thread-level `startLine` is already tracked to head while thread `line` is not (e.g. thread `15..12`).
  Comment-level fields are consistent. Use comment-level fields only.
- An old-side (`LEFT`) comment's `line`/`originalLine` value is already merge-base-
  relative, independent of whichever `commit`/`originalCommit` won the "exists locally"
  fallback - confirmed on the sandbox: an old-side comment written directly against
  head (`commit == originalCommit == head`, no remap needed) still reports the *merge-
  base* file's own line number, not an offset relative to head's parent. Tracking an
  old-side anchor therefore always starts from merge-base, never from `commit`.
- github.com computes placement live, as contract §9.4 describes: both range endpoints are tracked (lines inside
  may change), in both directions of history, the old side of a commit view is the commit's parent, and lines
  outside the viewed hunks get a context-only hunk.
- Bodies round-trip byte-identical through the API (multi-line, code fences, emoji).

API usage:
- `gh api graphql --input -` with `{query, variables}` JSON on stdin avoids `-f` quoting of multi-line bodies.
- An introspection query may use the same introspection field at most twice.
- Mutations for reviews: `addPullRequestReview`, `addPullRequestReviewThread`, `addPullRequestReviewThreadReply`,
  `addPullRequestReviewComment` (deprecated), `updatePullRequestReview(Comment)`,
  `deletePullRequestReview(Comment)`, `submitPullRequestReview`, `resolveReviewThread`, `unresolveReviewThread`.

## Sandbox

Private repo `GuillaumeLagrange/diffy-tests`, rebuilt from scratch by `sandbox/build.js` (Bun; run from the
omp eval kernel: `await (await import('<abs path>/sandbox/build.js')).buildAll()`, about 5 minutes; it
force-pushes every sandbox branch). Each PR has base `base/<name>` and head `sandbox/<name>`, and a description
table listing every comment id (the first word of each comment body) and where it must show.

- **#2 Placement**: tracking across commits, force-push, merge, rename, delete, outdated, resolved. Round B was
  written after the last push. **Never push to `sandbox/placement`**: it would remap round B and destroy the
  between-pushes state.
- **#3 Content**: multi-paragraph bodies, code blocks with nested fences, suggestions (single, 2→3 lines,
  deletion, on an intermediate commit, in a reply), reply chain, resolved threads, conversation comments.
- **#4 Pending**: the owner's unsubmitted review with threads on three commits and a pending reply.
  **Never submit or delete it**; it is the `pull` fixture.

Use these to record GraphQL fixtures and to check behaviour. `make test-gh` must create its own branch and PR
per run (submitted reviews can't be deleted) and close it afterwards.

A local clone lives at `~/projects/diffy-tests` (HTTPS remote, PR heads fetched as `origin/pr/N`) for manual smoke runs.
Never push from it. `/tmp/diffy-sandbox` is `build.js`'s own working copy.

## Checking github.com

Follow the global browser rule. Specific to GitHub's new "Changes" UI:
- Full PR: `/pull/N/changes`; one commit: `/pull/N/changes/<sha>`.
- It renders lazily; scroll while collecting `document.body.innerText`. Thread headers read
  `Comment on line R15` / `Comment on lines R13 to R15` / `Comment on file`.
- Deleted files stay behind "Load diff". The comments panel ("Open comments panel") hides resolved threads by
  default ("Showing 12 of 15" on #2; the 15 vs 14-thread count is unexplained).

## Harness facts

- `nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"` runs mini.test. Child nvims
  (`MiniTest.new_child_neovim`, `child.restart({ '-u', 'tests/minimal_init.lua' })`) support `type_keys`,
  `get_screenshot` and `lua_get` on 0.12.5.
- Children must always start with `-u tests/minimal_init.lua` so the user's config never loads.
- `MiniTest.config.collect.find_files` default globs `tests/**/test_*.lua`; test file names must match that.
- `require('tests.helpers.x')` isn't found via the normal `rtp/lua/?.lua` convention (`tests/` isn't under
  `lua/`); add the plugin root to `package.path` explicitly (`root .. '/?.lua;' .. package.path`) instead.
- Buffer/window/tabpage handles round-trip as plain Lua numbers through `child.lua_get`/`child.lua` (msgpack-rpc
  to a separate child process) — comparing/using them the same way as in-process is fine, no unwrapping needed.
- `vim.fn.confirm()` does **not** block for real input in this harness (headless, UI
  attached only for `get_screenshot`): it returns its default choice immediately, even
  with zero typeahead queued, and `child.type_keys()` can't drive it (confirmed by
  direct experiment: `is_blocked()` never becomes true around a `confirm()` call
  reached through a mapped keystroke, regardless of ordering/timing/combining keys).
  Test confirm()-driven code by mocking it instead (`child.lua("vim.fn.confirm =
  function(...) return N end")`), the same technique mini.nvim's own test suite uses
  for its `confirm()`-driven features (`mini.bufremove`, `mini.files`).
- A mapped key that itself calls `nvim_open_win` + `vim.cmd('startinsert')` (a
  floating compose buffer, say) leaves `nvim_get_mode().blocking` `true` for a while
  after `child.type_keys()` returns - clearing only once *more real input* arrives
  (another `type_keys()` call), not with more wall-clock time or more guard-free
  polling alone. `ui.wait_ready`/`child.lua` throw immediately while blocked (their
  guard checks `is_blocked()` up front); reimplement the same `DiffyReady` wait with
  raw `child.api.*` calls (no guard) instead of `ui.wait_ready` right after such a
  keystroke - see `tests/test_review_local.lua`'s `wait_ready_raw`.
- The same `blocking=true` transient (previous bullet) also follows a keystroke whose
  handler synchronously kicks off a `vim.system`/`run.git` subprocess (no float
  involved at all) - observed reliably right when the handler also closes a floating
  window first (`conflict.lua`'s confirm-prompt accept path), and, less predictably (a
  timing race against the RPC round-trip), even with no window in play. Unlike the
  `startinsert`-float case, this one *does* clear on its own once the subprocess's own
  callback has run - but a guard check performed immediately after `child.type_keys()`
  returns can still land before that happens. Use the same raw-`child.api` `wait_ready`
  reimplementation defensively right after any keystroke you know spawns a subprocess
  synchronously, not only after a float-opening one - see `tests/test_conflicts.lua`'s
  `wait_ready_raw`.
- An uncaught Lua error thrown inside a `vim.schedule`-scheduled callback sets
  `vim.v.errmsg` inside that same nvim process (verified: `child.lua_get('vim.v.errmsg')`
  picks it up); it does **not** reliably land in `:messages`' own history in headless
  mode. Detect an async-callback crash from the test side by clearing `vim.v.errmsg`
  before the action and reading it back after, not by scraping `:messages`.
- Reproducing "an async git callback fires after/out of order with a later one" needs
  more than delaying delivery of an already-finished `vim.system` result: `git/run.lua`'s
  own liveness/staleness check runs at the moment the real subprocess completes, using
  whatever session state is current *then* - holding back only the delivery of an
  already-completed callback lets that check see the (by then already-stale) state
  regardless, so it still gets dropped correctly and proves nothing. Instead, defer
  *issuing* the subprocess itself (patch `require('diffy.git.run').git`/`.run` to push
  `function() real_fn(args, opts) end` onto a queue instead of calling it, matched by
  `opts.gen`, and run the queued closure only when the test wants the race to happen) -
  this delays the real subprocess's own completion time, and so the check inside it,
  to whenever the test chooses. A held multi-call chain (e.g. tree.lua's name-status
  then numstat) needs the drain repeated (each release can enqueue the next call in the
  chain), not a single pass.

## Open questions

- Legacy `addPullRequestReviewComment` with old-side (LEFT) lines.
- Whether the review's `commitOID` matters on github.com beyond anchoring (the "reviewed changes" link).
- Bodies authored in the web UI (CRLF line endings?). Author one in #3 via the browser if it matters.
