-- §9.4, §12.7 (phase 7B): the GitHub backend's write side through the UI -
-- push (client-side validation before any API call, primary-commit/
-- other-commit routing, multi-line tracking to HEAD), pull (restoring
-- drafts to their original commit/line from a pending review), reply,
-- resolve/unresolve, submit. Same strategy as `tests/test_github_read.lua`
-- (contract §11.4): a real git bundle of the sandbox's `pending` PR history
-- (exact shas the recorded fixture refers to) plus a fake `gh` transport -
-- only `gh` is faked, git and nvim are real.
local leak = require('tests.helpers.leak')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local dir

local PENDING_BUNDLE = vim.fn.getcwd() .. '/tests/fixtures/github/pending.bundle'
local PR4_FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/github/pr4.json'
local BASE = 'base/pending'
local MERGE_BASE = '00c9d496d93a587199db453b2f18d7c4e0c994e8' -- == base/pending's own tip
local Q1 = '624697d43fdafc6e982d28e5cc504dc58ffd78f3' -- f.txt L5-7
local Q2 = '555868b2a02f69191ea2a6f02ce7365285b02ce6' -- f.txt L20
local HEAD_SHA = '5a5dae9a718551dcddd9ecd66fb85ef6c43c6b28' -- Q3, sandbox/pending's tip, f.txt L30

local function git(cwd, args)
  local res = vim.system(vim.list_extend({ 'git' }, args), { cwd = cwd, text = true }):wait()
  assert(res.code == 0, table.concat(args, ' ') .. '\n' .. (res.stderr or ''))
  return vim.trim(res.stdout or '')
end

--- A fresh clone of the sandbox's real `pending` PR history (exact shas,
--- offline, read-only fetch from the bundle - never pushed to).
local function clone_pending()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  git(d, { 'init', '-q', '-b', 'main' })
  git(d, { 'config', 'user.name', 'diffy' })
  git(d, { 'config', 'user.email', 'diffy@example.com' })
  git(d, { 'remote', 'add', 'origin', 'https://github.com/GuillaumeLagrange/diffy-tests.git' })
  git(d, {
    'fetch',
    '-q',
    PENDING_BUNDLE,
    'refs/remotes/origin/base/pending:refs/heads/base/pending',
    'refs/remotes/origin/sandbox/pending:refs/heads/sandbox/pending',
  })
  git(d, { 'checkout', '-q', 'sandbox/pending' })
  return d
end

--- Swap in the fake with the *real* recorded PR #4 fixture (has published
--- threads D1/D2 and the owner's real pending review E1-E4) - for the
--- pull/reply/resolve/submit scenarios.
local function install_fake_pr4(c, d)
  c.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = fake.load_fixture(%q, 4)
    state.repo_dir = %q
    state.merge_base = %q
    state.viewer = 'GuillaumeLagrange'
    state.find_pr = { ['sandbox/pending'] = { number = 4, baseRefName = %q, headRefOid = %q } }
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(PR4_FIXTURE, d, MERGE_BASE, BASE, HEAD_SHA))
end

--- A synthetic, empty PR (no pre-existing threads/pending review) - for the
--- push scenarios, so pushed drafts are the *only* content and their
--- outcome is unambiguous.
local function install_fake_empty(c, d)
  c.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = {
      repo_dir = %q,
      merge_base = %q,
      reads = { [4] = { repository = { pullRequest = {
        id = 'PR_TEST', number = 4, title = 't', body = '',
        baseRefName = %q, headRefOid = %q, author = { login = 'x' },
        comments = { nodes = {} }, reviews = { nodes = {} },
        pendingReviews = { nodes = {} },
        reviewThreads = { pageInfo = { hasNextPage = false }, nodes = {} },
      } } } },
      find_pr = { ['sandbox/pending'] = { number = 4, baseRefName = %q, headRefOid = %q } },
    }
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(d, MERGE_BASE, BASE, HEAD_SHA, BASE, HEAD_SHA))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      dir = clone_pending()
      child.fn.chdir(dir)
    end,
    post_case = function()
      leak.check(child, snapshot)
      if dir then
        vim.fn.delete(dir, 'rf')
      end
    end,
  },
})

local function wins()
  return child.lua_get('require("diffy.session").current().wins')
end

local function open_pr()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy pr')
  ui.wait_ready(child)
end

local function open_file(path)
  ui.arm_ready(child, 'review')
  child.lua(([[
    local s = require('diffy.session').current()
    require('diffy.panels.tree').open_path(s, %q)
  ]]):format(path))
  ui.wait_ready(child)
end

--- Select log entry `idx` (1-based, newest first) as a single commit.
local function select_commit(idx)
  local w = wins()
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, ('call cursor(%d, 1)'):format(idx))
  child.type_keys('<CR>')
  ui.wait_ready(child)
end

local function select_all()
  local w = wins()
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(1, 1)')
  child.type_keys('a')
  ui.wait_ready(child)
end

-- Opening a float (`gc`/`K`+`r`) leaves the child transiently
-- `blocking=true` in a way that only clears once more real input arrives -
-- `ui.arm_ready`/`wait_ready` throw immediately while blocked (AGENTS.md);
-- reimplement the same wait with raw, guard-free `child.api.*` calls right
-- after such a keystroke (`tests/test_review_local.lua`'s own convention).
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

local function wait_ready_raw(timeout)
  local start = vim.loop.now()
  while vim.loop.now() - start < (timeout or 5000) do
    if child.api.nvim_exec_lua('return _G.__diffy_ready', {}) then
      break
    end
  end
  pcall(child.api.nvim_exec_lua, 'pcall(vim.api.nvim_del_autocmd, _G.__diffy_ready_au)', {})
end

local function compose_draft(win, lnum, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum))
  arm_ready_raw('compose')
  child.type_keys('gc')
  wait_ready_raw()
  child.type_keys(body, '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()
end

local function compose_draft_range(win, lnum1, lnum2, body)
  child.api.nvim_set_current_win(win)
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum1))
  child.type_keys('v')
  child.fn.win_execute(win, ('call cursor(%d, 1)'):format(lnum2))
  arm_ready_raw('compose')
  child.type_keys('gc')
  wait_ready_raw()
  child.type_keys(body, '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()
end

local function push()
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review push')
  ui.wait_ready(child)
end

local function lines_with_signs(side)
  local out = {}
  for _, t in ipairs(ui.threads_visible(child, side)) do
    out[t.line] = true
  end
  return out
end

local function quickfix_entries()
  child.cmd('Diffy threads')
  local qf = child.lua_get('vim.tbl_map(function(e) return {lnum = e.lnum, text = e.text} end, vim.fn.getqflist())')
  child.cmd('cclose')
  return qf
end

--- The single quickfix entry anchored at `lnum` (identifies a thread by
--- its anchor line, since the quickfix `text` carries the id/state/summary
--- - author/count, never the body - not the comment content itself).
local function quickfix_at(lnum)
  for _, e in ipairs(quickfix_entries()) do
    if e.lnum == lnum then
      return e.text
    end
  end
  return nil
end

T['§9.4/§12.7: push validates locally, sends nothing for an invalid draft (kept local with a warning), and pushes the rest'] = function()
  install_fake_empty(child, dir)
  open_pr()
  open_file('f.txt')

  local right = wins().right
  compose_draft(right, 30, 'valid: on the head hunk')
  compose_draft(right, 1, 'invalid: nowhere near a change')

  child.lua([[_G.__warn = nil; local n = vim.notify; vim.notify = function(msg, level) if level == vim.log.levels.WARN then _G.__warn = msg end; n(msg, level) end]])
  push()

  MiniTest.expect.equality(child.lua_get('_G.__warn') ~= vim.NIL, true)

  -- the valid one is now `pending` on GitHub (no longer just a local
  -- draft): still visible at its line after the push+refresh round-trip
  MiniTest.expect.equality(lines_with_signs('right')[30], true)

  -- the invalid one stayed local: persisted to disk, still `draft`
  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local path = dir .. '/.git/diffy/' .. branch .. '/pr-4.json'
  MiniTest.expect.equality(vim.fn.filereadable(path), 1)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  local found
  for _, t in ipairs(data.threads) do
    for _, c in ipairs(t.comments) do
      if c.body:find('invalid', 1, true) then
        found = c
      end
    end
  end
  MiniTest.expect.equality(found ~= nil, true)
  MiniTest.expect.equality(found.state, 'draft')

  child.cmd('Diffy close')
end

T['§9.4/§12.7: push with drafts on two commits lands each on its own commit; a multi-line draft on the second is tracked to HEAD'] = function()
  install_fake_empty(child, dir)
  open_pr()
  open_file('f.txt')

  -- log entries, newest first: head(Q3)=1, Q2=2, Q1=3
  select_commit(3)
  local q1_right = wins().right
  compose_draft(q1_right, 5, 'on Q1 line 5')
  compose_draft(q1_right, 7, 'on Q1 line 7')

  select_commit(2)
  local q2_right = wins().right
  compose_draft_range(q2_right, 18, 22, 'on Q2, multi-line 18-22')

  push()

  -- Q1's two single-line drafts: primary commit (most drafts), pushed via
  -- the batched `addPullRequestReview` call, visible at their own commit
  select_commit(3)
  local at_q1 = lines_with_signs('right')
  MiniTest.expect.equality(at_q1[5], true)
  MiniTest.expect.equality(at_q1[7], true)

  -- Q2's multi-line draft: "other commit", tracked to HEAD via
  -- `addPullRequestReviewThread` (unshifted - Q3's own edit is at L30)
  select_all()
  local at_head = lines_with_signs('right')
  MiniTest.expect.equality(at_head[5], true)
  MiniTest.expect.equality(at_head[7], true)
  MiniTest.expect.equality(at_head[22], true)

  -- the strongest signal that both drafts really left local storage and
  -- became real GitHub content (diffy's own cross-commit placement would
  -- show a still-local draft at these same lines/commits regardless of
  -- whether the push actually succeeded, so the two checks above alone
  -- don't prove it): nothing left in the local drafts file
  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local draft_path = dir .. '/.git/diffy/' .. branch .. '/pr-4.json'
  if vim.fn.filereadable(draft_path) == 1 then
    local text = table.concat(vim.fn.readfile(draft_path), '\n')
    MiniTest.expect.equality(text:find('multi-line 18-22', 1, true), nil)
    MiniTest.expect.equality(text:find('on Q1 line', 1, true), nil)
  end

  local q1_line = quickfix_at(5)
  local q2_line = quickfix_at(18)
  MiniTest.expect.equality(q1_line ~= nil, true)
  MiniTest.expect.equality(q1_line:find(Q1:sub(1, 7), 1, true) ~= nil, true)
  MiniTest.expect.equality(q2_line ~= nil, true)
  MiniTest.expect.equality(q2_line:find('head', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['§9.4: a reply drafted on a not-yet-pushed thread lands in that thread on push'] = function()
  install_fake_empty(child, dir)
  open_pr()
  open_file('f.txt')

  local right = wins().right
  compose_draft(right, 30, 'root comment')
  child.api.nvim_set_current_win(right)
  child.fn.win_execute(right, 'call cursor(30, 1)')
  child.type_keys('K')
  arm_ready_raw('compose')
  child.type_keys('r')
  wait_ready_raw()
  child.type_keys('follow-up', '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()

  push()

  -- one thread on GitHub holding both comments, nothing left as a local draft
  local at_30 = {}
  for _, e in ipairs(quickfix_entries()) do
    if e.lnum == 30 then
      table.insert(at_30, e.text)
    end
  end
  MiniTest.expect.equality(#at_30, 1)
  MiniTest.expect.equality(at_30[1]:find('+1', 1, true) ~= nil, true)
  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local draft_path = dir .. '/.git/diffy/' .. branch .. '/pr-4.json'
  if vim.fn.filereadable(draft_path) == 1 then
    local text = table.concat(vim.fn.readfile(draft_path), '\n')
    MiniTest.expect.equality(text:find('follow-up', 1, true), nil)
  end

  child.cmd('Diffy close')
end

T['§9.4/§12.7: pull restores a pending comment (eagerly remapped for display) at its original commit and line'] = function()
  install_fake_pr4(child, dir)
  open_pr()
  open_file('f.txt')

  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child)

  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local path = dir .. '/.git/diffy/' .. branch .. '/pr-4.json'
  MiniTest.expect.equality(vim.fn.filereadable(path), 1)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))

  -- E3 was written via the legacy position API against Q2 and eagerly
  -- remapped by GitHub to `commit = head` (AGENTS.md) - `pull` must restore
  -- its *original* commit/line (Q2, L20), not the live-tracked one
  local e3
  for _, t in ipairs(data.threads) do
    for _, c in ipairs(t.comments) do
      if c.body:find('E3', 1, true) then
        e3 = { thread = t, comment = c }
      end
    end
  end
  MiniTest.expect.equality(e3 ~= nil, true)
  MiniTest.expect.equality(e3.thread.anchor.commit, Q2)
  MiniTest.expect.equality(e3.thread.anchor.end_line, 20)
  MiniTest.expect.equality(e3.comment.state, 'draft')

  child.cmd('Diffy close')
end

T['§9.4/§12.7: reply, resolve/unresolve and submit'] = function()
  install_fake_pr4(child, dir)
  open_pr()
  open_file('f.txt')

  -- pull first (contract's own safety net): recreating the pending review
  -- on push/submit must not silently drop the pre-existing E1/E2/E3/E4
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child)

  local right = wins().right
  -- D1 (published, head R30) and D2 (published, resolved, head R20)
  child.api.nvim_set_current_win(right)
  child.fn.win_execute(right, 'call cursor(30, 1)')
  child.type_keys('K')
  arm_ready_raw('compose')
  child.type_keys('r')
  wait_ready_raw()
  child.type_keys('a reply from the test', '<Esc>')
  arm_ready_raw('review')
  child.type_keys('<C-s>')
  wait_ready_raw()

  MiniTest.expect.equality(lines_with_signs('right')[30], true)

  child.fn.win_execute(right, 'call cursor(30, 1)')
  child.type_keys('K')
  arm_ready_raw('review')
  child.type_keys('x')
  wait_ready_raw()

  child.fn.win_execute(right, 'call cursor(20, 1)')
  child.type_keys('K')
  arm_ready_raw('review')
  child.type_keys('x')
  wait_ready_raw()

  local d1_line = quickfix_at(30)
  local d2_line = quickfix_at(20)
  MiniTest.expect.equality(d1_line ~= nil, true)
  MiniTest.expect.equality(d1_line:find('resolved', 1, true) ~= nil, true)
  MiniTest.expect.equality(d2_line ~= nil, true)
  MiniTest.expect.equality(d2_line:find('resolved', 1, true), nil)

  arm_ready_raw('compose')
  child.cmd('Diffy review submit comment')
  wait_ready_raw()
  child.type_keys('looks good', '<Esc>')
  child.type_keys('<C-s>')
  -- `<C-s>` here chains push's own refresh+decorate (one `review` event)
  -- with submit's *own* mutation and refresh (another) - waiting for the
  -- first `review` event alone would catch push's, not submit's; poll the
  -- actual outcome (no pending review left) instead.
  local start = vim.loop.now()
  while vim.loop.now() - start < 5000 do
    if child.api.nvim_exec_lua('return require("diffy.session").current().review.pr.pending == nil', {}) then
      break
    end
  end

  -- submit consumed the pending review entirely (push+submit, contract
  -- §9.4): nothing left to pull afterwards
  child.lua([[_G.__notif = nil; vim.notify = function(msg) _G.__notif = msg end]])
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child)
  local msg = child.lua_get('_G.__notif')
  MiniTest.expect.equality(msg ~= vim.NIL, true)
  MiniTest.expect.equality(msg:find('no pending review', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

return T
