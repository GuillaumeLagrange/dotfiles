-- Screenshot of the default `:Diffy` layout (tree/log
-- column, diff pair, winbars).
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
      -- a fixed path (not `vim.fn.tempname()`'s random one): the screenshot
      -- embeds the worktree's absolute path, which must be stable to diff
      -- against a committed reference.
      local fixed_dir = '/tmp/diffy-screenshot-fixture'
      vim.fn.delete(fixed_dir, 'rf')
      repo = Repo.new()
      vim.fn.rename(repo.dir, fixed_dir)
      repo.dir = fixed_dir
      repo:commit('base', { ['f.txt'] = Repo.lines(20), ['g.txt'] = Repo.lines(5, 'g') })
      repo:commit('edit', { ['f.txt'] = Repo.edit(10, 'changed') })
      -- an uncommitted worktree edit, so the default `Unstaged` selection
      -- has something real to show.
      vim.fn.writefile(Repo.edit(3, 'uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')
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

T['default :Diffy layout'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  MiniTest.expect.reference_screenshot(child.get_screenshot())
  child.cmd('Diffy close')
end

return T
