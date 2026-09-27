-- §3: a branch view's full selection diffs against the merge-base, so
-- changes merged in from the base branch don't show as branch changes.
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
      repo = Repo.standard()
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

local function wins()
  return child.lua_get('require("diffy.session").current().wins')
end

local function buf_lines(win)
  return child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(win))
end

local function open_file(w, name)
  for i, l in ipairs(buf_lines(w.tree)) do
    if l:find(name, 1, true) then
      child.api.nvim_set_current_win(w.tree)
      child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(i))
      ui.arm_ready(child, 'open_row')
      child.type_keys('<CR>')
      ui.wait_ready(child)
      return
    end
  end
  error(name .. ' not in the tree')
end

T['§3: all commits of :Diffy branch diff against the merge-base; the oldest commit alone against its parent'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
  local w = wins()

  -- default selection is every branch commit: main's line-90 edit, merged
  -- into the branch, is on both sides, so it isn't part of the diff
  open_file(w, 'f.txt')
  MiniTest.expect.equality(buf_lines(w.left)[90], 'main: line 90 v2')
  MiniTest.expect.equality(buf_lines(w.right)[91], 'main: line 90 v2')
  local left_rev = child.lua_get('vim.wo[' .. w.left .. '].winbar'):match('^(%S+)')
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', left_rev }), repo.sha.M2)

  -- C1 alone (the oldest commit, before the merge): its own parent
  local log = buf_lines(w.log)
  local c1
  for i, l in ipairs(log) do
    if l:find(repo.sha.C1:sub(1, 7), 1, true) then
      c1 = i
    end
  end
  child.api.nvim_set_current_win(w.log)
  child.fn.win_execute(w.log, ('call cursor(%d, 1)'):format(c1))
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(buf_lines(w.left)[90], '90')
  MiniTest.expect.equality(buf_lines(w.right)[10], 'feat: line 10')

  child.cmd('Diffy close')
end

return T
