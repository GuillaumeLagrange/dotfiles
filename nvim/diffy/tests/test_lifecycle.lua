-- §1, §12.1 (phase 1): every teardown path leaves no diffy state, and two
-- sessions in separate tabs are fully independent.
local Repo = require('tests.helpers.repo')
local leak = require('tests.helpers.leak')

local child = MiniTest.new_child_neovim()
local snapshot
local repo

local function tabs()
  return child.lua_get('#vim.api.nvim_list_tabpages()')
end

local function session_count()
  return child.lua_get('vim.tbl_count(require("diffy.session").sessions)')
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
  MiniTest.expect.equality(session_count(), 1)
  local names = child.lua_get([[(function()
    local s = require('diffy.session').current()
    local out = {}
    for name, win in pairs(s.wins) do out[name] = vim.api.nvim_win_is_valid(win) end
    return out
  end)()]])
  MiniTest.expect.equality(names, { tree = true, log = true, left = true, right = true })
end

T['closing the tab with :tabclose leaves no diffy state'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('tabclose')
  wait_tabs(1)
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(session_count(), 0)
end

T['quitting a managed window closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' }, { 'left' }, { 'right' } },
})

T['quitting a managed window closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  local winid = child.lua_get(('require("diffy.session").current().wins.%s'):format(name))
  child.fn.win_gotoid(winid)
  child.cmd('q')
  wait_tabs(1)
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(session_count(), 0)
end

T['wiping a panel buffer closes the whole session'] = MiniTest.new_set({
  parametrize = { { 'tree' }, { 'log' } },
})

T['wiping a panel buffer closes the whole session']['leaves no diffy state'] = function(name)
  child.cmd('Diffy')
  local bufnr = child.lua_get(('require("diffy.session").current().bufs.%s'):format(name))
  child.cmd(('bwipeout! %d'):format(bufnr))
  wait_tabs(1)
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(session_count(), 0)
end

T[':Diffy close tears down the session'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('Diffy close')
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(session_count(), 0)
end

T['VimLeavePre tears down every open session'] = function()
  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 2)
  child.cmd('doautocmd VimLeavePre')
  MiniTest.expect.equality(tabs(), 1)
  MiniTest.expect.equality(session_count(), 0)
end

T['two sessions in separate tabs are independent'] = function()
  child.cmd('Diffy')
  local tab1 = child.lua_get('require("diffy.session").current().tab')

  child.cmd('Diffy')
  MiniTest.expect.equality(tabs(), 3)
  MiniTest.expect.equality(session_count(), 2)
  local tab2 = child.lua_get('require("diffy.session").current().tab')
  MiniTest.expect.equality(tab1 == tab2, false)

  -- close session 2 only; session 1 must stay fully intact
  child.cmd('Diffy close')
  MiniTest.expect.equality(tabs(), 2)
  MiniTest.expect.equality(session_count(), 1)

  local session1_ok = child.lua_get((([[(function()
    local s = require('diffy.session').for_tab(%d)
    if not s then return false end
    for _, w in pairs(s.wins) do
      if not vim.api.nvim_win_is_valid(w) then return false end
    end
    for _, b in pairs(s.bufs) do
      if not vim.api.nvim_buf_is_valid(b) then return false end
    end
    return true
  end)()]]):format(tab1)))
  MiniTest.expect.equality(session1_ok, true)
end

return T
