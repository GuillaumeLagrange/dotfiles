-- §8, §12.5 (phase 5): the 4-window conflict view - layout (screenshot),
-- `gho`/`ght` hunk-taking, `s` resolving (with a confirmation prompt when
-- markers remain), the same flow during a rebase conflict, and switching
-- back to a normal pair restoring the 2-window diff area.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      child.o.lines, child.o.columns = 24, 80
      snapshot = leak.snapshot(child)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
        repo = nil
      end
    end,
  },
})

--- A real, unresolved merge conflict on `f.txt` (content conflict: ours
--- has "MAIN", theirs has "FEATURE"). `g.txt` is an unrelated tracked file
--- for the "switch to a normal file" boundary test.
local function conflict_repo()
  local r = Repo.new()
  r:commit('Base', { ['f.txt'] = { 'l1', 'l2', 'l3' }, ['g.txt'] = { 'g1', 'g2' } })
  r:branch('feature'):commit('Feature', { ['f.txt'] = { 'l1', 'FEATURE', 'l3' } })
  r:checkout('main'):commit('Main', { ['f.txt'] = { 'l1', 'MAIN', 'l3' } })
  r:merge_conflict('feature')
  return r
end

local function wins()
  return child.lua_get('require("diffy.session").current().wins')
end

local function buf_lines(win)
  return child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(win))
end

local function winbar(win)
  return child.lua_get(('vim.wo[%d].winbar'):format(win))
end

local function is_diff(win)
  return child.lua_get(('vim.wo[%d].diff'):format(win))
end

T['§8: :Diffy conflicts opens the 4-window layout for the first conflicted file'] = function()
  -- a fixed path (not `vim.fn.tempname()`'s random one): nothing in this
  -- layout shows an absolute path except the result window's statusline,
  -- which must be stable to diff against a committed reference.
  repo = conflict_repo()
  local fixed_dir = '/tmp/diffy-screenshot-fixture-conflict'
  vim.fn.delete(fixed_dir, 'rf')
  vim.fn.rename(repo.dir, fixed_dir)
  repo.dir = fixed_dir
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)

  local w = wins()
  MiniTest.expect.equality(buf_lines(w.tree), { 'U f.txt' })
  MiniTest.expect.equality(winbar(w.ours), 'ours :2  f.txt')
  MiniTest.expect.equality(winbar(w.base), 'base :1  f.txt')
  MiniTest.expect.equality(winbar(w.theirs), 'theirs :3  f.txt')
  MiniTest.expect.equality(winbar(w.result), 'result  f.txt')
  MiniTest.expect.equality(buf_lines(w.ours), { 'l1', 'MAIN', 'l3' })
  MiniTest.expect.equality(buf_lines(w.base), { 'l1', 'l2', 'l3' })
  MiniTest.expect.equality(buf_lines(w.theirs), { 'l1', 'FEATURE', 'l3' })
  MiniTest.expect.equality(
    buf_lines(w.result),
    { 'l1', '<<<<<<< HEAD', 'MAIN', '=======', 'FEATURE', '>>>>>>> feature', 'l3' }
  )
  for _, key in ipairs({ 'ours', 'base', 'theirs', 'result' }) do
    MiniTest.expect.equality(is_diff(w[key]), true)
  end

  MiniTest.expect.reference_screenshot(child.get_screenshot())
  child.cmd('Diffy close')
end

T['§8: gho/ght take hunks and s marks the file resolved'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = wins()

  child.api.nvim_set_current_win(w.result)
  child.fn.win_execute(w.result, 'call cursor(2, 1)')
  child.type_keys('gho') -- take ours: drops the "<<<<<<< HEAD" marker line
  child.fn.win_execute(w.result, 'call cursor(1, 1)')
  child.type_keys(']x') -- next marker: "======="
  child.type_keys('ght') -- take theirs there
  child.type_keys(']x') -- next marker: the trailing ">>>>>>> feature"
  child.type_keys('ght') -- take theirs there too
  child.cmd('write')

  MiniTest.expect.equality(buf_lines(w.result), { 'l1', 'MAIN', 'FEATURE', 'l3' })

  ui.arm_ready(child, 'render')
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s')
  ui.wait_ready(child)

  local status = ui.git(repo.dir, { 'status', '--porcelain=v2' })
  MiniTest.expect.equality(status:find('^u ') == nil, true)
  MiniTest.expect.equality(status:find('f.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().conflict_active'), false)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().wins.left') ~= nil, true)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().wins.right') ~= nil, true)

  child.cmd('Diffy close')
end

-- `vim.fn.confirm`'s interactive prompt can't be driven through real
-- keystrokes in this headless harness (verified: it resolves to its
-- default choice immediately, without ever blocking for input) - answered
-- with a mock instead, the same technique mini.nvim's own test suite uses
-- for its own `confirm()`-driven code (e.g. `mini.bufremove`).
T['§8: s with conflict markers left asks for confirmation'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = wins()

  child.lua('_G.__confirm_choice = 2; vim.fn.confirm = function(...) return _G.__confirm_choice end')

  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s') -- declines (mocked choice 2, "No")
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') ~= nil, true)

  ui.arm_ready(child, 'render')
  child.lua('_G.__confirm_choice = 1')
  child.type_keys('s') -- accepts (mocked choice 1, "Yes")
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') == nil, true)

  child.cmd('Diffy close')
end

T['§8: the same flow works during a rebase conflict'] = function()
  local r = Repo.new()
  r:commit('Base', { ['f.txt'] = { 'l1', 'l2', 'l3' } })
  r:branch('feature'):commit('Feature', { ['f.txt'] = { 'l1', 'FEATURE', 'l3' } })
  r:checkout('main'):commit('Main', { ['f.txt'] = { 'l1', 'MAIN', 'l3' } })
  r:checkout('feature'):rebase_conflict('main')
  repo = r
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = wins()

  MiniTest.expect.equality(buf_lines(w.ours), { 'l1', 'MAIN', 'l3' })
  MiniTest.expect.equality(buf_lines(w.theirs), { 'l1', 'FEATURE', 'l3' })

  child.api.nvim_set_current_win(w.result)
  child.fn.win_execute(w.result, 'call cursor(2, 1)')
  child.type_keys('gho')
  child.fn.win_execute(w.result, 'call cursor(1, 1)')
  child.type_keys(']x')
  child.type_keys('ght')
  child.type_keys(']x')
  child.type_keys('ght')
  child.cmd('write')
  MiniTest.expect.equality(buf_lines(w.result), { 'l1', 'MAIN', 'FEATURE', 'l3' })

  ui.arm_ready(child, 'render')
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') == nil, true)

  child.cmd('Diffy close')
end

T['§8: selecting a normal file after a U row restores the 2-window diff area'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)
  vim.fn.writefile({ 'g1', 'edited' }, repo.dir .. '/g.txt')

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = wins()
  local tree_lines = buf_lines(w.tree)
  local u_line, g_line
  for i, l in ipairs(tree_lines) do
    if l:find('U f.txt', 1, true) then
      u_line = i
    end
    if l:find('M g.txt', 1, true) then
      g_line = i
    end
  end
  MiniTest.expect.equality(u_line ~= nil, true)
  MiniTest.expect.equality(g_line ~= nil, true)

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(u_line))
  ui.arm_ready(child, 'conflict')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().conflict_active'), true)

  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(g_line))
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().conflict_active'), false)
  local sw = child.lua_get('require("diffy.session").current().wins')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. sw.right .. '].diffy_path'), 'g.txt')
  MiniTest.expect.equality(is_diff(sw.left), true)
  MiniTest.expect.equality(is_diff(sw.right), true)

  child.cmd('Diffy close')
end

return T
