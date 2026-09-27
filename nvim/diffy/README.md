# diffy

A diff viewer for Neovim built on git and fugitive, with a review layer: comment on diffs, then either
hand the comments to an LLM agent or push them as a GitHub pull request review.

Each `:Diffy` session lives in its own tab: a panel column (changed files on top, commits below) and a
side-by-side diff in native diff mode. Closing the tab in any way (`:tabclose`, `:q` in a diffy window,
`:Diffy close`, quitting nvim) cleans everything up.

## Requirements

- Neovim ≥ 0.12, git ≥ 2.36
- [vim-fugitive](https://github.com/tpope/vim-fugitive): blob and index buffers
- [`gh`](https://cli.github.com), authenticated: `:Diffy pr`, and base-branch detection for `:Diffy branch`
- Optional, for GitHub avatars: a terminal with the kitty graphics protocol (kitty, ghostty, WezTerm; also
  inside zellij ≥ 0.45, not tmux), `curl` and ImageMagick

## Install

Put the `diffy` directory on the runtimepath, e.g. `vim.opt.rtp:prepend('/path/to/diffy')` (in this dotfiles
repo, `nvim/plugin/diffy.lua` does it). `setup` is optional:

```lua
require('diffy').setup({
  panel_width = 40,               -- width of the files/commits column
  keymaps = {
    toggle_panel = '<leader>e',   -- hide/show the panel column, in every diffy window
  },
  -- copied to `+` by `:Diffy review export`; %s is the absolute path of review.md
  review_prompt = 'Read %s and address each review comment. Reply per comment id with what you changed.',
  avatars = true,                 -- GitHub avatars in comment headers, when the terminal can draw them
})
```

## Commands

| Command | Shows | Selected at start |
|---|---|---|
| `:Diffy` | Unstaged, Staged, commits `@{u}..HEAD` (or the last 20) | Unstaged |
| `:Diffy branch [base]` | Unstaged, Staged, commits since the merge-base with `base` | all commits |
| `:Diffy A..B`, `:Diffy A...B` | the commits of the range | all |
| `:Diffy pr` | the commits of the current branch's pull request | all |
| `:Diffy file [path]` | commits touching the file (default: current buffer), across renames | newest |
| `:Diffy conflicts` | conflicted files, in the conflict view | first file |
| `:Diffy panel` | hide/show the panel column | |
| `:Diffy threads [author=… state=… review=…]` | quickfix list of every review thread (`state`: open, resolved, outdated, detached) | |
| `:Diffy review export\|clear` | local review, see below | |
| `:Diffy review push\|pull\|submit [comment\|approve\|request_changes]` | GitHub review, see below | |
| `:Diffy restore` | go back to your branch after an interrupted full checkout | |
| `:Diffy close` | close the session | |

`:Diffy branch` without an argument uses the PR base of the current branch, then `origin`'s default branch.

## The panels

**Commits** (bottom). The diff always shows one contiguous selection: left is the parent of the oldest
selected entry, right is the newest one. `Unstaged` means index → worktree, `Staged` means HEAD → index.
Merge commits are dimmed and skipped. In branch and PR views, a selection reaching the oldest commit
compares against the merge-base, like github.com, so changes merged in from the base branch don't show up.

| Key | |
|---|---|
| `<CR>` | select the entry under the cursor |
| `v`/`V` + motion, `<CR>` | select a range |
| `a` | select everything |
| `J` / `K` | select the next / previous commit |
| `X` | full checkout of the selected commit (see below) |

**Files** (top): status letter, path relative to its folder, `+added -removed`. The file shown in the diff
is highlighted.

| Key | |
|---|---|
| `<CR>` | open the file and move to the diff |
| `o` | open the file, stay in the tree |
| `za` | fold a folder |
| `gf` | open the real file in the previous tab |
| `s` / `u` / `-` | stage / unstage / toggle the file (a rename stages both paths) |
| `S` / `U` | stage / unstage everything |

Staging works only when the selection is exactly `Unstaged` or `Staged`. You can also stage hunk by hunk:
with `Unstaged` selected the left side is the index, so `do`/`dp` or editing it and `:w` stages; with
`Staged` selected the right side is the index.

## The diff

The right side is the real file (LSP, editable) when it shows the worktree, or HEAD for a file with no
uncommitted changes. Otherwise both sides are read-only fugitive blobs. Jumping to another file from the
right side (go-to-definition, `gf`, `:e`) loads that file's pair if it's part of the diff; otherwise diff
mode turns off until you come back (`<C-o>` or the tree).

| Key (in either diff window) | |
|---|---|
| `]f` / `[f` | next / previous file |
| `]r` / `[r` | next / previous commit |
| `R` | refresh everything: git state, panels, window sizes |
| `<leader>e` | hide / show the panel column |

**Full checkout.** `X` on a single commit checks it out (detached) so the right side becomes real files with
LSP. Leaving it (selecting something else, `X` again, closing the session) checks your branch out again.
It refuses when you have tracked changes. If nvim dies in between, the next `:Diffy` offers `:Diffy restore`.

**Conflicts.** `:Diffy conflicts`, or opening a `U` file, shows ours, base and theirs on top and the
result (the real file) below. Works for merge, rebase, cherry-pick and stash pop.

| Key | |
|---|---|
| `gho` / `ghb` / `ght` (in the result) | take ours / base / theirs for the conflict under the cursor |
| `]x` / `[x` (in the result) | next / previous conflict marker |
| `s` (in the tree) | mark resolved (`git add`); asks first if markers remain |

## Review

Comments show as a 💬 sign on their line and a one-line summary under it (author, reply count, first line
of the comment). The other side gets matching blank lines so the diff stays aligned.

| Key (in a diff window) | |
|---|---|
| `gc` | comment on the line (visual mode: on the range); `<C-s>` or `:w` saves, `q` cancels |
| move onto a commented line | preview its thread, over the other diff window, with its lines marked |
| `K` / `<CR>` | enter the thread float |
| `]t` / `[t` | next / previous thread, including several on the same line |
| `<leader>dt` | hide / show comments inline |
| `gP` | PR description and conversation (`:Diffy pr`) |

Threads open as a card over the other diff window. Each comment gets a header strip: avatar, author (on
GitHub; "You" in a local review), age, and its state when it isn't published yet: `draft` (only in
diffy), `pending` (in your unsubmitted GitHub review), `sent` (exported to the agent). The first header
also says `outdated` or `✓ resolved`. Bodies render as markdown; suggestion blocks are labelled, empty
ones as "remove these lines". A preview taller than half the window is cut, with a hint to press `K`.

In the thread float, the footer lists the keys that apply: `r` reply, `e` edit your draft, `dd` delete
your draft, `x` resolve/unresolve, `]t`/`[t` switch thread, `q` close. In the compose float, `<C-g>s`
inserts a GitHub suggestion block with the commented lines. `gP` shows the PR description and its
conversation the same way.

Avatars need a terminal with the kitty graphics protocol, `curl` and ImageMagick. They're downloaded once
and cached in `stdpath('cache')/diffy/avatars`; without them the headers are text only.

Local comments follow the code: after edits they're found again by their text within ±20 lines. When they
can't be, they're listed in `:Diffy threads` as detached.

### Local review, for an LLM agent

Available in `:Diffy` and `:Diffy branch`. Drafts are saved in `.git/diffy/<branch>/local.json`.

`:Diffy review export` writes `.git/diffy/<branch>/review.md` with every comment not yet sent (location,
side, commit, the code with context, the diff hunk, the comment), marks them sent and copies the prompt to
the `+` register: paste it to your agent. `:Diffy review clear` deletes the local review.

### GitHub review

`:Diffy pr` opens the pull request of the checked-out branch. It refuses unless your `HEAD` is the PR head
on GitHub and the tree is clean.

- Threads are placed like github.com's "Changes" view: in the full view and in each commit's view, at the
  line they track to, hidden where their lines changed. Outdated threads (not trackable to HEAD) and
  everything else are in `:Diffy threads`, with the commits each thread is visible in.
- Your comments are local drafts (`.git/diffy/<branch>/pr-<number>.json`) until you push.
- `:Diffy review push` replaces your pending review on GitHub with your drafts. Each lands on the commit
  you wrote it in. Drafts GitHub would reject (outside the diff and its 3 lines of context) stay local
  with a warning.
- `:Diffy review pull` imports your pending review from GitHub (it asks before replacing local drafts).
- `:Diffy review submit [comment|approve|request_changes]` pushes, then submits with a message you type.
- `x` resolves or unresolves a thread on GitHub immediately.
- `R` refreshes from GitHub.

## Highlights

All set with `default = true`, so a colorscheme or your config can override any of them:

| Group | Default | |
|---|---|---|
| `DiffyAdded` / `DiffyChanged` / `DiffyRemoved` / `DiffyConflict` | `Added` / `Changed` / `Removed` / `DiagnosticError` | status letters, counts |
| `DiffyDirectory`, `DiffySha`, `DiffyLabel`, `DiffyMerge` | `Directory`, `Identifier`, `Title`, `Comment` | tree folders, log rows |
| `DiffySelection` | `Visual` | selected commits |
| `DiffyCurrentFile`, `DiffyCurrentFileName` | `Visual`, bold | the file shown in the diff |
| `DiffyThreadSummary` / `DiffyThreadRelevant` / `DiffyThreadCurrent` | `Comment` / `Special` / `PmenuSel` | comment summaries: others / on the cursor line / open |
| `DiffyThreadRange` | `PmenuSel` | line numbers of the open thread's lines |
| `DiffyThread` / `DiffyThreadHeader` | background of `CursorLine` / `Pmenu` | comment cards / their header strips |
| `DiffyThreadAuthor`, `DiffyThreadAuthor1`…`5` | bold, `Identifier` `DiagnosticHint` `Constant` `Title` `Function` | author names, a colour per login |
| `DiffyThreadTime` | `Comment` | comment age |
| `DiffyThreadDraft` / `DiffyThreadPending` / `DiffyThreadSent` | `DiagnosticWarn` / `DiagnosticInfo` / `Comment` | comment states |
| `DiffyThreadResolved` / `DiffyThreadOutdated` | `DiagnosticOk` / `DiagnosticWarn` | thread states |
| `DiffyThreadCodeBar` / `DiffyThreadSuggestion` | `Comment` / `Added` | code block bar / suggestion bar and label |
| `DiffyThreadKey` / `DiffyThreadHint` | `Special` / `Comment` | footer keys / their labels |

## Tests

From this directory: `make test` (the whole suite, about 45 s), `make test FILE=tests/test_staging.lua`.
`make test-gh` runs the GitHub tests against the real sandbox repository, opening and closing a throwaway
PR per test.
