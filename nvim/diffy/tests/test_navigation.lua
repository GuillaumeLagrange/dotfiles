-- §6, §12.4 (phase 4): a `BufWinEnter` in the right diff window swaps the
-- pair when the new buffer's path is in the current file list and
-- highlights it in the tree; otherwise diff mode turns off and the left
-- window shows an "outside diff" placeholder. `<C-o>` restores the pair.
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
      repo = Repo.new():commit('base', {
        ['a.txt'] = Repo.lines(5),
        ['b.txt'] = Repo.lines(5),
        ['outside.txt'] = Repo.lines(5),
      })
      -- unstaged edits so bare `:Diffy` (Unstaged selected) shows a real,
      -- editable worktree file on the right for both a.txt and b.txt (§3)
      vim.fn.writefile({ 'a1 edited', 'a2', 'a3', 'a4', 'a5' }, repo.dir .. '/a.txt')
      vim.fn.writefile({ 'b1 edited', 'b2', 'b3', 'b4', 'b5' }, repo.dir .. '/b.txt')
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

local function win_diff(win)
  return child.lua_get(('vim.wo[%d].diff'):format(win))
end

T['jumping to another listed file swaps both sides and highlights the tree'] = function()
  -- §6
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'a.txt')

  child.api.nvim_set_current_win(w.right)
  child.cmd('edit ' .. vim.fn.fnameescape(repo.dir .. '/b.txt'))

  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.path, l.right.path }, { 'b.txt', 'b.txt' })
  MiniTest.expect.equality(l.diff, true)
  MiniTest.expect.equality(win_diff(w.right), true)

  local current = ui.rows_with(child, 'tree', 'DiffyCurrentFile')
  MiniTest.expect.equality(#current, 1)
  MiniTest.expect.equality(current[1]:find('b.txt', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['jumping outside the file list leaves diff mode with a placeholder, and <C-o> restores the pair'] = function()
  -- §6
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.right)
  child.cmd('edit ' .. vim.fn.fnameescape(repo.dir .. '/outside.txt'))

  local l = ui.layout(child)
  MiniTest.expect.equality(l.diff, false)
  MiniTest.expect.equality(win_diff(w.right), false)
  MiniTest.expect.equality(l.left.text, { '(outside diff)' })
  MiniTest.expect.equality(l.right.name, repo.dir .. '/outside.txt')

  child.api.nvim_set_current_win(w.right)
  child.type_keys('<C-o>')

  l = ui.layout(child)
  MiniTest.expect.equality(l.diff, true)
  MiniTest.expect.equality(win_diff(w.right), true)
  MiniTest.expect.equality({ l.left.path, l.right.path }, { 'a.txt', 'a.txt' })

  child.cmd('Diffy close')
end

return T
