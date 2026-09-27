-- Contiguous-range resolution (left = parent of
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

T['selecting Base..M2 shows f.txt with left = base content and right = M2 content'] = function()
  ui.arm_ready(child, 'render')
  child.cmd(('Diffy %s..%s'):format(repo.sha.Base, repo.sha.M2))
  ui.wait_ready(child)

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

T['a rename shows as one entry whose sides are the old and new file'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

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

local function open_file(path, key)
  ui.open_tree_row(child, path, key or 'o', 'open_row')
end

T['<CR> in the tree opens the pair and moves to the new side; o stays in the tree'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)

  open_file('f.txt', 'o')
  MiniTest.expect.equality(child.api.nvim_get_current_win(), ui.wins(child).tree)
  open_file('f.txt', '<CR>')
  MiniTest.expect.equality(child.api.nvim_get_current_win(), ui.wins(child).right)

  child.cmd('Diffy close')
end

--- Highlight groups of the extmarks covering line `lnum` of the `side`
--- diff window.
local function colour(side, lnum)
  return child.lua(([[
    local s = require('diffy.session').for_tab(vim.api.nvim_get_current_tabpage())
    local buf = vim.api.nvim_win_get_buf(s.wins[%q])
    local out = {}
    for _, m in ipairs(vim.inspect_pos(buf, %d, 0).extmarks) do
      table.insert(out, m.opts.hl_group)
    end
    return out
  ]]):format(side, lnum - 1))
end

T['an added or deleted file fills the diff area, coloured as such; a modified one brings the pair back'] = function()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
  local function shown()
    local l = ui.layout(child)
    local bars = vim.tbl_filter(function(b)
      return b ~= ''
    end, l.bars)
    return { left = l.left ~= vim.NIL and l.left.path or false, right = l.right ~= vim.NIL and l.right.path or false, windows = #bars }
  end

  open_file('d.txt')
  MiniTest.expect.equality(shown(), { left = 'd.txt', right = false, windows = 1 })
  MiniTest.expect.equality({ colour('left', 1), colour('left', 10) }, { { 'DiffyFileDeleted' }, { 'DiffyFileDeleted' } })

  open_file('new.txt')
  MiniTest.expect.equality(shown(), { left = false, right = 'new.txt', windows = 1 })
  MiniTest.expect.equality(colour('right', 20), { 'DiffyFileAdded' })

  open_file('f.txt')
  MiniTest.expect.equality(shown(), { left = 'f.txt', right = 'f.txt', windows = 2 })
  MiniTest.expect.equality({ ui.layout(child).diff, colour('right', 1) }, { true, {} })

  child.cmd('Diffy close')
end

return T
