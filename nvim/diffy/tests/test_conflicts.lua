-- The 4-window conflict view - layout (screenshot),
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

local function buf_lines(win)
  return child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(win))
end

local function is_diff(win)
  return child.lua_get(('vim.wo[%d].diff'):format(win))
end

local function arm_ready_raw(event)
  ui.arm_ready_raw(child, event)
end

T[':Diffy conflicts opens the 4-window layout for the first conflicted file'] = function()
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

  local w = ui.wins(child)
  MiniTest.expect.equality(buf_lines(w.tree), { 'U f.txt' })
  local bars = ui.layout(child).bars
  for _, bar in ipairs({ 'ours :2  f.txt', 'base :1  f.txt', 'theirs :3  f.txt', 'result  f.txt' }) do
    MiniTest.expect.equality(vim.tbl_contains(bars, bar), true)
  end
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

T['gho/ght take hunks and s on the last conflict resolves it and leaves no conflict pane'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.result)
  child.fn.win_execute(w.result, 'call cursor(1, 1)')
  child.type_keys(']x') -- lands on "<<<<<<<"
  child.type_keys('ght') -- the whole conflict becomes theirs
  child.cmd('write')

  MiniTest.expect.equality(buf_lines(w.result), { 'l1', 'FEATURE', 'l3' })

  ui.arm_ready(child, 'render')
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s')
  ui.wait_ready(child)

  local status = ui.git(repo.dir, { 'status', '--porcelain=v2' })
  MiniTest.expect.equality(status:find('^u ') == nil, true)
  MiniTest.expect.equality(status:find('f.txt', 1, true) ~= nil, true)
  -- no conflict pane (not even a stale ours) remains once nothing is conflicted
  for _, bar in ipairs(ui.layout(child).bars) do
    MiniTest.expect.equality(bar:find('^ours ') or bar:find('^theirs ') or bar:find('^base ') or bar:find('^result '), nil)
  end

  child.cmd('Diffy close')
end

T[']x skips a markdown heading underline and stops on each real marker'] = function()
  repo = Repo.new()
  repo:commit('Base', { ['f.md'] = { 'Title', '==========', 'l2' } })
  repo:branch('feature'):commit('Feature', { ['f.md'] = { 'Title', '==========', 'FEATURE' } })
  repo:checkout('main'):commit('Main', { ['f.md'] = { 'Title', '==========', 'MAIN' } })
  repo:merge_conflict('feature')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.result)
  child.fn.win_execute(w.result, 'call cursor(1, 1)')
  local seen = {}
  for _ = 1, 3 do
    child.type_keys(']x')
    table.insert(seen, child.api.nvim_get_current_line())
  end
  MiniTest.expect.equality(seen, { '<<<<<<< HEAD', '=======', '>>>>>>> feature' })

  child.cmd('Diffy close')
end

-- `s` with markers left opens `lua/diffy/prompt.lua`'s real floating
-- confirmation - driven here with
-- actual `y`/`n` keystrokes, not a `vim.fn.confirm` mock.
T['s with conflict markers left asks for confirmation'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'conflict')
  child.cmd('Diffy conflicts')
  ui.wait_ready(child)
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s') -- markers still present: opens the confirm float
  MiniTest.expect.equality(child.lua_get('vim.api.nvim_win_get_config(0).relative'), 'editor')
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') ~= nil, true)

  child.type_keys('n') -- declines
  MiniTest.expect.equality(child.lua_get('vim.api.nvim_win_get_config(0).relative'), '')
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') ~= nil, true)

  child.type_keys('s') -- asks again
  MiniTest.expect.equality(child.lua_get('vim.api.nvim_win_get_config(0).relative'), 'editor')
  arm_ready_raw('render')
  child.type_keys('y') -- accepts
  ui.wait_ready_raw(child)
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') == nil, true)

  child.cmd('Diffy close')
end

T['the same flow works during a rebase conflict'] = function()
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
  local w = ui.wins(child)

  MiniTest.expect.equality(buf_lines(w.ours), { 'l1', 'MAIN', 'l3' })
  MiniTest.expect.equality(buf_lines(w.theirs), { 'l1', 'FEATURE', 'l3' })

  child.api.nvim_set_current_win(w.result)
  child.fn.win_execute(w.result, 'call cursor(4, 1)') -- inside the conflict, on "======="
  child.type_keys('gho')
  child.cmd('write')
  MiniTest.expect.equality(buf_lines(w.result), { 'l1', 'MAIN', 'l3' })

  ui.arm_ready(child, 'render')
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('s')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.git(repo.dir, { 'status', '--porcelain=v2' }):find('^u ') == nil, true)

  child.cmd('Diffy close')
end

T['selecting a normal file after a U row restores the 2-window diff area'] = function()
  repo = conflict_repo()
  child.fn.chdir(repo.dir)
  vim.fn.writefile({ 'g1', 'edited' }, repo.dir .. '/g.txt')

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
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
  MiniTest.expect.equality(vim.tbl_contains(ui.layout(child).bars, 'result  f.txt'), true)
  -- <CR> moved to the result window, the one to edit
  MiniTest.expect.equality(child.lua_get('vim.wo.winbar'), 'result  f.txt')

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(g_line))
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  local lay = ui.layout(child)
  MiniTest.expect.equality(vim.tbl_contains(lay.bars, 'result  f.txt'), false)
  MiniTest.expect.equality(lay.right.path, 'g.txt')
  MiniTest.expect.equality(lay.diff, true)

  child.cmd('Diffy close')
end

return T
