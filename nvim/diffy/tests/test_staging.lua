-- §5, §12.3 (phase 3): tree staging keys, the Unstaged/Staged sides, and
-- nested directory grouping.
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

local function tree()
  return ui.layout(child).tree
end

local function select_log_row(needle)
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.log)
  local row
  for i, l in ipairs(ui.layout(child).log) do
    if not row and l:find(needle, 1, true) then
      row = i
    end
  end
  child.api.nvim_win_set_cursor(w.log, { row, 0 })
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)
end

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

T['Unstaged shows index/worktree, and writing the left buffer stages exactly the edited hunk'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(20) })
  local edited = Repo.lines(20)
  edited[5] = 'edited5'
  edited[15] = 'edited15'
  vim.fn.writefile(edited, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local l = ui.layout(child)
  MiniTest.expect.equality({ l.left.rev, l.left.path }, { 'index', 'f.txt' })
  MiniTest.expect.equality({ l.right.rev, l.right.path }, { 'worktree', 'f.txt' })
  local w = ui.wins(child)

  child.api.nvim_set_current_win(w.left)
  child.fn.win_execute(w.left, 'call cursor(5, 1)')
  child.type_keys('do')
  child.cmd('write')

  -- check the changed lines themselves, not the hunk header (git's context
  -- annotation on `@@ ... @@` can echo either edited line as text)
  local staged = ui.git(repo.dir, { 'diff', '--cached' })
  MiniTest.expect.equality(staged:find('+edited5', 1, true) ~= nil, true)
  MiniTest.expect.equality(staged:find('+edited15', 1, true) ~= nil, false)

  local unstaged = ui.git(repo.dir, { 'diff' })
  MiniTest.expect.equality(unstaged:find('+edited15', 1, true) ~= nil, true)
  MiniTest.expect.equality(unstaged:find('+edited5', 1, true) ~= nil, false)

  child.cmd('Diffy close')
end

T['`s` on an unstaged file stages it, then `u` from Staged unstages it again'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['f.txt'] = Repo.lines(5), ['g.txt'] = Repo.lines(5) })
  vim.fn.writefile({ 'changed' }, repo.dir .. '/g.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')

  ui.arm_ready(child, 'render')
  child.type_keys('s')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), 'g.txt')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), '')

  select_log_row('Staged')
  child.api.nvim_set_current_win(w.tree)
  child.api.nvim_win_set_cursor(w.tree, { find_line(tree(), 'g.txt'), 0 })
  ui.arm_ready(child, 'render')
  child.type_keys('u')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), 'g.txt')

  child.cmd('Diffy close')
end

T['`u` on a staged rename pair unstages both paths'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['h.txt'] = Repo.lines(5) })
  repo:mv('h.txt', 'i.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  select_log_row('Staged')
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  local lnum = find_line(tree(), 'R h.txt')
  MiniTest.expect.equality(lnum ~= nil, true)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(lnum))

  ui.arm_ready(child, 'render')
  child.type_keys('u')
  ui.wait_ready(child)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  -- `ui.git` trims the whole output, dropping the first line's leading
  -- status-column space; match the rest of each porcelain line instead
  local status = ui.git(repo.dir, { 'status', '--porcelain' })
  MiniTest.expect.equality(status:find('D h.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(status:find('?? i.txt', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['an unstaged rename shows as D + ?, as R after `git add -N`, and `s` stages both paths'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['h.txt'] = Repo.lines(5) })
  os.rename(repo.dir .. '/h.txt', repo.dir .. '/i.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local w = ui.wins(child)
  local before = tree()
  MiniTest.expect.equality(find_line(before, 'D h.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(before, '? i.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(before, 'R h.txt') == nil, true)

  ui.git(repo.dir, { 'add', '-N', 'i.txt' })
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)

  local after = tree()
  local lnum = find_line(after, 'R h.txt \226\134\146 i.txt')
  MiniTest.expect.equality(lnum ~= nil, true)

  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(lnum))
  ui.arm_ready(child, 'render')
  child.type_keys('s') -- stage the rename pair from its Unstaged (intent-to-add) row
  ui.wait_ready(child)

  local staged = ui.git(repo.dir, { 'diff', '--cached', '-M', '--name-status' })
  MiniTest.expect.equality(staged:sub(1, 1), 'R')
  MiniTest.expect.equality(staged:find('h.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(staged:find('i.txt', 1, true) ~= nil, true)
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), '')

  child.cmd('Diffy close')
end

T['staging keys are a no-op, with a warning, when the selection is not exactly Unstaged or Staged'] = function()
  -- §5
  repo = Repo.standard()
  local cur = vim.fn.readfile(repo.dir .. '/f.txt')
  cur[1] = 'dirty'
  vim.fn.writefile(cur, repo.dir .. '/f.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  select_log_row('Shift') -- touches f.txt, same file as the dirty edit
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, 'call cursor(1, 1)')

  -- observe only that a warning fires, never its exact wording (§11.3.4)
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
  child.type_keys('s')
  MiniTest.expect.equality(child.lua_get('_G.__warns') >= 1, true)

  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--cached', '--name-only' }), '')
  MiniTest.expect.equality(ui.git(repo.dir, { 'diff', '--name-only' }), 'f.txt')

  child.cmd('Diffy close')
end

T['nested directories group under collapsible headers, single-child chains flattened'] = function()
  -- §5
  repo = Repo.new()
    :commit('Base', { ['top.txt'] = Repo.lines(1) })
    :commit('Add', {
      ['a/b/c/file1.txt'] = Repo.lines(1),
      ['a/b/c/file2.txt'] = Repo.lines(1),
      ['a/d/file3.txt'] = Repo.lines(1),
    })
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.Add))
  ui.wait_ready(child)

  local w = ui.wins(child)
  local lines = tree()

  local function has(text)
    for _, l in ipairs(lines) do
      if l == text then
        return true
      end
    end
    return false
  end

  -- a/b/c collapses into one "b/c/" row under "a/" (chain flattening), not
  -- three separate header rows
  MiniTest.expect.equality(has('a/'), true)
  MiniTest.expect.equality(has('  b/c/'), true)
  MiniTest.expect.equality(has('b/'), false)
  MiniTest.expect.equality(has('c/'), false)
  -- a/d holds a single file, so `d/` never gets a header row at all
  MiniTest.expect.equality(has('d/'), false)

  -- rows under a header show the path relative to it (§5)
  local f1 = find_line(lines, 'A file1.txt')
  local f3 = find_line(lines, 'A d/file3.txt')
  MiniTest.expect.equality(find_line(lines, 'a/b/c/file1.txt'), nil)
  MiniTest.expect.equality(lines[f1]:match('^(%s*)'), '    ')
  MiniTest.expect.equality(lines[f3]:match('^(%s*)'), '  ')

  -- foldmethod=indent starts a fold at the first *indented* line, not the
  -- shallower header above it - za on "  b/c/" folds it and its files,
  -- leaving "a/" visible above the closed fold
  local child_line
  for i, l in ipairs(lines) do
    if l == '  b/c/' then
      child_line = i
    end
  end
  MiniTest.expect.equality(child_line ~= nil, true)
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(child_line))
  child.type_keys('za')
  local closed = child.lua_get(
    ('vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(%d) end)'):format(w.tree, child_line)
  )
  MiniTest.expect.equality(closed, child_line)

  child.cmd('Diffy close')
end

T['a new untracked directory shows its files individually as ? rows, grouped under a header'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['top.txt'] = Repo.lines(1) })
  vim.fn.mkdir(repo.dir .. '/newdir', 'p')
  vim.fn.writefile({ 'x' }, repo.dir .. '/newdir/a.txt')
  vim.fn.writefile({ 'y' }, repo.dir .. '/newdir/b.txt')
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)

  local lines = tree()

  local function has_exact(text)
    for _, l in ipairs(lines) do
      if l == text then
        return true
      end
    end
    return false
  end

  -- plain `git status` (no `--untracked-files=all`) reports a brand-new
  -- untracked directory as one `?? newdir/` entry, rendered as a single
  -- flattened `? newdir/` row with no header and no per-file rows; fails
  -- without `repo.status` passing `--untracked-files=all`, which reports
  -- (and so renders) both files individually instead
  MiniTest.expect.equality(has_exact('? newdir/'), false)
  MiniTest.expect.equality(has_exact('newdir/'), true)
  local a_lnum = find_line(lines, '? a.txt')
  local b_lnum = find_line(lines, '? b.txt')
  MiniTest.expect.equality(find_line(lines, 'newdir/a.txt'), nil)
  MiniTest.expect.equality(a_lnum ~= nil, true)
  MiniTest.expect.equality(b_lnum ~= nil, true)
  -- grouped under the directory's own header row, indented one level in
  MiniTest.expect.equality(lines[a_lnum]:match('^(%s*)'), '  ')
  MiniTest.expect.equality(lines[b_lnum]:match('^(%s*)'), '  ')

  child.cmd('Diffy close')
end

T['staging from Unstaged in :Diffy branch keeps Unstaged selected'] = function()
  -- §5
  repo = Repo.new():commit('Base', { ['base.txt'] = Repo.lines(5) })
  repo:branch('feat'):commit('C1', { ['committed.txt'] = Repo.lines(3) })
  vim.fn.writefile({ 'dirty a' }, repo.dir .. '/a.txt')
  vim.fn.writefile({ 'dirty b' }, repo.dir .. '/b.txt')
  ui.git(repo.dir, { 'add', '-N', 'a.txt', 'b.txt' })
  child.fn.chdir(repo.dir)

  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
  select_log_row('Unstaged')
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.tree)
  child.fn.win_execute(w.tree, ('call cursor(%d, 1)'):format(find_line(tree(), 'a.txt')))
  ui.arm_ready(child, 'render')
  child.type_keys('s')
  ui.wait_ready(child)

  -- still the Unstaged view: only b.txt left, not the branch's committed file
  MiniTest.expect.equality(ui.rows_with(child, 'log', 'DiffySelection'), { '\226\150\140 Unstaged' })
  local t = tree()
  MiniTest.expect.equality(find_line(t, 'b.txt') ~= nil, true)
  MiniTest.expect.equality(find_line(t, 'a.txt'), nil)
  MiniTest.expect.equality(find_line(t, 'committed.txt'), nil)

  child.cmd('Diffy close')
end

return T
