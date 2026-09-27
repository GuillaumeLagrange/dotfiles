-- The 4-window conflict view (contract §8): `:Diffy conflicts` (tree-only,
-- no log, first conflicted file selected) and selecting a `U` row in a
-- normal session's tree (`panels/tree.lua`'s `open_row`/`stage` hooks).
-- Stages 1/2/3 (base/ours/theirs) are read through fugitive; the result
-- pane is the real worktree file, still holding its conflict markers until
-- resolved. Works identically during merge, rebase, cherry-pick and
-- stash-pop - all of them populate the same index stages.
local session_mod = require('diffy.session')
local run = require('diffy.git.run')
local parse = require('diffy.git.parse')

local M = {}

local STAGE_LABEL = { [1] = 'base :1', [2] = 'ours :2', [3] = 'theirs :3' }
local MARKER_PAT = [[^\(<\{7}\|=\{7}\|>\{7}\)]]

--- One-time window restructuring: close the normal 2-window pair's right
--- window, reuse its left window as the "ours" pane (keeping its existing
--- `WinClosed` watcher - the key it's stored under doesn't matter to it),
--- then build `base`/`theirs` beside it and `result` below all three. The
--- big regions are split off first (top block / result), then the top
--- block is subdivided into three columns, so `result` ends up spanning
--- the full width instead of just one column.
local function enter_layout(session)
  local ours_win = session.wins.left
  local right_win = session.wins.right
  session_mod.unregister_window(session, 'right')
  if right_win and vim.api.nvim_win_is_valid(right_win) then
    pcall(vim.api.nvim_win_close, right_win, true)
  end
  session.wins.left = nil

  local result_buf = session_mod.scratch_buf(session, 'result')
  local result_win = vim.api.nvim_open_win(result_buf, false, { win = ours_win, split = 'below' })
  session_mod.register_buffer(session, 'result', result_buf)
  session_mod.register_window(session, 'result', result_win)

  local base_buf = session_mod.scratch_buf(session, 'base')
  local base_win = vim.api.nvim_open_win(base_buf, false, { win = ours_win, split = 'right' })
  session_mod.register_buffer(session, 'base', base_buf)
  session_mod.register_window(session, 'base', base_win)

  local theirs_buf = session_mod.scratch_buf(session, 'theirs')
  local theirs_win = vim.api.nvim_open_win(theirs_buf, false, { win = base_win, split = 'right' })
  session_mod.register_buffer(session, 'theirs', theirs_buf)
  session_mod.register_window(session, 'theirs', theirs_win)

  session.wins.ours = ours_win
  session.conflict_active = true
end

--- Reverse of `enter_layout`: close base/theirs/result, drop the real
--- result buffer's keymaps, and rebuild a plain right window beside the
--- surviving "ours" window (renamed back to "left") - the normal
--- 2-window diff area, ready for `diffpair.show`.
function M.leave(session)
  if not session.conflict_active then
    return
  end
  for _, key in ipairs({ 'base', 'theirs', 'result' }) do
    local win = session.wins[key]
    session_mod.unregister_window(session, key)
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if session.real_bufs and session.real_bufs.result and vim.api.nvim_buf_is_valid(session.real_bufs.result) then
    session_mod.unmap_buffer(session, session.real_bufs.result)
  end
  if session.real_bufs then
    session.real_bufs.result = nil
  end
  session.conflict_bufs = nil
  session.conflict_active = false
  session.conflict_path = nil

  local ours_win = session.wins.ours
  session.wins.ours = nil
  session.wins.left = ours_win
  if ours_win and vim.api.nvim_win_is_valid(ours_win) then
    vim.wo[ours_win].diff = false
    vim.wo[ours_win].scrollbind = false
  end

  local right_buf = session_mod.scratch_buf(session, 'right')
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { 'diffy: nothing loaded yet' })
  local right_win = vim.api.nvim_open_win(right_buf, false, { win = ours_win, split = 'right' })
  session_mod.register_buffer(session, 'right', right_buf)
  session_mod.register_window(session, 'right', right_win)
end

--- Put stage `stage`'s blob for `path` into pane `key` ('ours'|'base'
--- |'theirs'), or an empty placeholder when that stage doesn't exist
--- (e.g. an add/delete conflict).
local function set_stage_pane(session, key, stage, path, stages)
  local win = session.wins[key]
  local info = stages[stage]
  local buf
  if info then
    local url = vim.fn.FugitiveFind((':%d:'):format(stage) .. path, session.gitdir)
    buf = vim.fn.bufadd(url)
    vim.fn.bufload(buf)
  else
    buf = session_mod.scratch_buf(session, key)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ('(no %s version)'):format(STAGE_LABEL[stage]) })
  end
  vim.api.nvim_win_set_buf(win, buf)
  session_mod.register_buffer(session, 'conflict_' .. key, buf)
  session.conflict_bufs = session.conflict_bufs or {}
  session.conflict_bufs[key] = buf
  vim.wo[win].winbar = STAGE_LABEL[stage] .. '  ' .. (info and path or '(missing)')
end

local function set_result_keymaps(session, buf)
  local map = session_mod.map
  local function take(key)
    return function()
      local b = session.conflict_bufs and session.conflict_bufs[key]
      if b then
        pcall(vim.cmd, 'diffget ' .. b)
      end
    end
  end
  map(session, 'n', 'gho', take('ours'), { buffer = buf, desc = 'take ours hunk' })
  map(session, 'n', 'ghb', take('base'), { buffer = buf, desc = 'take base hunk' })
  map(session, 'n', 'ght', take('theirs'), { buffer = buf, desc = 'take theirs hunk' })
  map(session, 'n', ']x', function()
    vim.fn.search(MARKER_PAT)
  end, { buffer = buf, desc = 'next conflict marker' })
  map(session, 'n', '[x', function()
    vim.fn.search(MARKER_PAT, 'b')
  end, { buffer = buf, desc = 'previous conflict marker' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
end

--- The result pane: the real worktree file (still holding its conflict
--- markers until resolved), replacing whatever it showed for a previously
--- open conflicted file (§10: a real buffer's diffy keymaps don't outlive
--- it being shown in a diffy window).
local function set_result_pane(session, path)
  local win = session.wins.result
  local prev_real = session.real_bufs and session.real_bufs.result
  local abspath = session.root .. '/' .. path
  local buf = vim.fn.bufadd(abspath)
  vim.fn.bufload(buf)
  if prev_real and prev_real ~= buf and vim.api.nvim_buf_is_valid(prev_real) then
    session_mod.unmap_buffer(session, prev_real)
  end
  vim.api.nvim_win_set_buf(win, buf)
  session.real_bufs = session.real_bufs or {}
  session.real_bufs.result = buf
  session.conflict_bufs = session.conflict_bufs or {}
  session.conflict_bufs.result = buf
  vim.wo[win].winbar = 'result  ' .. path
  set_result_keymaps(session, buf)
end

--- Fill all four panes for `path` (already-open conflict layout) and put
--- every window into one shared diff group.
local function render_panes(session, path, stages)
  session.conflict_path = path
  set_stage_pane(session, 'ours', 2, path, stages)
  set_stage_pane(session, 'base', 1, path, stages)
  set_stage_pane(session, 'theirs', 3, path, stages)
  set_result_pane(session, path)
  for _, key in ipairs({ 'ours', 'base', 'theirs', 'result' }) do
    local win = session.wins[key]
    vim.wo[win].scrollbind = true
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
  end
end

--- Open (or switch to) the 4-window conflict view for `path` (§8). Builds
--- the layout on first entry; a later call while already active just
--- swaps the four panes' content.
function M.enter(session, path)
  run.git({ 'ls-files', '-u', '-z', '--', path }, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      local unmerged = parse.ls_files_unmerged(res.stdout or '')
      local stages = unmerged[path] or {}
      if not session.conflict_active then
        enter_layout(session)
      end
      render_panes(session, path, stages)
      run.ready({ session = session.id, event = 'conflict' })
    end,
  })
end

local function still_conflicted(abspath)
  if vim.fn.filereadable(abspath) == 0 then
    return false
  end
  for _, line in ipairs(vim.fn.readfile(abspath)) do
    if line:match('^<<<<<<< ') or line == '=======' or line:match('^>>>>>>> ') then
      return true
    end
  end
  return false
end

--- `s` on a conflicted row (dedicated conflicts tree, or a `U` row in a
--- normal session, via `panels/tree.lua`'s `M.stage`): `git add` the file,
--- warning and asking for real-key confirmation first if markers remain
--- (§8, §11.2 - `lua/diffy/prompt.lua`, not `vim.fn.confirm`). `cb(staged)`
--- is optional and always called exactly once: `true` once `git add`
--- succeeds, `false` on decline or failure.
function M.resolve(session, path, cb)
  local abspath = session.root .. '/' .. path
  local function do_add()
    run.git({ 'add', '--', path }, {
      cwd = session.root,
      session = session,
      on_exit = function(res)
        if res.code == 0 and session.refresh then
          session.refresh(session)
        end
        if cb then
          cb(res.code == 0)
        end
      end,
    })
  end
  if still_conflicted(abspath) then
    require('diffy.prompt').confirm(session, {
      ('%s still has conflict markers - stage anyway?'):format(path),
    }, function(accepted)
      if accepted then
        do_add()
      elseif cb then
        cb(false)
      end
    end)
  else
    do_add()
  end
end

-- `:Diffy conflicts`'s own tree (no log entries, only unmerged files).

local function render_tree(session)
  local buf = session.bufs.tree
  local lines = {}
  for _, p in ipairs(session.conflict_paths or {}) do
    table.insert(lines, 'U ' .. p)
  end
  if #lines == 0 then
    lines = { '(no conflicts)' }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function path_at_cursor(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  return (session.conflict_paths or {})[lnum]
end

--- `]f`/`[f` in the dedicated conflicts tree: move to and open the
--- next/previous conflicted file.
function M.move(session, delta)
  local paths = session.conflict_paths or {}
  if #paths == 0 then
    return
  end
  local cur
  for i, p in ipairs(paths) do
    if p == session.conflict_path then
      cur = i
      break
    end
  end
  local nxt = cur and (cur + delta) or (delta > 0 and 1 or #paths)
  if nxt < 1 or nxt > #paths then
    return
  end
  if vim.api.nvim_win_is_valid(session.wins.tree) then
    pcall(vim.api.nvim_win_set_cursor, session.wins.tree, { nxt, 0 })
  end
  M.enter(session, paths[nxt])
end

local function setup_conflicts_tree(session)
  local map = session_mod.map
  local buf = session.bufs.tree
  local function open_at_cursor()
    local p = path_at_cursor(session)
    if p then
      M.enter(session, p)
    end
  end
  map(session, 'n', '<CR>', open_at_cursor, { buffer = buf, desc = 'open conflict' })
  map(session, 'n', 'o', open_at_cursor, { buffer = buf, desc = 'open conflict' })
  map(session, 'n', 's', function()
    local p = path_at_cursor(session)
    if p then
      M.resolve(session, p)
    end
  end, { buffer = buf, desc = 'mark resolved' })
  map(session, 'n', ']f', function()
    M.move(session, 1)
  end, { buffer = buf, desc = 'next conflict' })
  map(session, 'n', '[f', function()
    M.move(session, -1)
  end, { buffer = buf, desc = 'previous conflict' })
  map(session, 'n', 'gf', function()
    local p = path_at_cursor(session)
    if not p then
      return
    end
    local abspath = session.root .. '/' .. p
    if session.prev_tab and vim.api.nvim_tabpage_is_valid(session.prev_tab) then
      vim.api.nvim_set_current_tabpage(session.prev_tab)
    else
      vim.cmd('tabnew')
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
  end, { buffer = buf, desc = 'open real file' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
end

--- Rebuild the conflicted-file list and open the current (or first) one.
--- `session.refresh` for a `:Diffy conflicts` session.
function M.refresh_list(session)
  run.git({ 'ls-files', '-u', '-z' }, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      local unmerged = parse.ls_files_unmerged(res.stdout or '')
      local paths = {}
      for p in pairs(unmerged) do
        table.insert(paths, p)
      end
      table.sort(paths)
      session.conflict_paths = paths

      render_tree(session)
      if not session.setup_done then
        setup_conflicts_tree(session)
        session.setup_done = true
      end

      local target = session.conflict_path
      local found = false
      for _, p in ipairs(paths) do
        if p == target then
          found = true
        end
      end
      if not found then
        target = paths[1]
      end

      if target then
        M.enter(session, target)
      else
        M.leave(session)
        run.ready({ session = session.id, event = 'render' })
      end
    end,
  })
end

--- `:Diffy conflicts` (§4, §8): open a session whose tree lists every
--- unmerged file (no log entries) and whose diff area is the 4-window
--- conflict view for the first one.
function M.start()
  local repo = require('diffy.git.repo')
  local s = session_mod.open({ range = { kind = 'conflicts' } })
  s.refresh = function(sess)
    M.refresh_list(sess)
  end

  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
      session_mod.teardown(s)
      return
    end
    s.root = root
    s.gitdir = vim.fn.FugitiveExtractGitDir(root)
    vim.bo[s.bufs.log].modifiable = true
    vim.api.nvim_buf_set_lines(s.bufs.log, 0, -1, false, { '(:Diffy conflicts - no log)' })
    vim.bo[s.bufs.log].modifiable = false
    M.refresh_list(s)
  end, s)
end

return M
