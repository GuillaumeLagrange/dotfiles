-- `:Diffy file` builds its log with `--follow`,
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

local function subjects(texts)
  return ui.log_subjects(child, texts)
end

local function select_row(row)
  ui.select_log_row(child, row)
end

T[':Diffy file follows a file across its rename'] = function()
  repo = file_history_repo()
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy file new.txt')
  ui.wait_ready(child)

  MiniTest.expect.equality(subjects(), { 'Edit', 'Rename', 'Base' })

  -- default selection: the newest commit; tree restricted to just this file
  MiniTest.expect.equality(subjects(ui.rows_with(child, 'log', 'DiffySelection')), { 'Edit' })
  local l = ui.layout(child)
  MiniTest.expect.equality(l.tree, { 'M new.txt' .. (' '):rep(25) .. '+1 -1' })
  MiniTest.expect.equality(l.right.path, 'new.txt')

  -- the rename commit: one row, old -> new, sides old.txt/new.txt
  select_row(2)
  l = ui.layout(child)
  MiniTest.expect.equality(l.tree, { 'R old.txt \226\134\146 new.txt' .. (' '):rep(15) .. '+0 -0' })
  MiniTest.expect.equality(l.left.path, 'old.txt')
  MiniTest.expect.equality(l.right.path, 'new.txt')

  -- the commit that added the file, before the rename: shown under its old name
  select_row(3)
  l = ui.layout(child)
  MiniTest.expect.equality(l.tree, { 'A old.txt' .. (' '):rep(25) .. '+5 -0' })
  MiniTest.expect.equality(l.right.path, 'old.txt')

  child.cmd('Diffy close')
end

return T
