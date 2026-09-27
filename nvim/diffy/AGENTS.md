# diffy — agent guide

`README.md` is the user-facing reference: every feature, command, key and option. Keep it in sync with the
code in the same change. This file is for whoever works on diffy: how the code is organised, how to test
it, and the nvim/git/GitHub behaviour we measured the hard way. `diff-plugin.md` is the original design
document, being retired; don't cite it (or this file) from code or tests.

## Working here

- `~/.config/nvim` is an out-of-store symlink to `~/dotfiles/nvim`: edits are live, no Home Manager rebuild.
  `nvim/plugin/diffy.lua` prepends `nvim/diffy` to the runtimepath and sets the user's `<leader>dv*` maps.
- Run tests from `nvim/diffy/`: `make test` (~45 s, offline), `make test FILE=tests/test_x.lua`,
  `make test-gh` (live GitHub, opt-in).
- Comments state the non-obvious why, invariants and gotchas; no narration of how the code came to be.
- A change that affects behaviour updates `README.md`.

## Code map

```
plugin/diffy.lua        :Diffy command + completion, nothing else at startup
lua/diffy/
  init.lua              setup/config, :Diffy dispatch, M.start (open a session) / M.build (render pipeline)
  session.lua           one session per tab: registry, augroup, namespaces, keymap tracking, layout, teardown
  git/run.lua           every git/gh subprocess (vim.system), error notify, DiffyReady
  git/parse.lua         pure parsers for git's -z formats (log, name-status, numstat, status v2, ls-files -u)
  git/repo.lua          root, merge-base, base resolution, status, default range, diff args
  selection.lua         log selection -> (left rev, right rev); the real-file rule
  panels/log.lua        commits panel: entries per view kind, selection keys
  panels/tree.lua       files panel: tree rows, staging keys, file navigation
  diffpair.lua          the two diff windows: buffers, diff mode, winbars, shared keys
  navigation.lua        BufWinEnter on the right window: swap the pair when you jump to another file
  checkout.lua          X full checkout, .git/diffy/checkout.json, restore
  conflict.lua          :Diffy conflicts and the 4-window conflict view
  prompt.lua            key-driven yes/no float (vim.fn.confirm can't be driven in tests)
  highlight.lua         highlight groups (default links) and width-fitting helpers
  review/model.lua      thread data, excerpt relocation, line tracking, GitHub anchor validity/position
  review/ui.lua         signs, summaries, thread float, compose float, :Diffy threads
  review/store.lua      JSON in .git/diffy/<branch>/
  review/local.lua      local backend + review.md export
  review/github.lua     GitHub backend: gh transport, read, placement, push/pull/submit
```

Conventions the code relies on:

- **Sessions.** `session.open` builds the tab (`:tab sbuffer`, see below) and registers windows/buffers.
  Every buffer diffy creates goes through `session.register_buffer` (`bufhidden=wipe`); every buffer-local
  map through `session.map` (desc prefixed `diffy: `, removed on teardown or when a real file leaves a diffy
  window); every namespace through `session.namespace`. Window options are only set inside the session tab.
  `teardown` is idempotent and runs from every close path.
- **Async.** All git/gh calls go through `git/run.lua` with `opts.session` (callbacks no-op once the session
  is closed) and, for renders, `opts.gen` (`session.gen` is bumped by every tree render, so a stale render
  from an earlier selection is dropped). Chained calls start the next link from the previous callback, so
  dropping one link drops the chain.
- **DiffyReady.** `run.ready({ session, event })` fires `User DiffyReady` when something finished drawing.
  Events: `render`, `select`, `open_row`, `review`, `thread`, `compose`, `conflict`, `checkout`, `restore`,
  `pr`, `close`. Tests wait on these; never sleep.
- **Review backends** expose `name`, `capabilities = {resolve, suggestions}`, `branch`, `author`,
  `place(session, thread) -> {win, start_line, end_line} | nil`, and for authoring `load`, `save`, `clear`,
  `export` (local) or `push`/`pull`/`submit`/`resolve_thread` (GitHub). `review/ui.lua` only draws what
  `place` returns and caches it on `thread._place`.
- **Alignment.** Counterpart lines come from nvim's own diff: in each window `row(l) = l + Σ diff_filler(k)`
  for `k ≤ l`; equal rows are counterparts. Summaries under a row are padded with blank virt_lines to the
  busier side's count so both windows stay aligned.

## Testing

Harness: mini.test, one fresh child nvim per case started with `-u tests/minimal_init.lua` (diffy + fugitive
+ mini.nvim pinned in `.deps/`, never the user's config). `minimal_init.lua` also pins git config
(`GIT_CONFIG_GLOBAL=/dev/null`, no commit signing: the user's global config signs with a hardware key and
`git commit` hangs on it). Fixture repos come from `tests/helpers/repo.lua` with pinned names and dates, so
shas are stable; `Repo.standard()` is the shared history (edits, re-edit, merge from main, rename, delete,
add, line shift).

Rules for every test:

1. Named after a behaviour in user terms (`'writing the index buffer stages only the edited hunk'`).
2. Proven to fail: break the code it covers, see it red, restore. Say what you broke in the commit message
   (`Fails without: …`). Use a reversible `sed` on a copy, never `git checkout` a file with other work in it.
3. Assert what the user sees: buffer text, winbars (`ui.layout`), rendered extmarks (`ui.threads_visible`,
   `ui.rows_with`), floats (`ui.thread_float`), git state (`ui.git`), files on disk. Never session internals;
   `ui.wins` is only for addressing windows.
4. Input through real keys and commands (`child.type_keys`, `:Diffy …`). Calling diffy's Lua directly is only
   for pure logic (parsers, selection, line tracking, anchor validity, position).
5. No: module-loads tests, default-config tests, mocks echoing their input, only-doesn't-throw, length
   checks instead of content, near-duplicates of the same path, error-wording pins.
6. Boundaries and transitions over happy-path repeats. Regression tests come from real bugs.
7. Deterministic: wait on `DiffyReady` or `vim.wait` on an observable condition; no network outside
   `make test-gh`. Git, fugitive and nvim are never mocked; the only fake is the `gh` transport.
8. The leak check (`tests/helpers/leak.lua`, `post_case` of every UI file) fails a case that leaves a diffy
   augroup, `diffy://` buffer, diffy keymap, extmark, extra tab/window, changed option outside the tab, or a
   listed `[No Name]`/fugitive buffer.
9. Screenshots only for the layout, the mirrored comment alignment and the conflict view. Reference files in
   `tests/screenshots/` are named after the case: renaming a case means renaming its reference file.

GitHub tests: `review/github.lua` sends everything through `M.transport`; tests swap it for
`tests/helpers/fake_github.lua`, which implements the GitHub behaviour listed below. Read responses are
real GraphQL recorded from sandbox PRs #2–#4 (`tests/fixtures/github/pr*.json`), with git bundles of their
branches so shas match. `make test-gh` (`DIFFY_TESTGH=1`) runs the same test files against the real sandbox,
one fresh PR per case, closed afterwards; placement cases are fake-only because they depend on PR #2's
between-pushes state. When fake and GitHub disagree, fix the fake.

Harness gotchas:

- Opening a float from a key (`K`, `gc`) or a key whose handler spawns a subprocess can leave the child
  `blocking` until more input arrives; `child.lua`/`ui.wait_ready` then throw. Wait with raw `child.api`
  calls (`ui.wait_ready_raw`).
- `vim.fn.confirm()` returns its default immediately in the child; that's why `prompt.lua` exists.
- An error inside a `vim.schedule` callback lands in `vim.v.errmsg`, not reliably in `:messages`.
- To reproduce an async race, defer *issuing* the subprocess (queue the `run.git` call), not the delivery of
  its result: the staleness check runs when the real subprocess completes.
- `:0cquit` (mini.test's `child.stop()`) fires `VimLeavePre`. Simulate a killed nvim with `SIGKILL` on the
  child's pid.
- Under `--noplugin`, rtp entries added in the init still don't source `plugin/`; `minimal_init.lua` runs
  them explicitly.

Reproducing a bug under the user's real config (most real bugs only showed up there): a child with
`child.restart({ '--cmd', 'set rtp^=~/.config/nvim packpath^=~/.local/share/nvim/site', '-u',
vim.fn.expand('~/.config/nvim/init.lua') })`, then `set termguicolors` and a `Normal` background (diffchar
raises E420 without one). `child.get_screenshot()` errors with their colorscheme; read the screen with
`vim.fn.screenstring(row, col)` and highlights with `vim.fn.screenattr`. Throwaway scripts go in `/tmp`.

## The user's config

- diffchar.vim is active (their `diffopt` has no `inline:`). Its `BufWinEnter`/`OptionSet diff` handlers
  keep per-tab state and crash with `E716 Key not present` when a buffer is swapped into a window still in
  diff mode, so `diffpair.show` turns diff off before swapping.
- `diffopt` has `linematch:60`, which splits a conflict into one-line hunks: `gho`/`ght` pass the whole
  marker block as a range to `:diffget`.
- lualine rewrites every window's `statusline`; window-local statuslines don't show. mini.indentscope draws
  guides in indented panel rows unless `vim.b.miniindentscope_disable = true`.
- `<leader>` is space and `<leader>bb`/`bd`/`bo` exist, so a buffer-local `<leader>b` would wait for
  `timeoutlen`; the panel toggle is `<leader>e`.
- `nvim/ftplugin/rust.lua` refuses rust-analyzer on `fugitive://` buffers: blob sides never get LSP.
- Terminal: kitty 0.48 inside zellij 0.45. Kitty image placeholders (e.g. GitHub avatars) render in plain
  kitty but zellij drops them (confirmed on screen; zellij rejects `U=1`, fix pending in
  zellij-org/zellij#5531). snacks.nvim disables images under zellij for the same reason.

## nvim facts (0.12.5)

- `:tabnew` leaves a listed `[No Name]` buffer behind once its window shows something else; open the tab
  directly on a scratch buffer with `:tab sbuffer N`.
- `vim.api.nvim__ns_set(ns, { wins = {…} })` scopes a namespace's extmarks/signs/virt_lines to those windows
  (experimental API; `vim.fn.nvim__ns_set` raises). `nvim_win_add_ns` doesn't exist.
- virt_lines on one side of a scrollbound diff shift that window only; the other side needs the same number
  of blank virt_lines on the counterpart line.
- Diff highlights (DiffAdd/DiffText) win over an extmark `line_hl_group`; mark ranges with
  `number_hl_group` instead.
- A float with `relative='win'` and `bufpos={w0, 0}` puts `col = 0` at the window's first text column, past
  its number/sign gutter.
- `nvim_set_current_win`/`nvim_win_set_buf` don't fire `WinEnter`/`BufEnter`. `BufWinEnter` runs with the
  affected window current and only when the buffer actually changes.
- `WinClosed`/`BufWipeout` callbacks that close other windows of the same tab race `:tabclose`/`:qa`
  (spurious E444); defer them with `vim.schedule`.
- `:bwipeout!` on an unlisted scratch buffer closes its window too (firing `WinClosed`).
- `v:exiting` is already set in `VimLeavePre` on a normal quit: tells an exit apart from a tab close.
- `vim.system(cmd, { env })` merges `env` into the inherited environment.
- `vim.json.decode` turns JSON `null` into `vim.NIL`; pass `{ luanil = { object = true, array = true } }`.
  Comparing `vim.NIL` with a number inside a scheduled callback fails silently.
- `vim.fn.writefile` turns a `\n` inside one list item into a NUL byte; split lines first.
- `string.find(s, p, 1, true)` takes `p` literally, `%` escapes included.
- `FugitiveFind(object, dir)` wants the `.git` dir (`FugitiveExtractGitDir(root)`), not the worktree root.

## git facts

- An unstaged rename is `D old` + `? new` until `git add -N new`; then `git diff -M` and porcelain v2 say `R`.
  diffy doesn't fake it. Staged rename plus an unstaged edit: porcelain v2 `2 RM`, the unstaged diff shows
  `M new`.
- `git status` needs `--untracked-files=all` to list files inside a new untracked directory.
- `git log -z` separates records with one NUL; `git diff -z --name-status`/`--numstat` terminate every token,
  and a rename's paths are two extra tokens.
- `--date-order` guarantees a merge is listed before its parents.
- A conflicted path appears twice in `git diff --name-status`: `U` and a spurious `M`. Keep the `U`.
- `git diff -M a b -- paths` pairs a rename only if both names are in the pathspec.
- After merging the base branch into a branch, the first commit's parent is no longer the merge-base:
  whole-branch diffs must use the merge-base (`git rev-list --ancestry-path mb..HEAD` finds the commits
  that contain it).
- Stable fixture shas: pin `GIT_{AUTHOR,COMMITTER}_{NAME,EMAIL,DATE}` and `GIT_CONFIG_GLOBAL=/dev/null`.
- `git bundle` carries only the named refs; recreate branches with `git fetch <bundle> refs/…:refs/heads/…`.
  A worktree can't check out a branch another worktree already has.

## GitHub facts (measured on the sandbox; the fake reproduces them)

Validation:
- Accepted: changed lines and up to 3 context lines around a hunk of `merge-base...commitOID`, both sides,
  multi-line ranges (even across hunks), renamed/added/deleted files, file-level threads.
- Rejected: anything else ("Line could not be resolved"), including lines brought in by merging the base;
  unknown path ("Path could not be resolved"). One invalid thread fails the whole `addPullRequestReview`,
  so validate locally first. `model.anchor_valid` takes `-U0` hunks (it adds the ±3 itself);
  `model.diff_position` needs the real `-U3` diff.
- Always send a renamed file's new path.

Pending reviews:
- One pending review per user per PR; `reviews(states: PENDING)` returns only the viewer's. While it exists,
  REST `POST pulls/{n}/comments` fails with 422.
- Threads in `addPullRequestReview` anchor at its `commitOID`. `addPullRequestReviewThread` has no commit and
  anchors at head. Deprecated `addPullRequestReviewComment(commitOID, position)` still works: `originalCommit`
  is that commit and GitHub moves `commit` to head right away when trackable.
- `position` = 1-based index of the line below the file's first `@@` in `merge-base...commitOID`, later `@@`
  headers counting as lines.
- `addPullRequestReview` returns no thread ids: replies drafted on a new thread are pushed afterwards with
  `addPullRequestReviewThreadReply`, finding the new thread by path and first comment body.
- Replies with a pending review id become pending replies; resolve/unresolve is immediate. A submitted review
  keeps the `commit` it was created with. You can't approve or request changes on your own PR.

Where comments point:
- Between pushes nothing is remapped: `line == originalLine`, `commit` = the commit written on.
- On the next push (force-pushes too) trackable comments get `commit` = head and a shifted `line`;
  untrackable ones get `line = null`, `isOutdated = true`. diffy computes placement and outdatedness itself.
- `diffSide`/`startDiffSide` are thread-level fields; `line`/`originalLine`/`startLine`/
  `originalStartLine`/`commit`/`originalCommit`/`diffHunk` are comment-level. Thread-level `startLine` is
  already tracked to head while `line` isn't: use comment-level lines only.
- An old-side comment's line is always merge-base-relative, whatever its `commit`.
- github.com tracks both range endpoints, in both directions of history; a commit view's old side is the
  commit's parent; lines outside the viewed hunks get a context hunk.
- Bodies round-trip byte-identical (multi-line, fences, emoji).

API: `gh api graphql --input -` with `{query, variables}` on stdin avoids quoting multi-line bodies. An
introspection query may use the same introspection field at most twice.

## Sandbox

Private repo `GuillaumeLagrange/diffy-tests`, rebuilt by `sandbox/build.js` (Bun; about 5 minutes,
force-pushes every sandbox branch). Each PR has base `base/<name>`, head `sandbox/<name>`, and a description
listing every comment id (the first word of its body) and where it must show.

- **#2 Placement**: tracking across commits, force-push, merge, rename, delete, outdated, resolved. **Never
  push to `sandbox/placement`**: it would remap the between-pushes comments.
- **#3 Content**: multi-line bodies, nested fences, suggestions, reply chains, resolved threads, conversation.
- **#4 Pending**: an unsubmitted review with threads on three commits and a pending reply. **Never submit,
  delete or push over it** (`:Diffy review push` deletes your pending review first).

A local clone is at `~/projects/diffy-tests` for manual runs; never push from it, and use a separate
`git worktree` when several agents smoke-test at once. Write-side experiments go on a throwaway PR.

On github.com: `/pull/N/changes` (full) and `/pull/N/changes/<sha>` (one commit) render lazily; scroll while
collecting `document.body.innerText`. Thread headers read `Comment on line R15` / `… lines R13 to R15`.

## Open questions

- Legacy `addPullRequestReviewComment` on old-side (LEFT) lines.
- Whether the review's `commitOID` matters on github.com beyond anchoring.
- Bodies written in the web UI (CRLF?).
