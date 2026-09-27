# diffy — feature & implementation contract

A Neovim diff viewer that replaces diffview.nvim, plus a review layer with two backends:
GitHub PR reviews and local reviews exported to an LLM agent.

Targets nvim ≥ 0.12, git ≥ 2.36, `gh` CLI (authenticated). Depends on vim-fugitive for blob/index buffers.

## 1. Principles

- **Clean lifecycle.** Each diffy session owns one tabpage, one augroup, and a set of namespaces. Closing
  the tab by any means (`:tabclose`, `:q` on the last managed window, wiping a panel buffer, `VimLeavePre`) runs
  one idempotent `teardown()`. After teardown there is no diffy augroup, autocmd, buffer-local keymap, extmark or
  diffy buffer, and no diffy window options on windows outside the tab.
- **Git does the work.** Diffs, renames and log come from the git CLI (`-z` output, parsed). Blob and index
  buffers are fugitive buffers (`FugitiveFind`). Writing an index buffer stages, as in fugitive.
- **Async.** Every git/gh call goes through `vim.system` with callbacks. The UI never blocks on a subprocess.
  When a view (or refresh) has finished rendering, diffy fires `User DiffyReady`; tests wait on it.
- **Manual refresh.** Refresh happens on `R` and after diffy's own mutations (stage, write, checkout). No
  watchers.
- **Self-contained.** Lives in `nvim/diffy/` (plugin layout: `lua/diffy/`, `plugin/`, `tests/`), is prepended to
  `runtimepath` from `nvim/plugin/diffy.lua`, and can be extracted to its own repo by moving the directory.

## 2. Layout

```
┌──────────┬─────────────────────┬─────────────────────┐
│ tree     │ old (left)          │ new (right)         │
│          │                     │                     │
│          │                     │                     │
├──────────┤                     │                     │
│ log      │                     │                     │
└──────────┴─────────────────────┴─────────────────────┘
```

- Two panel buffers (`diffy://tree`, `diffy://log`) in one left column, width `panel_width` (default 40).
- Panel windows show rows only: no line numbers, sign/fold/status columns, list chars, colorcolumn or spell;
  no wrap; cursorline on. Their statusline is a short label (`Files`, `Commits`), not the buffer name.
- The log always lists every entry; its height is `min(#entries, 40% of column)`, the tree gets the rest. Set on
  open and on `R`.
- **Panel toggle:** `:Diffy panel`, or `<leader>e` (config `keymaps.toggle_panel`) in any diffy window, hides
  the column; the diff windows then split the full width evenly. Toggling again restores it at `panel_width`
  with the same content and cursors. Hiding is not a close: the session stays alive and `]f`/`[f`, `]r`/`[r`
  keep working from the diff windows.
- Rows fit on one line: names too long for the width are truncated with `…`; status letter and counts always
  stay visible. Rows re-fit when the window is resized.
- Colors are highlight groups linked with `default` (a colorscheme can override them): status letters by kind
  (`A`/`?` Added, `M`/`R`/`C` Changed, `D` Removed, `U` DiagnosticError), directory headers Directory,
  `+n` Added, `-m` Removed, sha Identifier, merges Comment, `Unstaged`/`Staged` Title, selected log entries a
  leading `▌` plus a Visual line (`DiffySelection`), and the file shown in the diff a `DiffyCurrentFile` line
  with a bold name.
- The two diff windows use native diff mode (`:diffthis`, `diffopt` linematch), with scrollbind/cursorbind
  managed per window. Winbars show the rev and path of each side.
- `R` rebuilds the whole layout: window sizes, panels, diff pair, decorations.

## 3. The log model

The log panel is an ordered list of entries. The diff always shows one **contiguous selection** of
entries: the left side is the parent of the bottom-most selected entry, the right side is the top-most selected
entry.

| Entry          | Present in          | Meaning as top of selection | Meaning as bottom |
|----------------|---------------------|-----------------------------|-------------------|
| `Unstaged`     | `:Diffy`, `:Diffy branch` | worktree                    | left = index      |
| `Staged`       | `:Diffy`, `:Diffy branch` | index                       | left = HEAD       |
| commit `C`     | all                 | `C`                         | left = `C^`       |
| merge commit   | all (greyed)        | not selectable              | not selectable    |

- Commits listed are `merge-base..HEAD` (branch views) or the requested range. Non-merge commits only;
  merge commits appear dimmed in place so history shape stays visible, and navigation skips them.
- A selection that spans a merge is a range `A^..B` over non-merge endpoints (git computes the combined diff).
  Exception, in `:Diffy branch` and `:Diffy pr`: when the selection reaches the oldest commit and its top
  contains a merge of the base branch, the left side is the merge-base, as github.com's full-PR view. Otherwise
  base-branch changes merged into the branch would show as branch changes.
- Keys in log: `<CR>` select single entry, `v`+motion / `V` range select, `a` select all, `J`/`K` (also usable
  from the diff windows as `]r`/`[r`) move the single-entry selection to next/previous commit.
- **Right side is a real file** (LSP, editable) when the top entry is `Unstaged`, or it is `HEAD` and the file has
  no uncommitted changes, or the full-checkout commit (§7). Otherwise it is a read-only fugitive blob.

## 4. Commands and default selections

| Command                | Log entries                          | Default selection            |
|------------------------|--------------------------------------|------------------------------|
| `:Diffy`               | Unstaged, Staged, commits `@{u}..HEAD` or last 20 | `Unstaged`        |
| `:Diffy branch [base]` | Unstaged, Staged, `merge-base(base)..HEAD` | all commits              |
| `:Diffy A..B` / `A...B`| commits of the range                 | all                          |
| `:Diffy pr`            | PR commits (`merge-base(base)..HEAD`) | all                         |
| `:Diffy file [path]`   | commits touching path (`--follow`)   | newest commit                |
| `:Diffy conflicts`     | none; tree shows conflicted files    | first conflicted file        |
| `:Diffy close`         | closes the current session's tab     |                              |
| `:Diffy panel`         | hides/shows the tree/log column (§2) |                              |
| `:Diffy restore`       | recovers from an interrupted full checkout (§7) |                   |

- `branch` base resolution: explicit arg → PR base of the current branch (`gh pr view --json baseRefName`) →
  default branch of `origin`.
- `pr` works **only on the checked-out branch**. It refuses to open unless `HEAD` equals the PR head commit on
  GitHub and there are no tracked changes (staged or unstaged). The error says what's wrong (unpushed commits,
  behind remote, dirty tree).
- Only one session per tabpage. Several sessions in separate tabs are allowed and fully independent.

## 5. File tree

- Entries: status letter (`M A D R C U ?`), path grouped by directory (collapsible, single-child dirs
  flattened), `+n -m` counts right-aligned to the window width. A row under a directory header shows only the
  path relative to that header (the basename for a direct child), indented. Renames within one directory show
  `old → new` basenames; a rename across directories shows the new relative path (prefixed with `old →` only
  if it fits). Renames diff as a rename pair. Too-long names are truncated from the left with `…`, keeping the
  file name, status and counts.
- Renames come from git's detection (`-M`). An unstaged rename appears as `D` + `?` unless you `git add -N` the new
  path; diffy does not fake it.
- Keys: `<CR>`/`o` open pair, `]f`/`[f` next/previous file (also from diff windows), `za` fold dir, `gf` open
  the real file in the previous tab.
- **Staging** (only when the selection is exactly `Unstaged` or exactly `Staged`):
  - Tree: `s` stage, `u` unstage, `-` toggle, `S`/`U` all. On a rename pair both paths are staged/unstaged
    together.
  - `Unstaged` selected: left = index buffer (fugitive `//0/`), right = worktree. Editing the left side and `:w`,
    or `do`/`dp`, stages hunks.
  - `Staged` selected: left = HEAD blob, right = index buffer; writing it changes the index.
  - Untracked files show under `Unstaged` as `?` with an empty left side.

## 6. LSP navigation inside the diff

Applies only when the right side is a real file.

- A `BufWinEnter` autocmd (session augroup, scoped to the right diff window) catches any buffer change in that
  window (go-to-definition, `gf`, `:e`).
- If the new buffer's path is in the current file list, diffy loads the matching left side, re-enables diff
  mode on both, and highlights the file in the tree. The jump position is preserved.
- Otherwise the right window leaves diff mode, the left window shows a placeholder ("outside diff"), and the
  winbar says so. Returning to a diff file (`<C-o>`, tree) restores the pair.

## 7. Full checkout (intermediate commit with LSP)

- `X` on a single selected commit `C` in the log: refuses if there are tracked changes. Otherwise writes
  `.git/diffy/checkout.json` `{ branch, head, commit }`, runs `git checkout --detach C`, and shows `C^..C`
  with the right side as real files.
- Leaving it (selecting anything other than `C`, `X` again, closing the tab, `VimLeavePre`) checks out the
  saved branch and deletes the state file. If the tree became dirty meanwhile, diffy refuses to switch and
  explains why.
- On `:Diffy …` start, if the state file exists diffy warns and offers `:Diffy restore`, which checks out the
  saved branch and deletes the file.

## 8. Conflict view

- `:Diffy conflicts` (and selecting a `U` file in the tree) opens a 4-window layout in the diff area:

```
┌──────────┬──────────┬──────────┐
│ ours :2  │ base :1  │ theirs :3│
├──────────┴──────────┴──────────┤
│ result (worktree file)         │
└────────────────────────────────┘
```

- All four are in diff mode; the result is a real file. From the result window: `gho` / `ghb` / `ght` take
  the hunk from ours/base/theirs (`:diffget` on the right buffer), `]x`/`[x` jump between conflict markers.
- Tree `s` marks the file resolved (`git add`); it warns and asks for confirmation if conflict markers remain.
- Works during merge, rebase, cherry-pick and stash-pop (stages 1–3 read through fugitive).

## 9. Review layer

### 9.1 Data model

```
Thread  { id, backend, anchor, comments[], resolved, outdated, review_id? }
Comment { id, author, body (markdown), created_at, state: draft|pending|published|sent }
Anchor  { path, side: old|new, start_line, end_line, commit, excerpt }
```

- `commit` is the rev displayed on that side when the comment was written (a sha, `index`, or `worktree`).
- `excerpt` is the anchored lines. It is used to re-locate an anchor after edits (exact match within ±20 lines,
  otherwise the thread is **detached** and listed but not placed inline).

### 9.2 UI (shared by both backends)

- A thread shows as a sign on its anchor line plus a one-line `virt_lines` summary under the range end
  (`💬 alice +2 · resolved`). The same number of empty `virt_lines` goes on the counterpart line of the
  other diff window so the side-by-side alignment holds. The counterpart line is taken from nvim's own diff
  alignment: row(l) = l + Σ `diff_filler(k)` for k ≤ l in each window; lines with equal rows are counterparts.
- Decorations use namespaces scoped to the diffy diff windows (`nvim__ns_set(ns, {wins=…})`). A worktree
  buffer also open in another tab shows no diffy marks there.
- `K` / `<CR>` on an anchored line opens a float with the full thread (markdown, suggestion blocks rendered
  as diffs). In the float: `r` reply, `e` edit own draft, `dd` delete own draft, `x` resolve/unresolve (GitHub),
  `q` close.
- `gc` (normal on a line, visual on a range) opens a floating markdown compose buffer anchored below the line.
  `<C-s>` or `:w` saves the draft, `q` cancels. In compose, `<C-g>s` inserts a ```` ```suggestion ```` block
  pre-filled with the anchored lines (GitHub only).
- `]t`/`[t` next/previous thread in the file. `:Diffy threads` opens a quickfix list of all threads for the
  session (including detached and outdated ones), filterable by author, state and review.
- Thread filtering and toggling inline display (`<leader>dt`) never touch the underlying drafts.

### 9.3 Local backend (LLM feed)

- Available in `:Diffy` and `:Diffy branch`.
- Storage: `.git/diffy/<branch>/local.json`, persisted across restarts. Cleared only by
  `:Diffy review clear`.
- `:Diffy review export` writes `.git/diffy/<branch>/review.md` with all non-`sent` comments, marks them
  `sent`, and copies a prompt to the `+` register:
  `Read <abs path to review.md> and address each review comment. Reply per comment id with what you changed.`
  (prompt template configurable).
- `review.md` format:

~~~markdown
# Review of <branch>
base: <base sha> (<base ref>) · head: <HEAD sha> · range: <selection>

## c1 — src/foo.rs:42-45 (new side) · commit a1b2c3d
```rust
<excerpt with 3 lines of context, line-numbered>
```
<details><summary>diff hunk</summary>

```diff
<hunk around the anchor>
```
</details>

<comment body>
~~~

- Commit field: the sha when written in a commit view, `worktree` or `index` otherwise.

### 9.4 GitHub backend

Scope: the PR of the current branch (§4 guarantees local == PR head, clean tree).

**Read** (GraphQL through `gh api graphql`, paginated), cached in memory per session and refreshed with `R`:
- review threads with all comments, `isResolved`, `line/startLine/diffSide`,
  `originalLine/originalStartLine`, per-comment `commit/originalCommit`, `diffHunk` and `pullRequestReview`.
- reviews (author, state, body, submitted_at) for the review filter.
- PR description and conversation comments: `gP` opens them in a read-only markdown float.
- the viewer's own PENDING review, if any.

**Placement** (matches github.com's "Changes" views, which compute this live):
- Every thread has a source anchor `(commit X, path, side, line range)`: the comment's `commit`/`line` if that
  commit exists locally (GitHub's latest remap), else `originalCommit`/`originalLine`.
- In a view whose right side is commit `Y` (a single commit `C`, or HEAD for the full-PR view), a thread is shown
  at `track(X → Y)` when both endpoints of its range are mappable, in either direction of history (lines
  inside the range may have changed). Otherwise it's hidden in that view.
- New-side anchors are tracked to `Y`. Old-side anchors are merge-base coordinates: they show at their line in
  the full-PR view, and in a commit view `C` at `track(merge-base → C^)`, since `C^` is that view's left side.
- Resolved threads are placed like any other but drawn collapsed (sign + summary only). Thread-level
  `startLine` from the API is not used: GitHub reports it already tracked to HEAD while `line` isn't. Anchors
  come from comment-level fields only.
- A thread is **outdated** when it can't be tracked to HEAD. diffy computes this itself; the API's
  `isOutdated`/`line` only update when the PR head is pushed.
- If a placed thread falls on a line that's unchanged in the view (inside a diff fold), the fold is opened
  around it, as github.com adds a context hunk for it.
- `:Diffy threads` always lists everything, with the commits each thread is visible in.

**Line tracking:** a line maps between two blobs of the same file (rename-aware, `git diff -M X Y`) if it lies
outside every changed hunk of their diff (offset by the hunks above it). Otherwise it is unmappable.

**Writing:**
- Comments are local drafts in `.git/diffy/<branch>/pr-<number>.json`, anchored to the commit and lines of the
  view they were written in: commit `C` in a commit view, HEAD in the full-PR view.
- Old-side comments in a commit view are tracked from `C^` to the merge-base (GitHub's LEFT side is always the
  merge-base). If that fails, the draft stays local with a warning.
- An anchor is valid for commit `C` only if it falls inside the `merge-base...C` diff: a changed line or within
  3 context lines of a hunk (file-level comments are always valid). Validation runs before any API call,
  because GitHub rejects the whole review if one thread is invalid.
- `:Diffy review push` (one pending review per user, recreated each time; local drafts are the source of truth):
  1. Delete the viewer's pending review if present.
  2. `addPullRequestReview` with `commitOID` = the commit holding the most drafts, containing that commit's
     threads (multi-line supported).
  3. Single-line drafts on other commits: `addPullRequestReviewComment` (`commitOID`, `position`). It's
     deprecated, but it's the only way to anchor a thread in the same pending review to another commit.
     `position` is the 1-based line index below the file's first `@@` header in the `merge-base...C` diff.
  4. Multi-line drafts on other commits are tracked to HEAD and added with `addPullRequestReviewThread`. If they
     can't be tracked they stay local with a warning.
  5. Draft replies to existing threads: `addPullRequestReviewThreadReply`.
  Renamed files are always addressed by their new path.
- `:Diffy review pull`: imports the viewer's pending review into local drafts, restoring each comment's anchor
  from `originalCommit`/`originalLine`. If local drafts exist that differ, asks before replacing them.
- `:Diffy review submit [comment|approve|request_changes]`: push, then `submitPullRequestReview` with a body
  composed in a float. Drafts are marked `published` and reloaded from GitHub.
- Resolve/unresolve (`x`) calls `resolveReviewThread`/`unresolveReviewThread` directly (not part of the
  draft).

## 10. Architecture

```
nvim/diffy/
  plugin/diffy.lua          -- :Diffy command + completion, nothing else at startup
  lua/diffy/
    init.lua                -- setup(opts), config defaults, keymap table
    git/run.lua             -- async vim.system wrapper, error surfacing
    git/parse.lua           -- log, name-status -z, numstat, status v2, ls-files -u parsers
    git/repo.lua            -- merge-base, base resolution, cleanliness checks
    session.lua             -- tabpage, augroup, state, teardown, registry of sessions
    selection.lua           -- log model → (left rev, right rev) resolution, real-file rule
    panels/tree.lua
    panels/log.lua
    diffpair.lua            -- open left/right buffers, diff mode, winbars, buffer-local keymap tracking
    navigation.lua          -- LSP/BufWinEnter pair swapping
    checkout.lua            -- full checkout + state file + restore
    conflict.lua
    review/model.lua        -- threads, anchors, excerpt relocation, line tracking
    review/ui.lua           -- signs, mirrored virt_lines, floats, compose
    review/store.lua        -- json persistence in .git/diffy/
    review/local.lua        -- export review.md
    review/github.lua       -- gh graphql queries/mutations, push/pull/submit
  tests/                    -- mini.test specs + fixture repo builders
```

- Buffer-local keymaps on real-file buffers are recorded when set and removed when the buffer leaves a
  diffy window or on teardown. Panel and blob buffers are `bufhidden=wipe`.
- Window options changed on diff windows are only changed inside the session tab, which disappears on teardown.

## 11. Testing

diffy is mostly written by an LLM agent, so the test suite is the real spec. A feature counts as done only
when the scenarios listed for its phase (§12) pass. The suite must stay small enough that every test is read.

### 11.1 Harness

- `mini.test`, run headless. Each case drives a **fresh child nvim** (`MiniTest.new_child_neovim`) loaded
  with `tests/minimal_init.lua` (diffy + fugitive + mini.nvim only, pinned revs cloned into
  `nvim/diffy/.deps/`, gitignored).
- Commands, from `nvim/diffy/`: `make test` (whole suite), `make test FILE=tests/test_staging.lua`,
  `make test-gh` (live GitHub, opt-in, §11.4). The whole suite runs in under 60 s.
- **Fixture repos**, built by `tests/helpers/repo.lua` in a temp dir per case, with author/committer dates,
  names and `GIT_CONFIG_GLOBAL=/dev/null` pinned so shas are stable across runs. The builder returns shas by
  label:

  ```lua
  local r = Repo.new()
    :commit('base', { ['f.txt'] = lines(100), ['h.txt'] = lines(40, 'h') })
    :branch('feat'):commit('C1', { ['f.txt'] = edit(10, 'C1') })
    :checkout('main'):commit('M1', { ['f.txt'] = edit(90, 'M') })
    :checkout('feat'):merge('main'):mv('h.txt', 'i.txt'):commit('C3')
  r.sha.C1, r.dir
  ```

  One shared "standard" history (the one used on the GitHub sandbox: edits, re-edit of the same line, rename,
  delete, add, merge from main, line-shifting commit) plus per-case variants.
- **Observation helpers** (`tests/helpers/ui.lua`) describe what the user sees, never diffy's internal tables:
  - `layout()` → `{ tree = lines, log = lines, left = { rev, path, text }, right = {…}, diff = bool }`
  - `threads_visible(side)` → `{ { line = 15, summary = '💬 alice +1' }, … }` read from the extmarks
    actually rendered in that window.
  - `aligned()` → true if both diff windows show matching rows (from `screenrow` of counterpart lines).
  - `git(…)` → runs git in the fixture repo, for asserting the index, HEAD, branch and files on disk.
- **Input goes through real keymaps and commands** (`child.type_keys`, `:Diffy …`). Calling diffy's Lua
  functions directly is only allowed in the pure-logic tests of §11.2.
- **Leak check** runs automatically in the `post_case` hook of every UI test. It closes the session if one is
  still open, then fails the case if any of these remain: a `diffy` augroup, a `diffy://` buffer, a diffy
  buffer-local keymap, an extmark in a diffy namespace, an extra tab/window, or a changed option on a window
  outside the session tab.
- Screenshot references (`expect.reference_screenshot`) only for the layout itself, the mirrored comment
  alignment and the conflict layout. Stored in `tests/screenshots/`, regenerated only on purpose.

### 11.2 Test layers

| Layer | What | Mocks |
|---|---|---|
| Logic | line tracking, anchor validity (hunk ±3), `position` computation, selection → (left, right), git output parsers, review.md rendering | none; inputs come from real git output on fixture repos |
| UI scenarios | everything a user does in §2–§9, through keys | none (real git, real fugitive, real nvim) |
| GitHub | §9.4 read/placement/push/pull/submit through the UI | `gh` transport only (§11.4) |

Git, fugitive and nvim are never mocked. The only fake is the `gh` process.

### 11.3 Rules for every test (enforced in review)

A test is kept only if it would catch a bug a user would notice. Concretely:

1. **Named after a behaviour**, in user terms: `['writing the index buffer stages only the edited hunk']`, not
   `['diffpair.write works']`. Its first comment names the contract section it proves (`-- §5`).
2. **Proven to fail.** Before committing a test, the author breaks the feature it covers (reverts the fix,
   comments out the call) and sees the test go red. The commit message states what was broken:
   `Fails without: index buffer written to worktree path`. A test that can't be made to fail by breaking
   real code is deleted.
3. **Asserts the outcome, not the mechanism**: repo state, buffer text, visible threads, files written,
   window layout. Never which internal function was called, how often, or with what arguments.
4. **Banned outright**: module-loads/function-exists tests; default config values; a mock asserting it
   received what the test handed it; only-"doesn't throw"; length/non-empty checks standing in for content;
   snapshots of internal Lua tables; a second test on the same code path with a trivially different input;
   tests of private helpers already covered by a scenario; tests that pin error message wording.
5. **Boundaries and transitions over happy-path repeats**: first/last commit, merge skipped by navigation,
   rename + edit, empty diff, dirty tree refusal, teardown mid-operation, force-pushed commit missing.
6. **Regression tests** come from real bugs only: reproduce first (red), fix (green), keep.
7. **Budget**: new tests beyond a phase's listed scenarios need a reason in the commit message (a bug, or an
   uncovered boundary). Tests broken by an intentional behaviour change are updated to the new contract or
   deleted, never loosened until they pass.
8. **Deterministic**: no sleeps (wait on diffy's `User DiffyReady` event or `vim.wait` on an observable
   condition), no network outside `make test-gh`, no dependence on the user's config or `$HOME`.

Review step: after each phase, one reviewer pass reads the phase's test diff against these rules and
deletes offenders before the phase is marked done.

### 11.4 GitHub tests

- `review/github.lua` sends every request through one transport function. In tests, the transport is a
  **fake GitHub** (`tests/helpers/fake_github.lua`) implementing the behaviour measured on the sandbox:
  one pending review per user, all-or-nothing thread validation (changed line or ±3 context in
  `merge-base...commit`), per-comment `commit`/`originalCommit`, lazy remap on push, replies and resolve.
  Read responses use GraphQL JSON recorded from the sandbox, so shapes are real.
- Recorded responses come from the sandbox PRs, each built by `nvim/diffy/sandbox/build.js` with a
  description listing every comment and where it must show: #2 placement (tracking across commits,
  force-push, merge, rename, delete, outdated, resolved), #3 content (multi-line bodies, code blocks,
  suggestions, reply chains, resolved threads, conversation comments), #4 pending (an unsubmitted review
  with threads on three commits and a pending reply). These PRs are the reference for what github.com shows.
- `make test-gh` runs the same GitHub test files with `DIFFY_TESTGH=1`: the real `gh` transport against
  `GuillaumeLagrange/diffy-tests`, same keys and assertions. Each case pushes its fixture history to fresh
  uniquely-named branches and opens a new PR (submitted reviews can't be deleted), creates any pre-existing
  state (published/resolved threads, a pending review on several commits) through real API calls, and closes
  the PR and deletes the branches afterwards, even on failure. All write scenarios run live; of the read
  scenarios only the `:Diffy pr` refusals do, since placement depends on PR #2's between-pushes state, which
  can't be recreated cheaply — placement is covered by the responses recorded from the sandbox. It exists
  to catch the fake drifting from GitHub; run before closing phase 7 and
  whenever GitHub behaviour is in doubt. Where the fake and GitHub disagree, the fake is fixed.

## 12. Implementation phases

Each phase ends with its listed scenarios passing, the §11.3 review done, and is usable on its own. The
scenarios are the minimum; each one is a UI test unless marked *(logic)*.

1. **Skeleton, harness & lifecycle.** Plugin dir on rtp, `Makefile`, `minimal_init.lua`, repo builder, UI
   helpers, leak check, session/tab/augroup/teardown, `:Diffy close`.
   - each teardown path (`:tabclose`, `:q` in every managed window, `:bwipe` of a panel, `:Diffy close`,
     closing nvim) leaves no leak;
   - two sessions in two tabs: closing one leaves the other fully working;
   - the leak check itself fails when a deliberately leaked augroup/buffer/keymap/extmark is left behind.
2. **Range viewer.** git layer, log panel (merges dimmed/skipped), tree panel, diff pair, panel toggle,
   `:Diffy A..B`, `:Diffy branch`, contiguous selection, file/commit navigation, `R`.
   - `:Diffy branch` on the standard history: log lists branch commits, merge dimmed; `]r` from the commit before
     the merge lands on the commit after it;
   - selecting C1..C2 shows `f.txt` with left = base content and right = C2 content;
   - the rename shows as one `R h.txt → i.txt` entry whose sides are the old and new file;
   - the panel toggle hides the column (diff windows span the full width, the session stays alive, `]f` still
     moves files) and shows it again with the same content; teardown while hidden leaks nothing;
   - a long path under nested directories renders as one row that fits the panel width, status and counts
     visible;
   - base resolution: explicit arg, then PR base, then origin default branch *(logic)*;
   - screenshot: default layout.
3. **Index & status.**
   - `:Diffy` with unstaged edits: `Unstaged` selected, left = index, right = worktree file;
   - editing the left side and `:w` stages exactly that hunk (`git diff --cached` checked);
   - `s`/`u` on a file and on a staged rename pair stage/unstage both paths;
   - an unstaged rename shows as `D` + `?`, and as `R` after `git add -N`;
   - staging keys do nothing (with a message) when the selection isn't exactly `Unstaged` or `Staged`.
4. **Navigation & full checkout.**
   - jumping to another file in the diff (via `:e`, standing in for LSP) swaps both sides and highlights the
     tree; jumping outside the diff turns diff mode off and shows the placeholder; `<C-o>` restores the pair;
   - `X` on a commit with a dirty tree refuses and leaves HEAD untouched;
   - `X` then closing the tab returns to the original branch;
   - nvim killed during a checkout: the next `:Diffy` warns, and `:Diffy restore` returns to the branch.
5. **File history & conflicts.**
   - `:Diffy file` follows a file across its rename;
   - merge conflict: 4-window layout (screenshot), `gho`/`ght` take hunks, `s` marks resolved;
   - `s` with conflict markers left asks for confirmation;
   - the same flow during a rebase conflict.
6. **Review core + local backend.**
   - `gc` on a range + `<C-s>` shows the sign and summary; the other side gets matching blank lines, so
     `aligned()` stays true (plus a screenshot);
   - drafts survive restarting nvim;
   - editing lines above an anchored comment moves it with its excerpt; deleting its lines makes it detached
     and listed in `:Diffy threads`;
   - `:Diffy review export` writes the documented `review.md` for comments on worktree, index and commit
     views, marks them sent, and puts the prompt in `+`;
   - comment decorations don't show in a window outside the session showing the same file.
7. **GitHub backend** (fake GitHub; the same scenarios via `make test-gh`).
   - placement matches the sandbox observations: a comment written on C1 shows at its tracked line at head and
     in C1's view, is hidden in C2's view when C2 changed its line, and is labelled outdated;
   - a thread on a line unchanged in the viewed commit opens the fold around it;
   - `position` computation for multi-hunk files *(logic)*;
   - push with one invalid draft sends nothing for it, keeps it local with a warning, and pushes the rest;
   - push with drafts on two commits: each lands on its commit; a multi-line draft on the second commit is
     tracked to HEAD;
   - pull restores drafts at their original commits and lines;
   - reply, resolve/unresolve, submit;
   - `:Diffy pr` refuses when local HEAD differs from the PR head or the tree is dirty.
8. **Migration.** Remove diffview (`nvim/plugin/diffview.lua`, lock entry), remap `<leader>dv*` to diffy,
   drop octo/diffview patterns from `lua/session.lua` and `lua/utils/init.lua`, add `diffy://` to ephemeral
   buffer patterns. No new tests; the suite stays green.

## 13. Known risks

- `nvim__ns_set` is an experimental API. Fallback: a decoration provider that draws only in diffy windows.
- `addPullRequestReviewComment` (per-commit threads, §9.4) is deprecated. If GitHub removes it, single-line
  drafts on non-primary commits fall back to step 4 (track to HEAD).
- A thread whose commit was force-pushed away may not exist locally: placement uses `commit`/`line` first,
  and a thread with neither commit available is only listed in `:Diffy threads`.
- Large PRs: GraphQL pagination and log/tree size. Panels render lazily and git output streams.

## 14. Later (not planned)

- Single-buffer view showing all files' diffs inline with file navigation (the data model and review anchors
  must not assume two windows).
- Applying GitHub suggestion blocks locally.
- Opening PRs other than the checked-out branch.
- Arbitrary (non-contiguous) commit selection.
