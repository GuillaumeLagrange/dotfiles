-- Left/right diff windows: fugitive blob/index
-- buffers or the real worktree file, native diff mode with scrollbind/
-- cursorbind, winbars, and the navigation keymaps shared by both windows.
local session_mod = require('diffy.session')

local M = {}

local function short(rev)
  if rev == 'WORKTREE' then
    return 'worktree'
  elseif rev == 'INDEX' then
    return 'index'
  elseif rev == 'HEAD' then
    return 'HEAD'
  end
  local sha, rest = rev:match('^(%x+)(.*)$')
  if sha and #sha > 7 then
    return sha:sub(1, 7) .. rest
  end
  return rev
end

local function fugitive_object(rev, path)
  if rev == 'INDEX' then
    return ':0:' .. path
  end
  return rev .. ':' .. path
end

local function set_nav_keymaps(session, buf)
  local map = session_mod.map
  map(session, 'n', ']r', function()
    require('diffy.panels.log').move_selection(session, 1)
  end, { buffer = buf, desc = 'next commit' })
  map(session, 'n', '[r', function()
    require('diffy.panels.log').move_selection(session, -1)
  end, { buffer = buf, desc = 'previous commit' })
  map(session, 'n', ']f', function()
    require('diffy.panels.tree').move_file(session, 1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    require('diffy.panels.tree').move_file(session, -1)
  end, { buffer = buf, desc = 'previous file' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
  session_mod.map_toggle(session, buf)
  require('diffy.review.ui').setup_diff_keymaps(session, buf)
end

--- Put `spec` (`{rev, path}` or `nil` for "no file on this side") into
--- window `name` ('left'|'right'): the real worktree file, a fugitive
--- index/blob buffer, or an empty placeholder.
local function open_side(session, name, spec)
  local win = session.wins[name]
  session.real_bufs = session.real_bufs or {}
  local prev_real = session.real_bufs[name]

  local buf, is_real
  if not spec or not spec.path then
    buf = session_mod.scratch_buf(session, name)
    is_real = false
  elseif spec.rev == 'WORKTREE' then
    local abspath = session.root .. '/' .. spec.path
    buf = vim.fn.bufadd(abspath)
    vim.fn.bufload(buf)
    is_real = true
  else
    local url = vim.fn.FugitiveFind(fugitive_object(spec.rev, spec.path), session.gitdir)
    buf = vim.fn.bufadd(url)
    vim.fn.bufload(buf)
    is_real = false
  end

  if prev_real and prev_real ~= buf and vim.api.nvim_buf_is_valid(prev_real) then
    session_mod.unmap_buffer(session, prev_real)
  end

  -- navigation.lua's BufWinEnter handler must ignore diffy's own buffer
  -- swaps; this counter lets it tell them apart from user navigation.
  session._nav_guard = (session._nav_guard or 0) + 1
  vim.api.nvim_win_set_buf(win, buf)
  session._nav_guard = session._nav_guard - 1

  if is_real then
    session.real_bufs[name] = buf
  else
    session_mod.register_buffer(session, name, buf)
    session.real_bufs[name] = nil
  end

  set_nav_keymaps(session, buf)

  vim.w[win].diffy_rev = spec and spec.rev or nil
  vim.w[win].diffy_path = spec and spec.path or nil
  vim.wo[win].winbar = (spec and spec.path) and (short(spec.rev) .. '  ' .. spec.path) or '(no file)'
end

--- Show `left_spec`/`right_spec` in the session's diff windows and put both
--- into native diff mode with scrollbind/cursorbind. Either spec may be
--- `nil` (added/deleted file: the other side is empty).
function M.show(session, left_spec, right_spec)
  -- Swap buffers with diff off: a window still in diff mode diffs the new
  -- buffer against the old pair mid-swap, and diff plugins' BufWinEnter
  -- handlers (diffchar.vim) error on the half-updated state.
  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    if win and vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      vim.api.nvim_win_call(win, function()
        vim.cmd('diffoff')
      end)
    end
  end
  open_side(session, 'left', left_spec)
  open_side(session, 'right', right_spec)

  for _, name in ipairs({ 'left', 'right' }) do
    local win = session.wins[name]
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
  end

  require('diffy.review.ui').decorate(session)
end

--- No files in the current selection: clear both sides to placeholders.
function M.clear(session)
  M.show(session, nil, nil)
end

--- Leave diff mode because the right window navigated outside the current
--- file list: the right window keeps whatever real buffer it now
--- shows (its diffy keymaps removed, since it's no longer diffy-managed);
--- the left window becomes an "outside diff" placeholder. Selecting a
--- listed file again (`M.show`) restores the pair.
function M.leave(session)
  local left, right = session.wins.left, session.wins.right
  for _, win in ipairs({ left, right }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].scrollbind = false
      vim.wo[win].cursorbind = false
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, 'diffoff')
      end)
    end
  end

  if right and vim.api.nvim_win_is_valid(right) then
    local prev_real = session.real_bufs and session.real_bufs.right
    if prev_real and vim.api.nvim_buf_is_valid(prev_real) then
      session_mod.unmap_buffer(session, prev_real)
    end
    if session.real_bufs then
      session.real_bufs.right = nil
    end
    vim.w[right].diffy_rev = nil
    vim.w[right].diffy_path = nil
    vim.wo[right].winbar = '(outside diff)'
  end

  if left and vim.api.nvim_win_is_valid(left) then
    local buf = session_mod.scratch_buf(session, 'left')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '(outside diff)' })
    session_mod.register_buffer(session, 'left', buf)
    vim.api.nvim_win_set_buf(left, buf)
    vim.w[left].diffy_rev = nil
    vim.w[left].diffy_path = nil
    vim.wo[left].winbar = '(outside diff)'
  end

  session.current_path = nil
  require('diffy.panels.tree').mark_current(session)
end

return M
