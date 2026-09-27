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

T['§3: selecting Base..M2 shows f.txt with left = base content and right = M2 content'] = function()
  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.M2))
  ui.wait_ready(child)

  -- §3
  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.path, l.right.path }, { 'f.txt', 'f.txt' })

  local left_lines = l.left.text
  local right_lines = l.right.text
  -- base: line 1 untouched, line 90 still its original numbered content
  MiniTest.expect.equality(left_lines[1], '1')
  MiniTest.expect.equality(left_lines[90], '90')
  -- M2: line 90 holds the second edit made on main
  MiniTest.expect.equality(right_lines[1], '1')
  MiniTest.expect.equality(right_lines[90], 'main: line 90 v2')
  -- the left winbar names a rev that resolves to the base commit
  MiniTest.expect.equality(ui.git(repo.dir, { 'rev-parse', l.left.rev }), repo.sha.Base)

  child.cmd('Diffy close')
end

T['§5: a rename shows as one entry whose sides are the old and new file'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  -- §5
  local w = ui.wins(child)
  local tree_lines = ui.layout(child).tree
  local rename_lnum
  for i, l in ipairs(tree_lines) do
    if l:find('R h.txt', 1, true) then
      rename_lnum = i
    end
  end
  MiniTest.expect.equality(tree_lines[rename_lnum], 'R h.txt \226\134\146 i.txt' .. (' '):rep(19) .. '+0 -0')

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(rename_lnum))
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.path, l.right.path }, { 'h.txt', 'i.txt' })
  local old = vim.split(ui.git(repo.dir, { 'show', l.left.rev .. ':h.txt' }), '\n')
  MiniTest.expect.equality(old[1], 'h1')
  MiniTest.expect.equality(l.left.text, old)
  MiniTest.expect.equality(l.right.text, old)

  child.cmd('Diffy close')
end

T['§5: <CR> in the tree opens the pair and moves to the new side; o stays in the tree'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')
  ui.arm_ready(child, 'open_row')
  child.type_keys('o')
  ui.wait_ready(child)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.tree)

  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(child.api.nvim_get_current_win(), w.right)

  child.cmd('Diffy close')
end

return T
