-- Every teardown path leaves no diffy state, and two
-- sessions in separate tabs are fully independent.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local function tabs()
  return child.lua_get('#vim.api.nvim_list_tabpages()')
end

-- teardown is complete when only the original tab is left and no diffy://
-- buffer survives
local function expect_no_session()
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
  MiniTest.expect.equality(ui.layout(child), nil)
end

-- some paths defer teardown to the next tick (see session.lua's
-- watch_close/watch_wipe); wait for the observable effect instead of
-- asserting immediately.
local function wait_tabs(n)
  child.lua(('vim.wait(500, function() return #vim.api.nvim_list_tabpages() == %d end)'):format(n))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      repo = Repo.new():commit('base', { ['f.txt'] = Repo.lines(5) })
      child.fn.chdir(repo.dir)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

T[':Diffy opens a session tab with the layout skeleton'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  local l = ui.layout(child)
  MiniTest.expect.equality(l ~= nil, true)
  MiniTest.expect.equality(
    { tree = l.tree ~= vim.NIL, log = l.log ~= vim.NIL, left = l.left ~= vim.NIL, right = l.right ~= vim.NIL },
    { tree = true, log = true, left = true, right = true }
  )
  MiniTest.expect.equality(#l.bars, 4)
end

T['closing the tab with :tabclose leaves no diffy state'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('tabclose')
  wait_tabs(1)
  expect_no_session()
end

T[':tabclose before DiffyReady tears down cleanly, and the pending async render is a no-op'] = function()
  -- deterministically reproduce the race (real subprocess completion time
  -- is not reliable enough to race against on its own): hold back the
  -- delivery of `M.start`'s very first git call (`repo.root`, still a real
  -- `git rev-parse` subprocess) until released below, standing in for it
  -- completing after the tab is already gone.
  child.lua([[
    local real_system = vim.system
    _G.__release_root = nil
    vim.system = function(cmd, opts, on_exit)
      if cmd[1] == 'git' and cmd[2] == 'rev-parse' and cmd[3] == '--show-toplevel' then
        return real_system(cmd, opts, function(res)
          _G.__release_root = function() on_exit(res) end
        end)
      end
      return real_system(cmd, opts, on_exit)
    end
  ]])

  child.lua("vim.v.errmsg = ''")
  child.cmd('Diffy')
  child.cmd('tabclose')
  wait_tabs(1)
  expect_no_session()

  -- release the held-back completion now that the session is gone, then
  -- give the rest of the (real, unpatched) chain it kicks off - `git log`,
  -- `head_sha`, `status`, the tree's own two `git diff` calls - actual
  -- wall-clock time to run all the way to its former crash point
  child.lua('vim.wait(2000, function() return _G.__release_root ~= nil end)')
  child.lua('_G.__release_root()')
  child.lua("vim.wait(1500, function() return vim.v.errmsg ~= '' end)")

  MiniTest.expect.equality(child.lua_get('vim.v.errmsg'), '')
  expect_no_session()
end

T['quitting a managed window closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' }, { 'left' }, { 'right' } },
})

T['quitting a managed window closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  child.fn.win_gotoid(ui.wins(child)[name])
  child.cmd('q')
  wait_tabs(1)
  expect_no_session()
end

T['wiping a panel buffer closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' } },
})

T['wiping a panel buffer closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  local bufnr = child.api.nvim_win_get_buf(ui.wins(child)[name])
  child.cmd(('bwipeout! %d'):format(bufnr))
  wait_tabs(1)
  expect_no_session()
end

T[':Diffy close tears down the session'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('Diffy close')
  expect_no_session()
end

T['quitting nvim (VimLeavePre) tears down every open session'] = function()
  -- a real :qa would end the child before anything is observable
  child.cmd('Diffy')
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 3)
  child.cmd('doautocmd VimLeavePre')
  expect_no_session()
end

T['closing one of two session tabs leaves the other working'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(tabs(), 3)

  child.cmd('Diffy close')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('tabnext 2')
  MiniTest.expect.equality(ui.layout(child) ~= nil, true)

  -- session 1 still reacts to its keys: R picks up a new worktree change
  vim.fn.writefile({ 'changed' }, repo.dir .. '/f.txt')
  child.api.nvim_set_current_win(ui.wins(child).tree)
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)
  local l = ui.layout(child)
  MiniTest.expect.equality(vim.iter(l.tree):any(function(t) return t:find('f.txt', 1, true) ~= nil end), true)
  MiniTest.expect.equality(l.right.rev, 'worktree')
  MiniTest.expect.equality(l.right.path, 'f.txt')
end

return T
