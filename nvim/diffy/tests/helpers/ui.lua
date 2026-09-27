-- Observation helpers (contract §11.1): describe what the user sees, never
-- diffy's internal tables. Each takes the `MiniTest.child` driving the UI
-- (except `git`, which inspects the fixture repo directly on disk).
local M = {}

--- `{ tree = lines, log = lines, left = { rev, path, text }, right = {…},
---   diff = bool }` for the session in `child`'s current tab, or `nil` if
--- none is open. `rev`/`path` come from `vim.w.diffy_rev`/`diffy_path`,
--- window-local vars later phases (diffpair.lua) set on the diff windows.
function M.layout(child)
  local result = child.lua([[
    local session = require('diffy.session')
    local s = session.for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return vim.NIL end

    local function buf_lines(win)
      if not win or not vim.api.nvim_win_is_valid(win) then return vim.NIL end
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end

    local function side(win)
      if not win or not vim.api.nvim_win_is_valid(win) then return vim.NIL end
      local buf = vim.api.nvim_win_get_buf(win)
      return {
        rev = vim.w[win].diffy_rev,
        path = vim.w[win].diffy_path,
        text = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      }
    end

    local diff = false
    if s.wins.left and vim.api.nvim_win_is_valid(s.wins.left) then
      diff = vim.wo[s.wins.left].diff
    end

    return {
      tree = buf_lines(s.wins.tree),
      log = buf_lines(s.wins.log),
      left = side(s.wins.left),
      right = side(s.wins.right),
      diff = diff,
    }
  ]])
  if result == vim.NIL then
    return nil
  end
  return result
end

--- Runs `git <args>` in fixture repo `dir`, for asserting HEAD/index/branch/
--- files on disk. Returns trimmed stdout; raises on nonzero exit.
function M.git(dir, args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, text = true }):wait()
  if res.code ~= 0 then
    error(('ui.git: `git %s` failed (%d)\n%s'):format(table.concat(args, ' '), res.code, res.stderr or ''), 2)
  end
  return vim.trim(res.stdout or '')
end

--- Threads currently rendered in `side`'s window ('left'|'right') of the
--- session in `child`'s current tab, read from the extmarks actually drawn:
--- `{ { line = 15, summary = '💬 alice +1' }, … }`.
--- Implemented by phase 6 (review layer), once threads/signs exist.
function M.threads_visible(_child, _side)
  error('ui.threads_visible: implemented by phase 6 (review layer)')
end

--- True if the left/right diff windows currently show matching rows for
--- counterpart lines (contract §9.2: `row(l) = l + Σ diff_filler(k)`):
--- each window's own cursor line (kept in step by cursorbind) is compared
--- via that formula, so this catches any diff-fill/scroll misalignment.
function M.aligned(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return false end
    local lw, rw = s.wins.left, s.wins.right
    if not (lw and rw and vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then
      return false
    end
    local function row(win)
      return vim.api.nvim_win_call(win, function()
        local lnum = vim.fn.line('.')
        local filler = 0
        for k = 1, lnum do
          filler = filler + vim.fn.diff_filler(k)
        end
        return lnum + filler
      end)
    end
    return row(lw) == row(rw)
  ]])
end

--- Arm a one-shot listener for `User DiffyReady` in `child`, optionally
--- filtered to `data.event == event` (e.g. `'render'`, `'select'`,
--- `'open_row'`, see the modules that call `git/run.lua`'s `M.ready`). Call
--- this right before the action expected to trigger a render; pair with
--- `M.wait_ready` right after. This is the only synchronization point
--- tests use - never a sleep (contract §11.3).
function M.arm_ready(child, event)
  local filter = event and ('%q'):format(event) or 'nil'
  child.lua(([[
    _G.__diffy_ready = false
    _G.__diffy_ready_au = vim.api.nvim_create_autocmd('User', {
      pattern = 'DiffyReady',
      callback = function(a)
        if %s == nil or (a.data and a.data.event == %s) then
          _G.__diffy_ready = true
        end
      end,
    })
  ]]):format(filter, filter))
end

--- Block (up to `timeout` ms, default 5000) until the listener armed by
--- `M.arm_ready` fires, then remove it.
function M.wait_ready(child, timeout)
  child.lua(('vim.wait(%d, function() return _G.__diffy_ready end)'):format(timeout or 5000))
  child.lua('pcall(vim.api.nvim_del_autocmd, _G.__diffy_ready_au)')
end

return M
