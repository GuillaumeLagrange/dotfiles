-- §4, §12.5 (phase 5): `:Diffy file` builds its log with `--follow`,
-- defaults to the newest commit, and restricts the tree to just the
-- followed file - showing its old name in commits before the rename.
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
    end,
    post_case = function()
      leak.check(child, snapshot)
      if repo then
        repo:destroy()
        repo = nil
      end
    end,
  },
})

-- `Init` never touches old.txt/new.txt, so it falls outside the `--follow`
-- log (it exists only to give `Base`, the file's first commit, a real
-- parent to diff against). Every commit also touches `other.txt`, so the
-- tree's pathspec restriction to just the followed file is exercised, not
-- merely a side effect of every commit happening to touch one file.
local function file_history_repo()
  local r = Repo.new()
  r:commit('Init', { ['other.txt'] = { 'o1' } })
  r:commit('Base', { ['old.txt'] = Repo.lines(5, 'l'), ['other.txt'] = { 'o1', 'o2' } })
  r:mv('old.txt', 'new.txt'):commit('Rename', { ['other.txt'] = { 'o1', 'o2', 'o3' } })
  r:commit('Edit', { ['new.txt'] = Repo.edit(1, 'changed'), ['other.txt'] = { 'o1', 'o2', 'o3', 'o4' } })
  return r
end

local function wins()
  return child.lua_get('require("diffy.session").current().wins')
end

local function buf_lines(win)
  return child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(win))
end

local function subjects()
  return child.lua_get([[(function()
    local out = {}
    for _, e in ipairs(require('diffy.session').current().entries) do
      table.insert(out, e.subject)
    end
    return out
  end)()]])
end

T['§4: :Diffy file follows a file across its rename'] = function()
  repo = file_history_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy file new.txt')
  ui.wait_ready(child)

  MiniTest.expect.equality(subjects(), { 'Edit', 'Rename', 'Base' })

  local w = wins()
  -- default selection: the newest commit; tree restricted to just this file
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().sel'), { top = 1, bottom = 1 })
  MiniTest.expect.equality(#buf_lines(w.tree), 1)
  MiniTest.expect.equality(buf_lines(w.tree)[1]:find('new.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.right .. '].diffy_path'), 'new.txt')

  -- select the rename commit: one row, old -> new, sides old.txt/new.txt
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  child.fn.win_execute(w.log, 'call cursor(2, 1)') -- Edit, Rename
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  MiniTest.expect.equality(#buf_lines(w.tree), 1)
  -- one row, counts right-aligned to the 40-cell panel (§5)
  MiniTest.expect.equality(buf_lines(w.tree)[1], 'R old.txt \226\134\146 new.txt' .. (' '):rep(15) .. '+0 -0')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.left .. '].diffy_path'), 'old.txt')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.right .. '].diffy_path'), 'new.txt')

  -- select the commit that first added the file, before any rename: the
  -- tree shows it under its old name
  child.fn.win_execute(w.log, 'call cursor(3, 1)') -- Edit, Rename, Base
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  MiniTest.expect.equality(#buf_lines(w.tree), 1)
  MiniTest.expect.equality(buf_lines(w.tree)[1], 'A old.txt' .. (' '):rep(25) .. '+5 -0')
  MiniTest.expect.equality(child.lua_get('vim.w[' .. w.right .. '].diffy_path'), 'old.txt')

  child.cmd('Diffy close')
end

return T
