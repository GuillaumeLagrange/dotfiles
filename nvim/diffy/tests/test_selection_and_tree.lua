-- §3, §5, §12.2 (phase 2): contiguous-range resolution (left = parent of
-- the bottom entry) and the file tree's rename display.
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

T['§3: selecting Base..M2 shows f.txt with left = base content and right = M2 content'] = function()
  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.M2))
  ui.wait_ready(child)

  local w = wins()
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.left .. '].diffy_path'), 'f.txt')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.right .. '].diffy_path'), 'f.txt')

  local left_lines = buf_lines(w.left)
  local right_lines = buf_lines(w.right)
  -- base: line 1 untouched, line 90 still its original numbered content
  MiniTest.expect.equality(left_lines[1], '1')
  MiniTest.expect.equality(left_lines[90], '90')
  -- M2: line 90 holds the second edit made on main
  MiniTest.expect.equality(right_lines[1], '1')
  MiniTest.expect.equality(right_lines[90], 'main: line 90 v2')

  child.cmd('Diffy close')
end

T['§5: a rename shows as one entry whose sides are the old and new file'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  local w = wins()
  local tree_lines = buf_lines(w.tree)
  local rename_lnum
  for i, l in ipairs(tree_lines) do
    if l:find('R h.txt', 1, true) then
      rename_lnum = i
    end
  end
  MiniTest.expect.equality(tree_lines[rename_lnum], 'R h.txt \226\134\146 i.txt  +0 -0')

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(rename_lnum))
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.left .. '].diffy_path'), 'h.txt')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.right .. '].diffy_path'), 'i.txt')
  local left_lines = buf_lines(w.left)
  local right_lines = buf_lines(w.right)
  MiniTest.expect.equality(left_lines[1], 'h1')
  MiniTest.expect.equality(right_lines[1], 'h1')
  MiniTest.expect.equality(#left_lines, 40)
  MiniTest.expect.equality(#right_lines, 40)

  child.cmd('Diffy close')
end

return T
