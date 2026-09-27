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

local function wins()
  return child.lua_get('require("diffy.session").current().wins')
end

local function win_diff(win)
  return child.lua_get(('vim.wo[%d].diff'):format(win))
end

local function diffy_path(win)
  return child.lua_get(('vim.w[%d].diffy_path'):format(win))
end

local function buf_lines(win)
  return child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(win))
end

T['jumping to another listed file swaps both sides and highlights the tree'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = wins()
  MiniTest.expect.equality(diffy_path(w.right), 'a.txt')

  child.api.nvim_set_current_win(w.right)
  child.cmd('edit ' .. vim.fn.fnameescape(repo.dir .. '/b.txt'))

  MiniTest.expect.equality(diffy_path(w.right), 'b.txt')
  MiniTest.expect.equality(diffy_path(w.left), 'b.txt')
  MiniTest.expect.equality(win_diff(w.left), true)
  MiniTest.expect.equality(win_diff(w.right), true)

  local cursor_line = child.lua_get(('vim.api.nvim_win_get_cursor(%d)[1]'):format(w.tree))
  local highlighted = buf_lines(w.tree)[cursor_line]
  MiniTest.expect.equality(highlighted:find('b.txt', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['jumping outside the file list leaves diff mode with a placeholder, and <C-o> restores the pair'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = wins()
  child.api.nvim_set_current_win(w.right)
  child.cmd('edit ' .. vim.fn.fnameescape(repo.dir .. '/outside.txt'))

  MiniTest.expect.equality(win_diff(w.left), false)
  MiniTest.expect.equality(win_diff(w.right), false)
  MiniTest.expect.equality(buf_lines(w.left), { '(outside diff)' })
  local right_name = child.lua_get(('vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(%d))'):format(w.right))
  MiniTest.expect.equality(right_name:find('outside.txt', 1, true) ~= nil, true)

  child.api.nvim_set_current_win(w.right)
  child.type_keys('<C-o>')

  MiniTest.expect.equality(win_diff(w.left), true)
  MiniTest.expect.equality(win_diff(w.right), true)
  MiniTest.expect.equality(diffy_path(w.right), 'a.txt')
  MiniTest.expect.equality(diffy_path(w.left), 'a.txt')

  child.cmd('Diffy close')
end

return T
