--- Backend-neutral core: the edit model, the navigable edit history, and the
--- apply/preview/clear/navigate operations. Adapters hand it edits; it owns
--- buffer resolution and drives the renderer. Knows nothing about any agent.

local Diff = require('agent-diff.diff')
local Render = require('agent-diff.render')

local M = {}

---@class AgentDiff.Edit
---@field path string           absolute file path
---@field kind "applied"|"pending"
---@field old_file string[]|nil pre-edit content; nil renders as all-added
---@field new_file string[]     post-edit content

---@class AgentDiff.Entry
---@field path string
---@field kind "applied"|"pending"
---@field old_file string[]|nil pre-edit content, kept so a hidden edit can be re-rendered
---@field new_file string[]     post-edit content, kept so a hidden edit can be re-rendered
---@field bufnr integer|nil     buffer the edit is currently rendered in; nil when hidden
---@field extmark_ids integer[]|nil placed marks; nil when hidden

M.config = {
  -- Cap on the navigable edit history; the oldest entries are dropped past it.
  queue = { max = 50 },
  -- When the agent edits a file that isn't currently on screen, bring it into
  -- the editor window (loading it if needed) so the diff is visible — but only
  -- when the layout is unambiguous (exactly one normal editor window besides the
  -- sidekick panel). Otherwise leave the layout alone.
  autodisplay = true,
  -- Only track edits to files inside the git worktree containing the editor's
  -- cwd. Agents write outside the project too (scratchpads, /tmp); those edits
  -- are dropped outright — not previewed, not rendered, not added to history.
  repo_only = true,
}

--- Absolute path of the git worktree root containing the editor's cwd, or nil if
--- cwd is not in a git repo. Memoized per cwd so the common case is one shell-out.
local repo_root_cache = {}
local function repo_root()
  local cwd = vim.fn.getcwd()
  local cached = repo_root_cache[cwd]
  if cached ~= nil then
    return cached or nil -- false = "not a repo", memoized
  end
  local out = vim.fn.systemlist({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' })
  local root = (vim.v.shell_error == 0 and out[1] and out[1] ~= '') and vim.fn.fnamemodify(out[1], ':p') or false
  repo_root_cache[cwd] = root
  return root or nil
end

--- Whether `path` (absolute) sits inside the editor's git worktree. False when
--- there is no repo, or the path is outside it. Gates which edits get tracked at
--- all, so off-project writes (scratchpads, /tmp, other repos) are ignored.
---@param path string
---@return boolean
local function in_repo(path)
  local root = repo_root()
  if not root then
    return false
  end
  root = root:gsub('/$', '') .. '/'
  return path:sub(1, #root) == root
end

---@type AgentDiff.Entry[]  insertion-ordered applied edits — the navigable history.
--- Entries persist across hides (user edit, Esc, on-demand clear): hiding only
--- drops their rendering, so they stay navigable. Reset only on restart.
local history = {}
---@type table<string, AgentDiff.Entry>  pending edits keyed by path (preview state)
local pending = {}
local nav_cursor = nil ---@type integer? index into `history`

--- Hide every currently-shown diff (defined below). Only one edit's diff is ever
--- rendered at a time across all buffers, so a new render clears the rest first.
local hide_all

--- Buffer whose full path is exactly `path`, or -1 if none is loaded. Unlike
--- vim.fn.bufnr(), which regex/substring-matches the argument and can bind to an
--- unrelated buffer whose name merely contains `path` (e.g. `app.ts` matching an
--- open `app.ts.snap`), this compares resolved names for equality.
---@param path string absolute path
---@return integer bufnr  -1 when no loaded buffer matches
local function buf_for_path(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':p') == path then
      return buf
    end
  end
  return -1
end

--- A window is a normal editor window if it holds a regular file buffer, is not
--- floating, and is not the sidekick CLI panel.
---@param win integer
---@return boolean
local function is_editor_win(win)
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return false -- floating (pickers, explorer overlays, ...)
  end
  if vim.w[win].sidekick_cli ~= nil then
    return false -- the sidekick panel
  end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
end

--- The window to passively auto-display an edit in: the sole editor window in the
--- tab. nil when there is none (focus is on the sidekick panel with nothing else
--- open) or when there is more than one — an ambiguous layout where `:edit`ing the
--- file would swap a buffer the user is actively viewing out from under them.
--- Explicit navigation doesn't use this; it targets the current window directly.
---@return integer? win
local function target_win()
  local found ---@type integer?
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_win(win) then
      if found then
        return nil -- more than one editor window: ambiguous, don't steal
      end
      found = win
    end
  end
  return found
end

--- Resolve a path to a buffer that is visible on screen, so the diff can be
--- seen. When it isn't visible, load it and show it: on an explicit navigation
--- (`force`) in the current window; otherwise, passively, only in the lone editor
--- window when the layout is unambiguous (see `autodisplay`). Returns nil if the
--- file can't be safely surfaced, or if a visible buffer has unsaved edits — its
--- on-screen content then differs from the disk the diff was computed against.
---@param path string
---@param force boolean?  surface into the current window even if the layout is ambiguous
---@return integer? bufnr
---@return "not_open"|"modified"|nil reason  why no bufnr (nil when bufnr is returned)
local function resolve(path, force)
  local bufnr = buf_for_path(path)

  local visible = bufnr ~= -1 and #vim.fn.win_findbuf(bufnr) > 0
  if not visible then
    -- Only surface files that already exist on disk: `:edit`ing a path with no
    -- file yet opens an empty buffer, and once the agent's write lands under it
    -- vim raises W13 ("created after editing started"). A brand-new file has no
    -- on-disk baseline to diff against anyway.
    if vim.fn.filereadable(path) ~= 1 then
      return nil, 'not_open'
    end
    -- Passive auto-display picks the lone editor window and bails when ambiguous;
    -- an explicit navigation targets the window the user is in.
    local win
    if force then
      win = vim.api.nvim_get_current_win()
    elseif M.config.autodisplay then
      win = target_win()
    end
    if not win then
      return nil, 'not_open'
    end
    -- Show the file in the editor window, loading it if needed. `:edit` keeps
    -- the buffer listed and reads the current disk content.
    local ok = pcall(vim.api.nvim_win_call, win, function()
      vim.cmd.edit(vim.fn.fnameescape(path))
    end)
    if not ok then
      return nil, 'not_open'
    end
    bufnr = buf_for_path(path)
  end

  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, 'not_open'
  end
  if vim.bo[bufnr].modified then
    return nil, 'modified'
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd.checktime()
  end)
  return bufnr
end

local cancel_defer ---@type fun(path: string)

--- Drop the oldest history entries beyond the cap, clearing any marks they still
--- have on screen. Adjusts nav_cursor so it keeps pointing at the same entry.
local function trim_history()
  while #history > M.config.queue.max do
    local old = table.remove(history, 1)
    if old.bufnr and old.extmark_ids then
      Render.clear_ids(old.bufnr, old.extmark_ids)
    end
    -- A trimmed entry may still have a defer armed (its file never opened); cancel
    -- it, or opening that file later renders an edit no longer in history.
    cancel_defer(old.path)
    if nav_cursor then
      nav_cursor = nav_cursor > 1 and nav_cursor - 1 or nil
    end
  end
end

local rerender_entry ---@type fun(entry: AgentDiff.Entry, force?: boolean): integer?

--- Build an entry for an edit and render it now if its file is on screen. A
--- deferred entry (file not visible, or mid-edit) still comes back fully formed
--- with bufnr/extmark_ids nil, so it stays navigable and re-renders later — an
--- applied edit belongs in history whether or not its file is open right now.
--- Returns nil only when there's nothing to show at all (empty diff).
---@param edit AgentDiff.Edit
---@return AgentDiff.Entry?
local function render_edit(edit)
  local path = vim.fn.fnamemodify(edit.path, ':p')
  local hunks = Diff.hunks(edit.old_file, edit.new_file)
  if #hunks == 0 then
    return nil
  end

  local entry = {
    path = path,
    kind = edit.kind,
    old_file = edit.old_file,
    new_file = edit.new_file,
  } ---@type AgentDiff.Entry

  local bufnr, reason = resolve(path)
  if bufnr then
    hide_all()
    entry.bufnr = bufnr
    entry.extmark_ids = Render.hunks(bufnr, hunks, edit.kind)
  elseif reason == 'not_open' then
    -- Re-render once the file is opened, but not for a buffer that is merely
    -- mid-edit: its content differs from disk and there's nothing safe to show.
    M._defer_until_open(path, function()
      rerender_entry(entry)
    end)
  end
  return entry
end

--- Re-render a history entry that was hidden, placing fresh marks in its buffer.
--- `force` surfaces the file into the current window even if the layout is
--- ambiguous — used when the user explicitly navigates to the edit. Returns the
--- buffer it landed in, or nil if the file can't be surfaced.
---@param entry AgentDiff.Entry
---@param force boolean?
---@return integer? bufnr
function rerender_entry(entry, force)
  local bufnr, reason = resolve(entry.path, force)
  if not bufnr then
    -- Only a passive re-render defers; a forced navigation that still can't
    -- surface the file (e.g. deleted, or the buffer is mid-edit) just fails.
    if reason == 'not_open' and not force then
      M._defer_until_open(entry.path, function()
        rerender_entry(entry)
      end)
    end
    return nil
  end
  local hunks = Diff.hunks(entry.old_file, entry.new_file)
  if #hunks == 0 then
    return nil
  end
  hide_all()
  entry.bufnr = bufnr
  entry.extmark_ids = Render.hunks(bufnr, hunks, entry.kind)
  return bufnr
end

--- Cancel a pending `_defer_until_open` for `path`, if one is armed. A preview that
--- deferred (file not on disk / off screen) leaves an autocmd holding its entry; if
--- the path is superseded before it fires — an apply on a just-created file opens the
--- file and would trigger the stale preview re-render — the mark it places is tracked
--- by nothing and never clears. Drop the autocmd whenever the pending entry is dropped.
---@param path string absolute path
function cancel_defer(path)
  pcall(vim.api.nvim_del_augroup_by_name, 'agent_diff_defer_' .. path)
end

--- Drop the pending preview for `path`: clear its on-screen marks, forget the
--- entry, and cancel any armed defer for it. The defer cancel matters even when
--- there is no pending entry — a deferred preview whose file never opened leaves
--- only the autocmd behind, which would otherwise fire later and paint a stale diff.
---@param path string absolute path
local function drop_pending(path)
  local prev = pending[path]
  if prev and prev.bufnr and prev.extmark_ids then
    Render.clear_ids(prev.bufnr, prev.extmark_ids)
  end
  pending[path] = nil
  cancel_defer(path)
end

--- Run `cb` once the file at `path` is opened. Used to render an edit whose file
--- isn't on screen yet.
---@param path string absolute path
---@param cb fun()
function M._defer_until_open(path, cb)
  local group = vim.api.nvim_create_augroup('agent_diff_defer_' .. path, { clear = true })
  -- Match on buffer name in the callback rather than an autocmd file-pattern:
  -- patterns split on commas and treat [ ] * ? as globs, which silently fail for
  -- paths containing those characters (e.g. Next.js `[slug]` routes).
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, {
    group = group,
    pattern = '*',
    callback = function(args)
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ':p') ~= path then
        return
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
      cb()
    end,
  })
end

--- Preview a proposed (not-yet-written) edit. Replaces any prior pending for the
--- same path.
---@param edit AgentDiff.Edit
function M.preview(edit)
  edit.kind = 'pending'
  local path = vim.fn.fnamemodify(edit.path, ':p')
  if M.config.repo_only and not in_repo(path) then
    return
  end
  drop_pending(path)
  local entry = render_edit(edit)
  if entry then
    pending[path] = entry
  end
end

--- Register an applied edit (the write has landed). Clears any pending preview
--- for the path first, then renders the applied diff and appends it to history.
---@param edit AgentDiff.Edit
function M.apply(edit)
  edit.kind = 'applied'
  local path = vim.fn.fnamemodify(edit.path, ':p')
  if M.config.repo_only and not in_repo(path) then
    return
  end
  drop_pending(path)
  local entry = render_edit(edit)
  if entry then
    history[#history + 1] = entry
    -- The freshly applied edit is the one now shown, so anchor the cursor on it:
    -- `[a` then steps to the edit before it, `]a` reports there's no next.
    nav_cursor = #history
    trim_history()
    -- Move the diff window's cursor onto the change so the latest edit is
    -- surfaced, without stealing the user's focus.
    M._reveal(entry)
  end
end

--- Drop an entry's on-screen marks without forgetting the entry, so it stays
--- navigable and can be re-rendered later.
---@param entry AgentDiff.Entry
local function hide_entry(entry)
  if entry.bufnr and entry.extmark_ids then
    Render.clear_ids(entry.bufnr, entry.extmark_ids)
  end
  entry.bufnr = nil
  entry.extmark_ids = nil
end

-- Forward-declared above so the render paths can enforce the single-diff
-- invariant. Hides every shown history entry and drops all pending previews.
function hide_all()
  for _, entry in ipairs(history) do
    if entry.bufnr then
      hide_entry(entry)
    end
  end
  for path in pairs(pending) do
    drop_pending(path)
  end
end

--- Whether any agent-diff highlight is currently on screen (applied or pending).
--- Lets a caller (e.g. an Esc mapping) fall through when there's nothing to hide.
---@return boolean
function M.is_showing()
  for _, entry in ipairs(history) do
    if entry.bufnr then
      return true
    end
  end
  return next(pending) ~= nil
end

--- Forget all history and pending previews and drop their marks. Not wired to
--- any user action (in-session history is kept deliberately); it exists so tests
--- can reset the module between cases.
function M._reset()
  M.clear()
  history = {}
  nav_cursor = nil
end

--- Hide highlights without forgetting the edits — history stays navigable and a
--- hidden edit re-renders when navigated to. bufnr = just that buffer's marks;
--- nil = every currently-shown edit. Pending previews are dropped outright (they
--- track a proposal, not history).
---@param bufnr integer?
function M.clear(bufnr)
  if bufnr == nil then
    hide_all()
    -- hide_all cancels defers only for pending previews. An applied edit can also
    -- have armed a defer (its file was off-screen when the write landed); on an
    -- explicit dismiss, cancel those too, or opening the file later revives a diff
    -- the user just cleared. The entry stays navigable — a later [a re-arms it.
    for _, entry in ipairs(history) do
      cancel_defer(entry.path)
    end
    return
  end
  for _, entry in ipairs(history) do
    if entry.bufnr == bufnr then
      hide_entry(entry)
    end
  end
  for path, entry in pairs(pending) do
    if entry.bufnr == bufnr then
      if entry.extmark_ids then
        Render.clear_ids(entry.bufnr, entry.extmark_ids)
      end
      pending[path] = nil
    end
  end
end

--- Clear every diff — applied or pending — associated with `path`: hide history
--- entries for it (they stay navigable), drop its pending preview, and cancel any
--- armed defer. Path-keyed rather than buffer-keyed so it works even when the file
--- has no buffer yet (a deferred preview), which is exactly the failed-edit case
--- the adapter needs: a rejected off-screen edit must not resurface later.
---@param path string absolute path
function M.clear_path(path)
  path = vim.fn.fnamemodify(path, ':p')
  for _, entry in ipairs(history) do
    if entry.path == path then
      hide_entry(entry)
    end
  end
  drop_pending(path)
end

--- The topmost live-mark row (0-indexed) of an entry, or nil if it has no live
--- marks. Marks aren't stored in row order (adds precede deletes), so scan all.
---@param entry AgentDiff.Entry
---@return integer?
local function top_row(entry)
  if not (entry.bufnr and entry.extmark_ids and vim.api.nvim_buf_is_valid(entry.bufnr)) then
    return nil
  end
  local row ---@type integer?
  for _, id in ipairs(entry.extmark_ids) do
    local start_row = Render.mark_range(entry.bufnr, id)
    if start_row and (not row or start_row < row) then
      row = start_row
    end
  end
  return row
end

--- Show the history entry at index `i` alone (hiding every other diff), focus it,
--- and anchor the cursor there. Returns true on success, false if its file can't
--- be surfaced (closed / mid-edit).
---@param i integer
---@return boolean
local function show_at(i)
  local entry = history[i]
  hide_all()
  if not (entry.bufnr and entry.extmark_ids) then
    rerender_entry(entry, true)
  end
  local row = top_row(entry)
  if not row then
    return false
  end
  nav_cursor = i
  M._focus(entry.bufnr, row)
  return true
end

--- Whether any history entry currently has a live diff on screen.
---@return boolean
local function anything_shown()
  for _, entry in ipairs(history) do
    if entry.bufnr then
      return true
    end
  end
  return false
end

--- Jump to the next/prev edit in history, in time order — no wraparound. Only one
--- edit's diff is shown at a time. With nothing on screen (e.g. after Esc, or a
--- burst that never auto-displayed), a navigate first surfaces the current edit —
--- the one last anchored, or the newest — rather than stepping past it. Notifies
--- when there is no edit in the requested direction.
---@param dir 1|-1
function M.navigate(dir)
  -- Never yank focus/windows around while the user is typing. The keymaps are
  -- normal-mode only, but guard the entry point too (insert, terminal, etc.).
  if vim.fn.mode():match('^[iRt]') then
    return
  end
  if #history == 0 then
    vim.notify('agent-diff: no ' .. (dir > 0 and 'next' or 'previous') .. ' agent diff', vim.log.levels.INFO)
    return
  end

  -- Nothing shown: bring the current edit into view instead of stepping.
  if not anything_shown() then
    if show_at(nav_cursor or #history) then
      return
    end
  end

  local i = (nav_cursor or (dir > 0 and 0 or #history + 1)) + dir
  while i >= 1 and i <= #history do
    if show_at(i) then
      return
    end
    -- File couldn't be surfaced: skip past it in the same direction.
    i = i + dir
  end

  -- No edit in that direction. If the anchored edit is still shown, just move
  -- the cursor to it (a no-op re-focus) rather than reporting nothing — the user
  -- pressed a motion key and should land on the diff, not sit where they were.
  local cur = nav_cursor and history[nav_cursor]
  if cur then
    local row = top_row(cur)
    if row then
      M._focus(cur.bufnr, row)
      return
    end
  end
  vim.notify('agent-diff: no ' .. (dir > 0 and 'next' or 'previous') .. ' agent diff', vim.log.levels.INFO)
end

--- Move a window's cursor to a row and center the view, without changing which
--- window is focused.
---@param win integer
---@param bufnr integer
---@param row integer 0-indexed
local function position_cursor(win, bufnr, row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(row + 1, line_count), 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd('normal! zz')
  end)
end

--- Focus a buffer's window (switching to it) and move the cursor to a row. Used
--- by explicit navigation, which is meant to take the user to the edit.
---@param bufnr integer
---@param row integer 0-indexed
function M._focus(bufnr, row)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    vim.api.nvim_set_current_buf(bufnr)
    win = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(win)
  end
  position_cursor(win, bufnr, row)
end

--- Move the cursor onto an entry's diff in whatever window shows it, without
--- stealing focus. Used when the agent's write lands: the diff window follows the
--- edit, but the user's own window keeps focus.
---@param entry AgentDiff.Entry
function M._reveal(entry)
  local win = entry.bufnr and vim.fn.bufwinid(entry.bufnr) or -1
  if win == -1 then
    return
  end
  local row = top_row(entry)
  if row then
    position_cursor(win, entry.bufnr, row)
  end
end

--- Toggle auto-display: whether an applied edit to an off-screen file is pulled
--- onto screen. `on` forces a value; omitted flips the current one. Read live in
--- resolve(), so the change takes effect from the next edit — nothing on screen
--- moves. Returns the new state.
---@param on boolean?
---@return boolean
function M.toggle_autodisplay(on)
  if on == nil then
    on = not M.config.autodisplay
  end
  M.config.autodisplay = on
  return on
end

return M
