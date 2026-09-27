-- §2, §3, §4, §12.2 (phase 2): the log model for `:Diffy branch`, merge
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
      table.insert(out, e.kind == 'commit' and e.subject or e.kind)
    end
    return out
  end)()]])
end

local function open_branch()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy branch main')
  ui.wait_ready(child)
end

T['§3/§4: :Diffy branch lists Unstaged, Staged and the branch commits, merge dimmed'] = function()
  open_branch()

  MiniTest.expect.equality(
    subjects(),
    { 'unstaged', 'staged', 'Shift', 'Add', 'Delete', 'Rename', 'Merge branch \'main\' into feat', 'C1' }
  )

  local merged = child.lua_get([[(function()
    for _, e in ipairs(require('diffy.session').current().entries) do
      if e.kind == 'commit' and e.merge then return true end
    end
    return false
  end)()]])
  MiniTest.expect.equality(merged, true)

  -- rendered dimmed: the merge line carries the merge highlight group
  local merge_hl = child.lua_get([[(function()
    local s = require('diffy.session').current()
    local merge_line
    for i, e in ipairs(s.entries) do
      if e.kind == 'commit' and e.merge then merge_line = i end
    end
    local marks = vim.api.nvim_buf_get_extmarks(s.bufs.log, s.ns.log_render, {merge_line - 1, 0}, {merge_line - 1, -1}, {details = true})
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == 'DiffyMerge' then return true end
    end
    return false
  end)()]])
  MiniTest.expect.equality(merge_hl, true)

  child.cmd('Diffy close')
end

T['§3: ]r from the commit before the merge lands on the commit after it, skipping it'] = function()
  open_branch()
  local w = wins()

  -- select "Rename" (the commit right before the dimmed merge in the list)
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  child.fn.win_execute(w.log, 'call cursor(6, 1)') -- Rename: Unstaged,Staged,Shift,Add,Delete,Rename
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  MiniTest.expect.equality(
    child.lua_get('require("diffy.session").current().entries[require("diffy.session").current().sel.top].subject'),
    'Rename'
  )

  -- ]r from the right diff window skips the merge and lands on C1
  child.api.nvim_set_current_win(w.right)
  ui.arm_ready(child, 'select')
  child.type_keys(']r')
  ui.wait_ready(child)

  local sel = child.lua_get('require("diffy.session").current().sel')
  MiniTest.expect.equality(sel.top, sel.bottom)
  local landed = child.lua_get(('require("diffy.session").current().entries[%d]'):format(sel.top))
  MiniTest.expect.equality(landed.kind, 'commit')
  MiniTest.expect.equality(landed.merge, false)
  MiniTest.expect.equality(landed.subject, 'C1')

  child.cmd('Diffy close')
end

T['§2: the log always lists every entry, sized min(#entries, 40% of the column), focused or not'] = function()
  child.o.lines = 40
  open_branch()
  local w = wins()
  local function heights()
    return child.lua_get(('{ vim.api.nvim_win_get_height(%d), vim.api.nvim_win_get_height(%d) }'):format(w.tree, w.log))
  end

  local h = heights()
  MiniTest.expect.equality(h[2], math.min(#subjects(), math.floor((h[1] + h[2]) * 0.4)))
  MiniTest.expect.equality(#buf_lines(w.log), #subjects())

  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  child.type_keys('<C-w>k')
  MiniTest.expect.equality(heights(), h)
  MiniTest.expect.equality(#buf_lines(w.log), #subjects())

  child.cmd('Diffy close')
end

T['§2/§3: rapid J J J ends up showing the last selection, even if an earlier one\'s git calls resolve later'] = function()
  open_branch()
  local w = wins()

  -- select 'Add' singly first (line 4: Unstaged,Staged,Shift,Add,...)
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  child.fn.win_execute(w.log, 'call cursor(4, 1)')
  ui.arm_ready(child, 'select')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  local g0 = child.lua_get('require("diffy.session").current().gen')

  -- `J` from here visits Delete, Rename, then (skipping the dimmed merge)
  -- C1 - three real, distinct diffs. Defer *issuing* (not just delivering)
  -- Delete's diff calls - the first J's render - until released below, so
  -- its git subprocess only starts, and so only completes and only then
  -- reaches `git/run.lua`'s own gen check, once two more selections have
  -- already landed: a deterministic stand-in for that subprocess simply
  -- taking longer than the next two, real git being unmockable but its
  -- completion order not otherwise controllable from a test.
  child.lua(([[
    local run_mod = require('diffy.git.run')
    local real_git = run_mod.git
    _G.__stale_gen = %d
    _G.__deferred = {}
    run_mod.git = function(args, opts)
      if args[1] == 'diff' and opts.gen == _G.__stale_gen then
        table.insert(_G.__deferred, function() real_git(args, opts) end)
        return nil
      end
      return real_git(args, opts)
    end
  ]]):format(g0 + 1))

  ui.arm_ready(child, 'select')
  child.type_keys('J')
  child.type_keys('J')
  child.type_keys('J')
  ui.wait_ready(child)

  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().sel'), { top = 8, bottom = 8 })
  MiniTest.expect.equality(
    child.lua_get('require("diffy.session").current().entries[8].subject'),
    'C1'
  )
  MiniTest.expect.equality(buf_lines(w.tree), { 'M f.txt' .. (' '):rep(27) .. '+1 -1' })

  -- now let the held-back (stale) render actually run and complete - it
  -- takes two rounds (name-status, then the numstat call it triggers on
  -- completion, also deferred by the same gen match). Fails without the
  -- session/gen check: it unconditionally overwrites the tree with
  -- Delete's diff (`D d.txt`) even though the selection still correctly
  -- points at C1.
  for _ = 1, 10 do
    child.lua([[
      while #_G.__deferred > 0 do
        local fn = table.remove(_G.__deferred, 1)
        fn()
      end
    ]])
    child.lua('vim.wait(300, function() return #_G.__deferred > 0 end)')
  end

  MiniTest.expect.equality(buf_lines(w.tree), { 'M f.txt' .. (' '):rep(27) .. '+1 -1' })
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current().sel'), { top = 8, bottom = 8 })

  child.cmd('Diffy close')
end

return T
