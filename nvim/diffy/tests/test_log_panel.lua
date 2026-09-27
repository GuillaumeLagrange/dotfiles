-- §2, §3, §4, §12.2 (phase 2): the log for `:Diffy branch`, merge
-- dimming/navigation-skip, and the log's fixed full-list height.
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


local function subject(text)
  return (text:gsub('^\226\150\140', ''):gsub('^%s*', ''):gsub('^%x%x%x%x%x%x%x ', ''))
end

-- Subjects of the given log rows (default: every row), 'Unstaged'/'Staged' included.
local function subjects(texts)
  local out = {}
  for i, t in ipairs(texts or ui.layout(child).log) do
    out[i] = subject(t)
  end
  return out
end

local function selected()
  return subjects(ui.rows_with(child, 'log', 'DiffySelection'))
end

local function open_branch()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

local function select_row(row)
  local w = ui.wins(child)
  child.api.nvim_set_current_win(w.log)
  child.api.nvim_win_set_cursor(w.log, { row, 0 })
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)
end

T[':Diffy branch lists Unstaged, Staged and the branch commits, with only the merge dimmed'] = function()
  -- §3, §4
  open_branch()

  MiniTest.expect.equality(
    subjects(),
    { 'Unstaged', 'Staged', 'Shift', 'Add', 'Delete', 'Rename', 'Merge branch \'main\' into feat', 'C1' }
  )
  MiniTest.expect.equality(subjects(ui.rows_with(child, 'log', 'DiffyMerge')), { 'Merge branch \'main\' into feat' })

  child.cmd('Diffy close')
end

T[']r from the commit before the merge lands on the commit after it, skipping it'] = function()
  -- §3
  open_branch()
  select_row(6)
  MiniTest.expect.equality(selected(), { 'Rename' })

  child.api.nvim_set_current_win(ui.wins(child).right)
  ui.arm_ready(child, 'select')
  child.type_keys(']r')
  ui.wait_ready(child)

  MiniTest.expect.equality(selected(), { 'C1' })
  MiniTest.expect.equality(ui.layout(child).tree, { 'M f.txt' .. (' '):rep(27) .. '+1 -1' })

  child.cmd('Diffy close')
end

T['the log always lists every entry, sized min(#entries, 40% of the column), focused or not'] = function()
  -- §2
  child.o.lines = 40
  open_branch()
  local w = ui.wins(child)
  local function heights()
    return child.lua_get(('{ vim.api.nvim_win_get_height(%d), vim.api.nvim_win_get_height(%d) }'):format(w.tree, w.log))
  end
  local all = { 'Unstaged', 'Staged', 'Shift', 'Add', 'Delete', 'Rename', 'Merge branch \'main\' into feat', 'C1' }

  local h = heights()
  MiniTest.expect.equality(h[2], math.min(#all, math.floor((h[1] + h[2]) * 0.4)))
  MiniTest.expect.equality(subjects(), all)

  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  child.type_keys('<C-w>k')
  MiniTest.expect.equality(heights(), h)
  MiniTest.expect.equality(subjects(), all)

  child.cmd('Diffy close')
end

T['rapid J J J ends up showing the last selection, even if an earlier one\'s git calls resolve later'] = function()
  -- §2, §3
  open_branch()
  select_row(4) -- Add

  -- J visits Delete, Rename, then (skipping the merge) C1. Hold back every
  -- diff call naming Delete's commit until released below, so its render
  -- completes only after C1's has landed.
  local delete = ui.git(repo.dir, { 'log', '--format=%H', '--grep=^Delete$' })
  child.lua(([[
    local run_mod = require('diffy.git.run')
    local real_git = run_mod.git
    _G.__deferred = {}
    run_mod.git = function(args, opts)
      if args[1] == 'diff' and table.concat(args, ' '):find(%q, 1, true) then
        table.insert(_G.__deferred, function() real_git(args, opts) end)
        return nil
      end
      return real_git(args, opts)
    end
  ]]):format(delete))

  ui.arm_ready(child, 'select')
  child.type_keys('J')
  child.type_keys('J')
  child.type_keys('J')
  ui.wait_ready(child)

  local c1_tree = { 'M f.txt' .. (' '):rep(27) .. '+1 -1' }
  MiniTest.expect.equality(selected(), { 'C1' })
  MiniTest.expect.equality(ui.layout(child).tree, c1_tree)

  -- release the stale render (name-status, then the numstat it triggers)
  for _ = 1, 10 do
    child.lua([[
      while #_G.__deferred > 0 do
        table.remove(_G.__deferred, 1)()
      end
    ]])
    child.lua('vim.wait(300, function() return #_G.__deferred > 0 end)')
  end

  MiniTest.expect.equality(ui.layout(child).tree, c1_tree)
  MiniTest.expect.equality(selected(), { 'C1' })

  child.cmd('Diffy close')
end

return T
