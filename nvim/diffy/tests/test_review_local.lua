-- §9.2, §9.3, §12.6 (phase 6): the review layer's UI and local backend -
-- compose/sign/summary/alignment, persistence across restarts, excerpt
-- relocation on edit/delete, review.md export, and namespace scoping.
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
      -- neutralize the machine's own git config so the local backend's
      -- author lookup (`git config user.name`) can't make a test's outcome
      -- depend on it (contract §11.3: no dependence on the user's config).
      child.lua([[vim.env.GIT_CONFIG_GLOBAL = '/dev/null'; vim.env.GIT_CONFIG_NOSYSTEM = '1']])
      repo = Repo.new()
      repo:commit('base', { ['f.txt'] = Repo.lines(30) })
      -- an uncommitted worktree edit, so the default `Unstaged` selection
      -- has a real file to show (§12.2's screenshot test does the same).
      vim.fn.writefile(Repo.edit(3, 'uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')
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

local function open_default()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy')
  ui.wait_ready(child)
end

-- Opening/closing `gc`'s compose float leaves the child transiently
-- `blocking` (AGENTS.md harness facts), so arm DiffyReady through raw
-- `child.api` calls; pair with `ui.wait_ready_raw`.
local function arm_ready_raw(event)
  child.api.nvim_exec_lua(([[
    _G.__diffy_ready = false
    _G.__diffy_ready_au = vim.api.nvim_create_autocmd('User', {
      pattern = 'DiffyReady',
      callback = function(a)
        if a.data and a.data.event == %q then
          _G.__diffy_ready = true
        end
      end,
    })
  ]]):format(event), {})
end

--- `gc` on line `lnum` of `win`, type `body`, then `<C-s>` to save the draft.
--- Syncs on the `compose`/`review` `DiffyReady` events (`review/ui.lua`).
local function write_comment(win, lnum, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  arm_ready_raw('compose')
  child.type_keys('gc')
  ui.wait_ready_raw(child)
  child.type_keys(body, '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  ui.wait_ready_raw(child)
end

T['§9.2: gc + <C-s> shows a sign and summary, mirrored as blank lines on the other side, staying aligned'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'needs a null check')

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(#visible, 1)
  MiniTest.expect.equality(visible[1].line, 5)
  MiniTest.expect.equality(visible[1].summary:find('\240\159\146\172', 1, true), 1)
  -- the summary is author/count/resolved-state only, not the body text
  MiniTest.expect.equality(visible[1].summary:find('null check', 1, true), nil)

  -- the left window got a matching blank virt_lines block at the
  -- counterpart line, so cursorbind/scrollbind alignment still holds
  child.api.nvim_set_current_win(w.right)
  child.fn.win_execute(w.right, 'call cursor(10, 1)')
  MiniTest.expect.equality(ui.aligned(child), true)

  child.cmd('Diffy close')
end

T['§9.3: drafts survive restarting nvim'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'first draft')
  child.cmd('Diffy close')

  child.restart({ '-u', 'tests/minimal_init.lua' })
  child.lua([[vim.env.GIT_CONFIG_GLOBAL = '/dev/null'; vim.env.GIT_CONFIG_NOSYSTEM = '1']])
  child.fn.chdir(repo.dir)
  open_default()

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(#visible, 1)
  MiniTest.expect.equality(visible[1].line, 5)

  child.cmd('Diffy close')
end

T['§9.1: editing lines above an anchor moves it with its excerpt'] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 20, 'about line 20')

  -- insert two lines above the anchor through the buffer itself (a real
  -- edit, not a behind-nvim's-back disk write - the already-loaded
  -- worktree buffer wouldn't see that), then refresh: the comment's
  -- excerpt should still be found, shifted down
  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 0, 0, false, { 'inserted a', 'inserted b' })
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)

  local visible = ui.threads_visible(child, 'right')
  MiniTest.expect.equality(#visible, 1)
  MiniTest.expect.equality(visible[1].line, 22)

  child.cmd('Diffy close')
end

T["§9.1: deleting an anchor's lines detaches it and lists it in :Diffy threads"] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 20, 'about line 20')

  child.api.nvim_buf_set_lines(child.api.nvim_win_get_buf(w.right), 19, 20, false, {})
  ui.arm_ready(child, 'render')
  child.type_keys('R')
  ui.wait_ready(child)

  MiniTest.expect.equality(#ui.threads_visible(child, 'right'), 0)

  child.cmd('Diffy threads')
  local qf_text = child.lua_get('vim.tbl_map(function(e) return e.text end, vim.fn.getqflist())')
  MiniTest.expect.equality(#qf_text, 1)
  MiniTest.expect.equality(qf_text[1]:find('detached', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['§9.3: review export writes review.md for worktree, index and commit views, marks sent, prompt in +'] = function()
  repo:commit('second', { ['f.txt'] = Repo.edit(15, 'second: line 15') })
  -- an uncommitted worktree edit so the default Unstaged selection has a
  -- real diff to comment on
  vim.fn.writefile(Repo.edit(3, 'second uncommitted')(vim.fn.readfile(repo.dir .. '/f.txt')), repo.dir .. '/f.txt')

  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 3, 'worktree comment')

  -- stage the uncommitted edit directly (not through diffy's own staging
  -- UI, which is a sibling phase): select `Staged` via the log panel
  -- (phase 2, already stable) and comment there
  ui.git(repo.dir, { 'add', '-A' })
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(2, 1)')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  write_comment(w.right, 3, 'staged comment')

  -- select the tip commit alone: right is real only if the tree is clean,
  -- which it isn't (a staged edit exists), so this is a genuine blob view
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(3, 1)')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  write_comment(w.right, 15, 'commit comment')

  -- back to `Unstaged` before exporting, so the header's range label is
  -- predictable for the assertion below
  child.api.nvim_set_current_win(w.tree)
  child.type_keys('<C-w>j')
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(1, 1)')
  child.type_keys('<CR>')
  ui.wait_ready(child)

  local branch = ui.git(repo.dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })

  ui.arm_ready(child, 'review')
  child.cmd('Diffy review export')
  ui.wait_ready(child)

  local review_md = repo.dir .. '/.git/diffy/' .. branch .. '/review.md'
  MiniTest.expect.equality(vim.fn.filereadable(review_md), 1)
  local text = table.concat(vim.fn.readfile(review_md), '\n')
  -- raw bytes, not `readfile()` (which quietly swaps NUL back to NL,
  -- masking a real regression: `writefile()` turns an embedded `\n`
  -- *within* one list entry into a NUL byte rather than a real line
  -- break - review.md is read by other tools as plain bytes, not through
  -- vim, so this must hold on disk, not just after round-tripping back)
  local raw = io.open(review_md, 'rb'):read('*a')
  MiniTest.expect.equality(raw:find('\0', 1, true), nil)

  MiniTest.expect.equality(text:find('# Review of ' .. branch, 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('worktree comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('staged comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('```diff', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('<details>', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit worktree', 1, true) ~= nil, true)
  MiniTest.expect.equality(text:find('commit index', 1, true) ~= nil, true)
  -- the header's range label uses the same commit-field vocabulary
  -- (worktree/index/sha) as the per-comment `commit` field, not a blind
  -- 7-char sha truncation that would mangle "worktree" into "worktre"
  MiniTest.expect.equality(text:find('range: index..worktree', 1, true) ~= nil, true)

  local reg = child.fn.getreg('+')
  MiniTest.expect.equality(reg:find(review_md, 1, true) ~= nil, true)

  -- exported comments are `sent`: the next export carries only newer ones
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(2, 1)')
  child.type_keys('<CR>')
  ui.wait_ready(child)
  write_comment(w.right, 5, 'later comment')
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review export')
  ui.wait_ready(child)
  local again = table.concat(vim.fn.readfile(review_md), '\n')
  MiniTest.expect.equality(again:find('later comment', 1, true) ~= nil, true)
  MiniTest.expect.equality(again:find('worktree comment', 1, true), nil)

  child.cmd('Diffy close')
end

T["§9.2: comment decorations don't show in a window outside the session showing the same file"] = function()
  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'a comment')
  MiniTest.expect.equality(#ui.threads_visible(child, 'right'), 1)

  -- open the same worktree file in a plain tab: the review namespace is
  -- scoped to the diffy session's own windows (`nvim__ns_set`), so nothing
  -- from it should be visible on screen here, even though it's the same
  -- buffer.
  child.cmd('tabnew ' .. vim.fn.fnameescape(repo.dir .. '/f.txt'))
  local rows = vim.tbl_map(function(row) return table.concat(row) end, child.get_screenshot().text)
  local screen = table.concat(rows, '\n')
  MiniTest.expect.equality(screen:find('\240\159\146\172', 1, true), nil)

  child.cmd('tabclose')
  child.cmd('Diffy close')
end

T['§9.2 screenshot: gc + <C-s> shows sign, summary and mirrored blank lines'] = function()
  child.o.lines, child.o.columns = 24, 80
  -- a fixed path (not `vim.fn.tempname()`'s random one): the screenshot
  -- embeds the worktree's absolute path, which must be stable to diff
  -- against a committed reference.
  local fixed_dir = '/tmp/diffy-review-screenshot-fixture'
  vim.fn.delete(fixed_dir, 'rf')
  vim.fn.rename(repo.dir, fixed_dir)
  repo.dir = fixed_dir
  child.fn.chdir(repo.dir)

  open_default()
  local w = ui.wins(child)
  write_comment(w.right, 5, 'needs a null check')
  MiniTest.expect.reference_screenshot(child.get_screenshot())

  child.cmd('Diffy close')
end

T['§9.2: gc on the empty-diff placeholder opens no composer and exports nothing'] = function()
  -- §9.2, §9.3
  ui.git(repo.dir, { 'checkout', '--', 'f.txt' })
  open_default()
  local w = ui.wins(child)
  MiniTest.expect.equality(ui.layout(child).right.path, nil)

  child.api.nvim_set_current_win(w.right)
  child.lua('_G.__warned = false; vim.notify = function(_, l) if l == vim.log.levels.WARN then _G.__warned = true end end')
  child.type_keys('gc')
  vim.wait(2000, function() return child.api.nvim_exec_lua('return _G.__warned', {}) end, 10)
  -- whatever gc opened, try to save a draft from it
  child.type_keys('Aorphan', '<Esc>', '<C-s>', '<Esc>')
  local floats = child.lua_get([[#vim.tbl_filter(function(x)
    return vim.api.nvim_win_get_config(x).relative ~= '' end, vim.api.nvim_list_wins())]])
  MiniTest.expect.equality(floats, 0)
  MiniTest.expect.equality(ui.threads_visible(child, 'right'), {})

  child.cmd('Diffy review export')
  local mds = vim.fn.glob(repo.dir .. '/.git/diffy/*/review.md', false, true)
  for _, p in ipairs(mds) do
    MiniTest.expect.equality(table.concat(vim.fn.readfile(p), '\n'):find('f.txt', 1, true), nil)
  end
  child.cmd('Diffy close')
end

return T
