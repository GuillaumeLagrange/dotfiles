-- §3, §4, §12.2 (phase 2): the log model for `:Diffy branch`, merge
-- dimming/navigation-skip, and the collapse-on-blur behaviour.
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

  -- rendered dimmed: focus the log so the full list (not the collapsed
  -- summary) is on screen, then check the merge line's highlight group.
  child.api.nvim_set_current_win(wins().tree)
  child.type_keys('<C-w>j')
  local merge_hl = child.lua_get([[(function()
    local s = require('diffy.session').current()
    local merge_line
    for i, e in ipairs(s.entries) do
      if e.kind == 'commit' and e.merge then merge_line = i end
    end
    local marks = vim.api.nvim_buf_get_extmarks(s.bufs.log, s.ns.log_render, {merge_line - 1, 0}, {merge_line - 1, -1}, {details = true})
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == 'Comment' then return true end
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

T['§2: the log collapses to a summary when unfocused and expands on focus'] = function()
  open_branch()
  local w = wins()

  local collapsed_height = child.lua_get(('vim.api.nvim_win_get_height(%d)'):format(w.log))
  local collapsed_lines = child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(w.log))
  MiniTest.expect.equality(collapsed_height, 1)
  MiniTest.expect.equality(#collapsed_lines, 1)
  MiniTest.expect.equality(collapsed_lines[1]:find('commit', 1, true) ~= nil, true)

  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  local expanded_height = child.lua_get(('vim.api.nvim_win_get_height(%d)'):format(w.log))
  local expanded_lines = child.lua_get(('vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(%d), 0, -1, false)'):format(w.log))
  MiniTest.expect.equality(expanded_height > 1, true)
  MiniTest.expect.equality(#expanded_lines, #subjects())

  child.type_keys('<C-w>k')
  local reblurred_height = child.lua_get(('vim.api.nvim_win_get_height(%d)'):format(w.log))
  MiniTest.expect.equality(reblurred_height, 1)

  child.cmd('Diffy close')
end

return T
