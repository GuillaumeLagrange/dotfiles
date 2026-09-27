-- §7, §12.4 (phase 4): `X` on a single selected commit refuses with a
-- dirty tree (HEAD untouched); leaving it (closing the tab) restores the
-- original branch; an interrupted checkout (nvim killed) is warned about on
-- the next `:Diffy` and recovered by `:Diffy restore`.
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
      snapshot = leak.snapshot(child)
      repo = Repo.new()
        :commit('base', { ['f.txt'] = Repo.lines(5) })
        :branch('feat')
        :commit('C1', { ['f.txt'] = Repo.edit(1, 'C1 change') })
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

local function state_file()
  return repo.dir .. '/.git/diffy/checkout.json'
end

T['`X` on a commit with a dirty tree refuses, leaving HEAD untouched'] = function()
  -- §7
  vim.fn.writefile({ 'dirty, uncommitted' }, repo.dir .. '/f.txt')

  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  child.api.nvim_set_current_win(ui.wins(child).log)
  ui.arm_ready(child, 'checkout')
  child.type_keys('X')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C1)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)

  child.cmd('Diffy close')
end

T['`X` then closing the tab returns to the original branch'] = function()
  -- §7
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  child.api.nvim_set_current_win(ui.wins(child).log)
  ui.arm_ready(child, 'checkout')
  child.type_keys('X')
  ui.wait_ready(child)

  -- checked out: HEAD detached at C1, right side is now a real (WORKTREE) file
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C1)
  local branch_ok = pcall(ui.git, repo.dir, { 'symbolic-ref', '-q', 'HEAD' })
  MiniTest.expect.equality(branch_ok, false)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 1)
  MiniTest.expect.equality(ui.layout(child).right.rev, 'worktree')

  ui.arm_ready(child, 'close')
  child.cmd('Diffy close')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
  MiniTest.expect.equality(#child.api.nvim_list_tabpages(), 1)
end

T['nvim killed during a checkout: the next :Diffy warns, and :Diffy restore returns to the branch'] = function()
  -- §7
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  child.api.nvim_set_current_win(ui.wins(child).log)
  ui.arm_ready(child, 'checkout')
  child.type_keys('X')
  ui.wait_ready(child)
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 1)

  -- simulate `nvim` being killed outright (no VimLeavePre, unlike
  -- `child.stop()`/`child.restart()`, which run `:0cquit` and do fire it)
  local pid = child.lua_get('vim.fn.getpid()')
  vim.system({ 'kill', '-9', tostring(pid) }):wait()

  child.restart({ '-u', 'tests/minimal_init.lua' })
  snapshot = leak.snapshot(child) -- fresh process: rebase the post_case baseline
  child.fn.chdir(repo.dir)
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', 'HEAD' }), repo.sha.C1) -- still detached

  child.lua([[
    _G.__warns = 0
    local orig = vim.notify
    vim.notify = function(msg, level, ...)
      if level == vim.log.levels.WARN or level == vim.log.levels.ERROR then
        _G.__warns = _G.__warns + 1
      end
      return orig(msg, level, ...)
    end
  ]])
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.equality(child.lua_get('_G.__warns') >= 1, true)
  child.cmd('Diffy close')

  ui.arm_ready(child, 'restore')
  child.cmd('Diffy restore')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'symbolic-ref', '--short', 'HEAD' }), 'feat')
  MiniTest.expect.equality(vim.fn.filereadable(state_file()), 0)
end

return T
