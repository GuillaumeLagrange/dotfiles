-- Panel column toggle and single-line, width-fitted tree rows.
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
      child.o.lines, child.o.columns = 30, 120
      snapshot = leak.snapshot(child)
      repo = nil
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
      end
    end,
  },
})

local function tab_wins()
  return child.lua_get('vim.api.nvim_tabpage_list_wins(0)')
end

T['the panel toggle hides the column (diff spans the width, ]f still works) and brings it back'] = function()
  repo = Repo.new():commit('Base', { ['a.txt'] = Repo.lines(5, 'a'), ['b.txt'] = Repo.lines(5, 'b') })
  vim.fn.writefile({ 'a1', 'changed' }, repo.dir .. '/a.txt')
  vim.fn.writefile({ 'b1', 'changed' }, repo.dir .. '/b.txt')
  child.fn.chdir(repo.dir)
  child.o.number = true

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local w = ui.wins(child)
  local before_hide = ui.layout(child)

  -- hide with the buffer-local key from a diff window
  child.api.nvim_set_current_win(w.left)
  child.type_keys('\\e')
  local hidden = ui.layout(child)
  MiniTest.expect.equality({ hidden.tree, hidden.log }, { vim.NIL, vim.NIL })
  MiniTest.expect.equality(#tab_wins(), 2)
  local lw, rw = child.api.nvim_win_get_width(w.left), child.api.nvim_win_get_width(w.right)
  MiniTest.expect.equality(lw + rw + 1, child.o.columns)
  MiniTest.expect.equality(math.abs(lw - rw) <= 1, true)
  MiniTest.expect.equality(hidden.left.path, 'a.txt')

  child.api.nvim_set_current_win(w.right)
  ui.arm_ready(child, 'open_row')
  child.type_keys(']f')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'b.txt')

  -- show again: same content, panel width, clean window options
  child.cmd('Diffy panel')
  w = ui.wins(child)
  local shown = ui.layout(child)
  MiniTest.expect.equality(shown.tree, before_hide.tree)
  MiniTest.expect.equality(shown.log, before_hide.log)
  MiniTest.expect.equality(child.api.nvim_win_get_width(w.tree), 40)
  MiniTest.expect.equality(child.lua_get('vim.wo[' .. w.tree .. '].number'), false)

  -- tree keys still open files after the re-show
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')
  ui.arm_ready(child, 'open_row')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(ui.layout(child).right.path, 'a.txt')

  -- hidden again, then closed: post_case's leak check covers the teardown
  child.type_keys('\\e')
  MiniTest.expect.equality(ui.layout(child).tree, vim.NIL)
  child.cmd('Diffy close')
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
end

T['a long path under nested dirs renders as one row fitting the panel, status and counts visible'] = function()
  local long = 'nvim/diffy/lua/diffy/a_rather_long_directory_name/init_with_an_extremely_long_file_name.lua'
  repo = Repo.new():commit('Base', { [long] = Repo.lines(5), ['nvim/diffy/lua/diffy/other.lua'] = Repo.lines(5) })
  vim.fn.writefile({ '1', 'changed', '3', '4', '5' }, repo.dir .. '/' .. long)
  vim.fn.writefile({ '1', '2', 'changed', '4', '5' }, repo.dir .. '/nvim/diffy/lua/diffy/other.lua')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
  local width = child.api.nvim_win_get_width(ui.wins(child).tree)
  local lines = ui.layout(child).tree

  -- header, the long file (relative to its own chain), the sibling
  MiniTest.expect.equality(#lines, 3)
  MiniTest.expect.equality(lines[1], 'nvim/diffy/lua/diffy/')
  local row = lines[2]
  -- truncated from the left with '…', keeping the file name, status and counts
  MiniTest.expect.equality(row:match('^  M \226\128\166') ~= nil, true)
  MiniTest.expect.equality(row:match('long_file_name%.lua +%+1 %-1$') ~= nil, true)
  MiniTest.expect.equality(row:find('a_rather', 1, true), nil)
  MiniTest.expect.equality(lines[3]:match('^  M other%.lua +%+1 %-1$') ~= nil, true)
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(child.fn.strdisplaywidth(l) <= width, true)
  end

  child.cmd('Diffy close')
end

return T
