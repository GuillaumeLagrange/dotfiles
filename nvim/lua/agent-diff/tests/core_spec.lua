local Core = require('agent-diff.core')
local Render = require('agent-diff.render')

--- Count agent-diff extmarks currently placed in a buffer.
local function mark_count(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, Render.ns, 0, -1, {})
end

--- Write lines to a fresh temp file, open it in the current window, and return
--- {path, bufnr, lines}. The buffer is unmodified and shows disk content, which
--- is what resolve() requires to render.
local function open_file(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return { path = path, bufnr = vim.api.nvim_get_current_buf(), lines = lines }
end

describe('core history + clear + navigate', function()
  before_each(function()
    -- Hard-reset the module between cases: clear() only hides (history persists
    -- in-session by design), so use the test-only _reset to start from empty.
    Core._reset()
    -- Cases operate on tempname() files outside any repo; the repo_only gate
    -- (on by default) would drop every edit. Track them unconditionally here.
    Core.config.repo_only = false
    vim.cmd('silent! %bwipeout!')
  end)

  it('renders an applied edit into its open buffer', function()
    local f = open_file({ 'a', 'b', 'c' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'b', 'c' }, new_file = { 'a', 'B', 'c' } })
    assert.is_true(mark_count(f.bufnr) > 0)
    assert.is_true(Core.is_showing())
  end)

  it('clear() hides marks but keeps the edit navigable', function()
    local f = open_file({ 'a', 'B', 'c' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'b', 'c' }, new_file = { 'a', 'B', 'c' } })
    assert.is_true(mark_count(f.bufnr) > 0)

    Core.clear()
    assert.equals(0, mark_count(f.bufnr))
    assert.is_false(Core.is_showing())

    -- The anchored edit was hidden; the next navigate brings it back.
    Core.navigate(1)
    assert.is_true(mark_count(f.bufnr) > 0)
    assert.is_true(Core.is_showing())
  end)

  it('navigate re-renders after the buffer was closed and reopened', function()
    local f = open_file({ 'a', 'B', 'c' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'b', 'c' }, new_file = { 'a', 'B', 'c' } })
    Core.clear()

    -- Reopen from disk in a new buffer, then navigate: it should find the file
    -- and place fresh marks.
    vim.cmd('silent! %bwipeout!')
    vim.cmd.edit(vim.fn.fnameescape(f.path))
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(0, mark_count(buf))

    Core.navigate(1)
    assert.is_true(mark_count(buf) > 0)
  end)

  it('is_showing() is false with no edits and true once one renders', function()
    assert.is_false(Core.is_showing())
    local f = open_file({ 'x' })
    Core.apply({ path = f.path, kind = 'applied', old_file = {}, new_file = { 'x' } })
    assert.is_true(Core.is_showing())
  end)

  it('navigate places the cursor on the changed line', function()
    -- Change on line 3 (1-indexed). Cursor should land there.
    local f = open_file({ 'a', 'b', 'C', 'd', 'e' })
    Core.apply({
      path = f.path,
      kind = 'applied',
      old_file = { 'a', 'b', 'c', 'd', 'e' },
      new_file = { 'a', 'b', 'C', 'd', 'e' },
    })
    Core.clear()
    Core.navigate(1)
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('navigate lands on the topmost region even when it is a deletion', function()
    -- Delete line 2, add a line near the end. The deletion is the topmost
    -- region; the cursor should sit at/above it, not jump to the later add.
    local f = open_file({ 'a', 'c', 'd', 'NEW', 'e' })
    Core.apply({
      path = f.path,
      kind = 'applied',
      old_file = { 'a', 'b', 'c', 'd', 'e' },
      new_file = { 'a', 'c', 'd', 'NEW', 'e' },
    })
    Core.clear()
    Core.navigate(1)
    -- The added 'NEW' is on line 4; landing there would mean we skipped the
    -- earlier deletion. Assert we're above it.
    assert.is_true(vim.api.nvim_win_get_cursor(0)[1] < 4)
  end)

  it('navigate is time-ordered and does not wrap around', function()
    -- Two edits; step back to the oldest, then `[a` again has nowhere older to go
    -- and (nothing left to fall back to being shown) reports "no previous".
    local f = open_file({ 'A', 'B' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'B' }, new_file = { 'A', 'B' } })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'A', 'b' }, new_file = { 'A', 'B' } })
    Core.navigate(-1) -- newest → oldest

    local notes = {}
    local orig = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    -- On the oldest and it's shown: `[a` re-focuses it, no notification.
    Core.navigate(-1)
    assert.equals(0, #notes)
    vim.notify = orig
  end)

  it('at the end, navigate re-focuses the shown edit instead of doing nothing', function()
    local f = open_file({ 'A', 'b', 'c', 'd', 'e' })
    Core.apply({
      path = f.path,
      kind = 'applied',
      old_file = { 'a', 'b', 'c', 'd', 'e' },
      new_file = { 'A', 'b', 'c', 'd', 'e' },
    })
    -- Newest edit shown, on line 1. Move the cursor away, then `]a` (no next)
    -- should bring it back to the diff rather than leaving it where it was.
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local notes = {}
    local orig = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    Core.navigate(1)
    vim.notify = orig
    assert.equals(0, #notes)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('shows only one edit at a time across buffers', function()
    local f1 = open_file({ 'A', 'b' })
    Core.apply({ path = f1.path, kind = 'applied', old_file = { 'a', 'b' }, new_file = { 'A', 'b' } })
    assert.is_true(mark_count(f1.bufnr) > 0)

    -- A second edit in a different buffer clears the first buffer's diff.
    local f2 = open_file({ 'X', 'y' })
    Core.apply({ path = f2.path, kind = 'applied', old_file = { 'x', 'y' }, new_file = { 'X', 'y' } })
    assert.is_true(mark_count(f2.bufnr) > 0)
    assert.equals(0, mark_count(f1.bufnr))

    -- Navigating back to the first re-shows it and clears the second.
    Core.navigate(-1)
    assert.is_true(mark_count(f1.bufnr) > 0)
    assert.equals(0, mark_count(f2.bufnr))
  end)

  it('preview then apply leaves a single applied render (no lingering pending)', function()
    local f = open_file({ 'a', 'b' })
    Core.preview({ path = f.path, kind = 'pending', old_file = { 'a', 'b' }, new_file = { 'a', 'B' } })
    assert.is_true(mark_count(f.bufnr) > 0)
    local pending_marks = mark_count(f.bufnr)

    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'b' }, new_file = { 'a', 'B' } })
    -- The pending marks were cleared and replaced by applied ones, not stacked.
    assert.is_true(mark_count(f.bufnr) > 0)
    assert.equals(pending_marks, mark_count(f.bufnr))
  end)

  it('resolves by exact path, not a superstring-named open buffer', function()
    -- An edit targets f.path, which is NOT open, while a buffer whose name is a
    -- superstring of it (f.path .. '.snap') IS open. vim.fn.bufnr() would
    -- substring-match the .snap buffer; the exact-name lookup must not.
    local base = vim.fn.tempname()
    local snap = base .. '.snap'
    vim.fn.writefile({ 'x', 'y', 'z' }, base)
    vim.fn.writefile({ 'unrelated' }, snap)
    vim.cmd.edit(vim.fn.fnameescape(snap)) -- only the .snap buffer is open
    local snap_buf = vim.api.nvim_get_current_buf()

    -- base is not open and there is only this one editor window, so a correct
    -- resolve auto-displays base; a wrong one paints onto snap_buf.
    Core.apply({ path = base, kind = 'applied', old_file = { 'X', 'y', 'z' }, new_file = { 'x', 'y', 'z' } })

    assert.equals(0, mark_count(snap_buf)) -- the .snap buffer is untouched
    local base_buf = vim.fn.bufnr(base)
    assert.is_true(base_buf ~= -1 and mark_count(base_buf) > 0)
  end)

  --- Whether a _defer_until_open autocmd is currently armed for `path`.
  local function defer_armed(path)
    for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
      if au.group_name == 'agent_diff_defer_' .. path then
        return true
      end
    end
    return false
  end

  it('clear_path cancels a deferred pending so a rejected off-screen edit cannot resurface', function()
    -- Mimic the adapter's failed-edit path: an off-screen file previews and defers
    -- on _defer_until_open, the edit is then rejected, and the adapter calls
    -- clear_path. The armed defer must be cancelled, or opening the file later
    -- repaints the never-applied change. Drive _defer_until_open directly so the
    -- test does not depend on the window layout that decides whether resolve()
    -- defers.
    local path = vim.fn.tempname()
    local fired = false
    Core._defer_until_open(path, function()
      fired = true
    end)
    assert.is_true(defer_armed(path))

    Core.clear_path(path) -- edit rejected
    assert.is_false(defer_armed(path)) -- the defer is gone

    -- Opening the file does not fire the (cancelled) callback.
    vim.fn.writefile({ 'a', 'b' }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.wait(50)
    assert.is_false(fired)
  end)

  it('created file: a deferred preview does not leak an untracked mark past clear', function()
    -- A brand-new file previews before it exists on disk, so the preview defers
    -- on _defer_until_open. The write then lands and apply opens the file, which
    -- fires that deferred callback. Its re-rendered pending mark must not survive
    -- clear(): apply has to cancel the stale defer, or the mark is tracked by
    -- nothing and lingers.
    local path = vim.fn.tempname()
    assert.equals(0, vim.fn.filereadable(path))

    Core.preview({ path = path, kind = 'pending', old_file = {}, new_file = { 'aaa', 'bbb', 'ccc' } })

    vim.fn.writefile({ 'aaa', 'bbb', 'ccc' }, path)
    Core.apply({ path = path, kind = 'applied', old_file = {}, new_file = { 'aaa', 'bbb', 'ccc' } })
    vim.wait(50)

    Core.clear()
    local buf = vim.fn.bufnr(path)
    assert.equals(0, mark_count(buf))
    assert.is_false(Core.is_showing())
  end)

  it('repo_only drops edits to files outside the editor git worktree', function()
    -- tempname() is outside this repo. With the gate on, the edit is ignored
    -- entirely: nothing renders and nothing enters the navigable history.
    Core.config.repo_only = true
    local f = open_file({ 'a', 'B', 'c' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'b', 'c' }, new_file = { 'a', 'B', 'c' } })
    assert.equals(0, mark_count(f.bufnr))
    assert.is_false(Core.is_showing())

    -- ...and there is nothing to navigate to (a notification, no render).
    local notes = {}
    local orig = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    Core.navigate(1)
    vim.notify = orig
    assert.equals(1, #notes)
    assert.equals(0, mark_count(f.bufnr))
  end)

  it('navigate with nothing shown surfaces the newest edit', function()
    -- Two edits in the same buffer; the second is the newest. clear() hides both.
    local f = open_file({ 'A', 'B' })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'a', 'B' }, new_file = { 'A', 'B' } })
    Core.apply({ path = f.path, kind = 'applied', old_file = { 'A', 'b' }, new_file = { 'A', 'B' } })
    Core.clear()
    assert.is_false(Core.is_showing())

    -- `]a` (next) with nothing shown surfaces the current/newest, not "no next".
    Core.navigate(1)
    assert.is_true(Core.is_showing())
    assert.is_true(mark_count(f.bufnr) > 0)
  end)

  it('auto-displays into the lone editor window without stealing focus', function()
    -- One editor window holding some file, plus the sidekick panel (mimicked by a
    -- nofile scratch window). An edit to a not-open file loads into that lone
    -- editor window and renders, but focus stays on the panel.
    open_file({ 'a1' })
    vim.cmd('split')
    vim.cmd('enew')
    vim.bo.buftype = 'nofile' -- stand-in for the sidekick panel
    local panel_win = vim.api.nvim_get_current_win()

    local other = vim.fn.tempname()
    vim.fn.writefile({ 'O1', 'o2' }, other)
    Core.apply({ path = other, kind = 'applied', old_file = { 'o1', 'o2' }, new_file = { 'O1', 'o2' } })

    assert.is_true(Core.is_showing())
    assert.equals(panel_win, vim.api.nvim_get_current_win())
  end)

  it('passive auto-display bails when the layout is ambiguous (two editor windows)', function()
    -- Two file splits (A and B) are an ambiguous layout: surfacing an off-screen
    -- edit would swap a buffer the user is viewing out from under them. Passive
    -- auto-display must decline and leave the layout untouched.
    open_file({ 'a1' })
    vim.cmd('split')
    open_file({ 'b1' })
    local win_b = vim.api.nvim_get_current_win()
    local layout_before = vim.fn.winlayout()

    local other = vim.fn.tempname()
    vim.fn.writefile({ 'O1', 'o2' }, other)
    Core.apply({ path = other, kind = 'applied', old_file = { 'o1', 'o2' }, new_file = { 'O1', 'o2' } })

    -- Nothing rendered, focus unchanged, layout untouched.
    assert.is_false(Core.is_showing())
    assert.equals(win_b, vim.api.nvim_get_current_win())
    assert.same(layout_before, vim.fn.winlayout())

    -- But explicit navigation still surfaces it into the current window.
    Core.navigate(1)
    assert.is_true(Core.is_showing())
  end)

  it('defers when there is no editor window, then navigates to it', function()
    -- Only a non-editor window exists (mimic the sidekick panel via a scratch
    -- buffer with buftype=nofile), so autodisplay has nowhere to render.
    vim.cmd('enew')
    vim.bo.buftype = 'nofile'

    local hidden = vim.fn.tempname()
    vim.fn.writefile({ 'H1', 'h2' }, hidden)
    Core.apply({ path = hidden, kind = 'applied', old_file = { 'h1', 'h2' }, new_file = { 'H1', 'h2' } })
    assert.is_false(Core.is_showing()) -- deferred: no editor window to use

    -- Navigating forces it into the current window and renders it.
    Core.navigate(1)
    local buf = vim.api.nvim_get_current_buf()
    assert.equals(hidden, vim.api.nvim_buf_get_name(buf))
    assert.is_true(mark_count(buf) > 0)
  end)
end)
