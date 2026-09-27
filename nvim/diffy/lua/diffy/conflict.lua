-- The 4-window conflict view: `:Diffy conflicts` (tree-only,
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
-- Vim regex for ]x/[x: git's exact markers, incl. diff3's `||||||| base`.
local MARKER_PAT = [[^\(<\{7} \||\{7} \|=\{7}$\|>\{7} \)]]
local OPEN_PAT = '^<<<<<<< '
local CLOSE_PAT = '^>>>>>>> '

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
end

local function open_pane(session, key, win, split)
  local buf = session_mod.scratch_buf(session, key)
  local new_win = vim.api.nvim_open_win(buf, false, { win = win, split = split })
  session_mod.register_buffer(session, key, buf)
  session_mod.register_window(session, key, new_win)
  return new_win
end

--- One-time window restructuring: close the normal pair's right window,
--- reuse its left window as the "ours" pane (its `WinClosed` watcher does
--- not depend on the name it's registered under), then build `base`/`theirs`
--- beside it and `result` below all three. The top block and result are
--- split first, then the top block is divided into three columns, so
--- `result` spans the full width.
local function enter_layout(session)
  local ours_win = session.wins.left
  local right_win = session.wins.right
  session_mod.unregister_window(session, 'right')
  if right_win and vim.api.nvim_win_is_valid(right_win) then
    pcall(vim.api.nvim_win_close, right_win, true)
  end
  session.wins.left = nil

  open_pane(session, 'result', ours_win, 'below')
  local base_win = open_pane(session, 'base', ours_win, 'right')
  open_pane(session, 'theirs', base_win, 'right')

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
  if session.real_bufs then
    local real = session.real_bufs.result
    if real and vim.api.nvim_buf_is_valid(real) then
      session_mod.unmap_buffer(session, real)
    end
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

-- Lines of the `<<<<<<< … >>>>>>>` block around the cursor, or nil outside one.
local function marker_block()
  local lnum = vim.fn.line('.')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local start
  for i = lnum, 1, -1 do
    if lines[i]:match(CLOSE_PAT) and i ~= lnum then
      return nil
    end
    if lines[i]:match(OPEN_PAT) then
      start = i
      break
    end
  end
  if not start then
    return nil
  end
  for i = math.max(lnum, start + 1), #lines do
    if lines[i]:match(OPEN_PAT) then
      return nil
    end
    if lines[i]:match(CLOSE_PAT) then
      return start, i
    end
  end
  return nil
end

local function map_rebuild(session, buf)
  session_mod.map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
end

local function set_result_keymaps(session, buf)
  local map = session_mod.map
  -- linematch splits a conflict into per-line hunks, so a bare :diffget would
  -- only take the line under the cursor; take the whole marker block instead.
  local function take(key)
    return function()
      local b = session.conflict_bufs and session.conflict_bufs[key]
      if not b then
        return
      end
      local s, e = marker_block()
      local range = s and ('%d,%d'):format(s, e) or ''
      local ok, err = pcall(vim.cmd, range .. 'diffget ' .. b)
      if not ok then
        vim.notify('diffy: ' .. tostring(err), vim.log.levels.WARN)
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
  map_rebuild(session, buf)
  session_mod.map_toggle(session, buf)
end

--- The result pane: the real worktree file (still holding its conflict
--- markers until resolved). The previously shown real buffer loses its
--- diffy keymaps.
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

--- Open (or switch to) the 4-window conflict view for `path`. Builds
--- the layout on first entry; a later call while already active just
--- swaps the four panes' content.
function M.enter(session, path, opts)
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
      if opts and opts.focus and vim.api.nvim_win_is_valid(session.wins.result) then
        vim.api.nvim_set_current_win(session.wins.result)
      end
      run.ready({ session = session.id, event = 'conflict' })
    end,
  })
end

local function still_conflicted(abspath)
  if vim.fn.filereadable(abspath) == 0 then
    return false
  end
  for _, line in ipairs(vim.fn.readfile(abspath)) do
    if line:match(OPEN_PAT) or line == '=======' or line:match(CLOSE_PAT) then
      return true
    end
  end
  return false
end

--- `s` on a conflicted row (dedicated conflicts tree, or a `U` row in a
--- normal session, via `panels/tree.lua`'s `M.stage`): `git add` the file,
--- asking for confirmation first if markers remain. `cb(staged)` is optional
--- and always called exactly once: `true` once `git add` succeeds, `false` on
--- decline or failure.
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
local function move(session, delta)
  local paths = session.conflict_paths or {}
  if #paths == 0 then
    return
  end
  local cur = index_of(paths, session.conflict_path)
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
  local function open_at_cursor(focus)
    local p = path_at_cursor(session)
    if p then
      M.enter(session, p, { focus = focus })
    end
  end
  map(session, 'n', '<CR>', function()
    open_at_cursor(true)
  end, { buffer = buf, desc = 'open conflict and focus the result' })
  map(session, 'n', 'o', function()
    open_at_cursor(false)
  end, { buffer = buf, desc = 'open conflict' })
  map(session, 'n', 's', function()
    local p = path_at_cursor(session)
    if p then
      M.resolve(session, p)
    end
  end, { buffer = buf, desc = 'mark resolved' })
  map(session, 'n', ']f', function()
    move(session, 1)
  end, { buffer = buf, desc = 'next conflict' })
  map(session, 'n', '[f', function()
    move(session, -1)
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
  map_rebuild(session, buf)
  session_mod.map_toggle(session, buf)
end

--- Rebuild the conflicted-file list and open the current (or first) one.
--- `session.refresh` for a `:Diffy conflicts` session.
local function refresh_list(session)
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
      if not index_of(paths, target) then
        target = paths[1]
      end

      if target then
        M.enter(session, target)
      else
        M.leave(session)
        require('diffy.diffpair').clear(session)
        run.ready({ session = session.id, event = 'render' })
      end
    end,
  })
end

--- `:Diffy conflicts`: open a session whose tree lists every
--- unmerged file (no log entries) and whose diff area is the 4-window
--- conflict view for the first one.
function M.start()
  local repo = require('diffy.git.repo')
  local s = session_mod.open({ range = { kind = 'conflicts' } })
  s.refresh = function(sess)
    refresh_list(sess)
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
    refresh_list(s)
  end, s)
end

return M
