# AGENTS.md

Orientation for working on agent-diff.nvim. Read this before editing.

## What it is

Inline visualization of what a CLI coding agent (currently Claude Code) writes,
rendered as extmarks in the buffer. Visualize-only: there is no accept/reject here —
that decision lives in the agent's chat. Everything downstream of "here is a before
and after pair of a file" is backend-neutral.

## Data flow

```
Claude hook (PreToolUse/PostToolUse/Stop)
  → agent-diff-hook.sh          (shell, in Claude's subprocess; base64s the JSON)
  → nvim RPC via $NVIM socket   (luaeval → claude.on_event)
  → claude.lua                  (ADAPTER: Claude payload → Edit model)
  → core.lua                    (backend-neutral: history, resolve buffer, navigate)
  → diff.lua                    (before/after lines → hunks)
  → render.lua                  (hunks → extmarks)
```

`agent-diff-hook.sh` lives OUTSIDE this dir — at `claude/hooks/agent-diff-hook.sh` in
the dotfiles repo — and is registered in `claude/settings.json`. Editing the event
set, or how the payload is encoded, means touching all three: the hook script,
`settings.json`, and `claude.lua`'s `on_event`.

## Module boundaries — keep them

- **`claude.lua` is the only file that knows Claude exists.** Hook payload shapes,
  `Edit`/`Write`/`MultiEdit` semantics, PreToolUse-before-PostToolUse ordering — all
  confined here. A second backend is a second adapter against the same `Core` API
  (`preview`, `apply`, `clear`). Do not leak agent concepts into core/diff/render.
- **`core.lua`** owns the edit model, the navigable history, buffer resolution, and
  the single-diff-on-screen invariant. Knows nothing about any agent.
- **`diff.lua` / `render.lua`** are pure: (old, new) → hunks → extmarks. No agent, no
  history, no buffer resolution.

## Invariants you must not break

- **One diff on screen at a time**, across all buffers. Every render path calls
  `hide_all()` before placing marks. History entries persist across hides — hiding
  drops the *rendering*, not the *entry*, so they stay navigable and re-render on `[a`/`]a`.
- **History survives; pending does not.** Applied edits accumulate in `history` for
  the session (capped by `queue.max`, oldest trimmed with `nav_cursor` adjusted).
  Pending previews are keyed by path and dropped on the next `apply`/`preview`/hide —
  they track a proposal, not a fact.
- **Never render over a modified buffer.** `resolve()` returns `modified` and bails:
  on-screen content there differs from the disk the diff was computed against. The
  autoclear autocmd (`init.lua`) also wipes a diff the instant the user actually edits
  (gated on `bo.modified`, because a `checktime` reload also fires `TextChanged`).
- **Never steal focus or move windows while the user is typing.** `navigate` early-
  returns in insert/replace/terminal mode. Applied edits use `_reveal` (moves the diff
  window's cursor, keeps user focus); explicit navigation uses `_focus` (switches
  window, deliberately).
- **Passive auto-display only acts on an unambiguous layout.** `target_win()` returns a
  window only when there is exactly *one* editor window (the sidekick panel doesn't
  count); with zero or several it returns nil and the edit defers rather than `:edit`
  over a split the user is viewing. Explicit `[a`/`]a` navigation bypasses this and
  targets the current window on purpose (`resolve(path, force=true)`).
- **Only track edits inside the repo (`repo_only`).** `preview`/`apply` drop edits whose
  path is outside the git worktree containing the editor's cwd — agents also write
  scratchpads and `/tmp`, which shouldn't render or enter history. The repo root is
  memoized per cwd.

## Gotchas already handled — don't regress

- **Resolve buffers by exact path, never `vim.fn.bufnr()`.** `bufnr()` regex/substring-
  matches its argument, so `app.ts` can bind to an open `app.ts.snap`, painting or
  clearing a diff on the wrong file. `buf_for_path()` compares resolved (`:p`) names for
  equality. The adapter's failed-edit path uses `Core.clear_path(path)` (path-keyed) for
  the same reason — and because a rejected off-screen edit has no buffer yet, only an
  armed defer.
- **Every path that drops an edit must cancel its armed defer.** An edit whose file
  wasn't on screen arms a `_defer_until_open` autocmd holding its entry. If the entry is
  dropped without cancelling that autocmd — on explicit clear, on `trim_history`
  eviction, on a superseding preview/apply, or on a failed edit — the autocmd later
  fires and repaints a diff that was cleared or is no longer navigable. `drop_pending`,
  `clear_path`, `trim_history`, and `M.clear(nil)` all call `cancel_defer`.
- **`_defer_until_open` matches on buffer name in the callback, not an autocmd file
  pattern.** Patterns split on commas and glob `[ ] * ?`, which silently breaks paths
  like Next.js `[slug]` routes.
- **Deleted lines from multiple hunks can share an anchor row.** histogram + linematch
  fragments a whole-file replace into interleaved add/delete hunks; `render.hunks`
  accumulates per anchor and emits one ordered `virt_lines` block so phantom lines
  don't stack out of order.
- **Added-line highlight ends at the last added row's EOL**, not column 0 of the next
  row — an end at `(next_row, 0)` with `hl_eol` paints a stray cell on the following
  unchanged line.
- **Line splitting mirrors `readfile`**: a single trailing newline must not produce a
  spurious empty last line. See `claude.split` and `diff.join`.
- **The diff baseline is the PreToolUse snapshot, with a fallback.** `on_post` diffs the
  post-write content against `snapshot[abs]` captured at PreToolUse. When that snapshot
  is missing (the hook is fire-and-forget; a PreToolUse can be dropped), `reverse_apply`
  reconstructs the pre-edit content by inverting the tool input against the new content
  — diffing against nothing would light the whole file up as added. Write has no
  recoverable baseline and legitimately renders as all-added.
- **Extmark placement is `pcall`-wrapped** (`render.set`): a bad row / unknown opt on
  some build degrades gracefully instead of aborting the whole render.
- **`_defer_until_open` and per-buffer autoclear create augroups named `agent_diff*`.**
  `teardown()` finds and deletes every such group by scanning registered autocmds.
  New augroups must keep the prefix or teardown/reload leaks them.

## Editing safely

- Everything from the hook runs through `vim.schedule` (`claude.on_event`): the RPC
  handler is a fast-event context where buffer/extmark APIs are restricted. Keep new
  work deferred.
- Row math is a minefield: `diff.lua` converts vim.diff's 1-based indices, and a pure
  deletion (`cb == 0`) anchors differently from a change/add. Re-read the comments in
  `diff.hunks` before touching `b_start`.
- After changing anything, run the suite: `just test` from this directory. Add or
  update specs in `tests/` — `diff_spec`, `core_spec`, `render_spec` cover the three
  pure/near-pure layers. `tests/minimal_init.lua` scopes the runtimepath so only
  `agent-diff.*` resolves; don't require sibling modules by bare name in tests.
- Use `:AgentDiffReload` (or `M.reload()`) to hot-reload in a live nvim — it tears
  down, drops the `agent-diff*` module cache, and re-runs `setup` with the last opts.
