-- Observation helpers (contract §11.1): describe what the user sees, never
-- diffy's internal tables. Each takes the `MiniTest.child` driving the UI
-- (except `git`, which inspects the fixture repo directly on disk).
--
-- `wins` is the one exception: it looks the session's windows up so a test
-- can *address* them (focus, move the cursor). Never assert on its result.
local M = {}

--- Window ids of the session in `child`'s current tab, by role (`tree`,
--- `log`, `left`, `right`, and during a conflict `ours`, `theirs`, `base`,
--- `result`), or `{}` if none is open. For addressing only.
function M.wins(child)
  return child.lua_get([[(function()
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    return s and s.wins or {}
  end)()]])
end

--- `{ tree = lines, log = lines, left = side, right = side, diff = bool,
---   bars = { winbar, … } }` for the session in `child`'s current tab, or
--- `nil` if none is open. A side is `{ rev, path, bar, name, text }`: `bar` is
--- the winbar as drawn, `rev`/`path` are parsed from it (`'worktree'`,
--- `'index'`, `'HEAD'` or a 7-char sha, then the path; both nil for
--- placeholders like `(outside diff)`), `name` the buffer name and `text` its
--- lines. `bars` lists every window's winbar in the tab, in screen order.
function M.layout(child)
  local result = child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return vim.NIL end
    local function ok(win) return win and vim.api.nvim_win_is_valid(win) end

    local function buf_lines(win)
      if not ok(win) then return vim.NIL end
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    end

    local function side(win)
      if not ok(win) then return vim.NIL end
      local buf = vim.api.nvim_win_get_buf(win)
      local bar = vim.wo[win].winbar
      local rev, path = bar:match('^(%S+)  (.+)$')
      return {
        rev = rev, path = path, bar = bar,
        name = vim.api.nvim_buf_get_name(buf),
        text = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      }
    end

    local wins = vim.api.nvim_tabpage_list_wins(0)
    table.sort(wins, function(a, b)
      local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
      return pa[2] < pb[2] or (pa[2] == pb[2] and pa[1] < pb[1])
    end)
    local bars = {}
    for _, w in ipairs(wins) do table.insert(bars, vim.wo[w].winbar) end

    return {
      tree = buf_lines(s.wins.tree),
      log = buf_lines(s.wins.log),
      left = side(s.wins.left),
      right = side(s.wins.right),
      diff = ok(s.wins.left) and vim.wo[s.wins.left].diff or false,
      bars = bars,
    }
  ]])
  if result == vim.NIL then
    return nil
  end
  return result
end

--- Rows of the `panel` ('log' | 'tree') as drawn: `{ { text, hl = { group =
--- true, … } }, … }`, where `hl` holds the whole-line highlight groups
--- rendered on that row (`DiffySelection`, `DiffyMerge`, `DiffyCurrentFile`).
function M.panel(child, panel)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local win = s and s.wins[%q]
    if not (win and vim.api.nvim_win_is_valid(win)) then return {} end
    local buf = vim.api.nvim_win_get_buf(win)
    local rows = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      rows[i] = { text = l, hl = vim.empty_dict() }
    end
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      local g = m[4].line_hl_group
      if g and rows[m[2] + 1] then rows[m[2] + 1].hl[g] = true end
    end
    return rows
  ]]):format(panel))
end

--- Texts of the `panel` rows drawn with line highlight `group`.
function M.rows_with(child, panel, group)
  local out = {}
  for _, r in ipairs(M.panel(child, panel)) do
    if r.hl[group] then
      table.insert(out, r.text)
    end
  end
  return out
end

--- Names of every `diffy://` buffer still loaded in `child`.
function M.diffy_buffers(child)
  return child.lua_get([[(function()
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local n = vim.api.nvim_buf_get_name(b)
      if n:find('^diffy://') then table.insert(out, n) end
    end
    return out
  end)()]])
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
--- `{ { line = 15, summary = '💬 alice +1: first line' }, … }`; several
--- summaries under one line are joined with ' | '. `blanks` counts the
--- padding lines drawn under that line; `hl` maps each summary text to the
--- highlight group it's drawn with.
function M.threads_visible(child, side)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return {} end
    local win = s.wins[%q]
    if not win or not vim.api.nvim_win_is_valid(win) then return {} end
    local ns = s.ns.review
    if not ns then return {} end
    local buf = vim.api.nvim_win_get_buf(win)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local out = {}
    for _, m in ipairs(marks) do
      local details = m[4]
      if details.virt_lines then
        local parts, blanks, hl = {}, 0, {}
        for _, vl in ipairs(details.virt_lines) do
          local text = {}
          for _, chunk in ipairs(vl) do
            table.insert(text, chunk[1])
          end
          text = table.concat(text)
          if text ~= '' then
            table.insert(parts, text)
            hl[text] = vl[1][2]
          else
            blanks = blanks + 1
          end
        end
        if #parts > 0 then
          table.insert(out, { line = m[2] + 1, summary = table.concat(parts, ' | '), count = #parts, blanks = blanks, hl = hl })
        end
      end
    end
    table.sort(out, function(a, b) return a.line < b.line end)
    return out
  ]]):format(side))
end

--- The thread float in `child`'s current tab, or nil: `{ text = lines, over
--- = 'left'|'right' (the diff window it's drawn over), focused = bool }`.
function M.thread_float(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return vim.NIL end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local cfg = vim.api.nvim_win_get_config(w)
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      if cfg.relative ~= '' and name:find('/thread/', 1, true) then
        local over = cfg.win == s.wins.left and 'left' or cfg.win == s.wins.right and 'right' or vim.NIL
        return {
          text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false),
          over = over,
          focused = w == vim.api.nvim_get_current_win(),
        }
      end
    end
    return vim.NIL
  ]])
end

--- True if every pair of counterpart lines visible in both diff windows is
--- drawn on the same screen row. Counterparts come from nvim's own diff
--- alignment (contract §9.2: `row(l) = l + Σ diff_filler(k)`, equal rows are
--- counterparts); the screen rows come from `screenpos`, so virt_lines that
--- shift one side only are caught.
function M.aligned(child)
  return child.lua([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    if not s then return false end
    local lw, rw = s.wins.left, s.wins.right
    if not (lw and rw and vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then
      return false
    end
    vim.cmd('redraw')
    local function rows(win)
      return vim.api.nvim_win_call(win, function()
        local by_row, filler = {}, 0
        for k = 1, vim.fn.line('w$') do
          filler = filler + vim.fn.diff_filler(k)
          if k >= vim.fn.line('w0') then
            by_row[k + filler] = k
          end
        end
        return by_row
      end)
    end
    local left, right = rows(lw), rows(rw)
    local pairs_seen = 0
    for row, l in pairs(left) do
      local r = right[row]
      if r then
        pairs_seen = pairs_seen + 1
        if vim.fn.screenpos(lw, l, 1).row ~= vim.fn.screenpos(rw, r, 1).row then
          return false
        end
      end
    end
    return pairs_seen > 0
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

--- `M.wait_ready` through raw `child.api` calls, for right after a keystroke
--- that leaves the child transiently `blocking` (a float + `startinsert`, or
--- a handler spawning git synchronously; see AGENTS.md harness facts), where
--- `child.lua`'s guard would throw.
function M.wait_ready_raw(child, timeout)
  vim.wait(timeout or 5000, function()
    return child.api.nvim_exec_lua('return _G.__diffy_ready', {}) == true
  end, 10)
  child.api.nvim_exec_lua('pcall(vim.api.nvim_del_autocmd, _G.__diffy_ready_au)', {})
end

return M
