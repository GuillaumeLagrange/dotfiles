-- §9.4, §12.7 (phase 7B): the GitHub backend's write side through the UI -
-- push (client-side validation before any API call, primary-commit/
-- other-commit routing, multi-line tracking to HEAD), pull (restoring
-- drafts to their original commit/line from a pending review), reply,
-- resolve/unresolve, submit (contract §11.4). A real git bundle of the
-- sandbox's `pending` PR history (exact shas) in both modes. Default: fake
-- `gh` transport. `make test-gh` (DIFFY_TESTGH=1): the real transport against
-- a fresh PR per case, pre-existing state created through the real API.
local leak = require('tests.helpers.leak')
local live = require('tests.helpers.github_live')
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

local function pr_number()
  return live.enabled and live.current.number or 4
end

--- The recorded PR #4 state in the fake; live, the same shapes created on
--- the fresh PR: D1 (published, head R30), D2 (published, resolved, head
--- R20), and a pending review with E1 on Q1 R5-7 and E3 written through the
--- legacy position API on Q2 R20.
local function setup_pending()
  if not live.enabled then
    child.lua(([[
      local fake = require('tests.helpers.fake_github')
      local state = fake.load_fixture(%q, 4)
      state.repo_dir = %q
      state.merge_base = %q
      state.viewer = 'GuillaumeLagrange'
      state.find_pr = { ['sandbox/pending'] = { number = 4, baseRefName = %q, headRefOid = %q } }
      _G.__fake_state = state
      require('diffy.review.github').transport = fake.new(state).transport
    ]]):format(PR4_FIXTURE, dir, MERGE_BASE, BASE, HEAD_SHA))
    return
  end
  local pr = live.current
  local add_review = [[mutation($pr:ID!,$c:GitObjectID!,$t:[DraftPullRequestReviewThread],$e:PullRequestReviewEvent){
    addPullRequestReview(input:{pullRequestId:$pr,commitOID:$c,threads:$t,event:$e}){pullRequestReview{id}}}]]
  live.graphql(add_review, {
    pr = pr.id,
    c = HEAD_SHA,
    e = 'COMMENT',
    t = {
      { path = 'f.txt', line = 30, side = 'RIGHT', body = 'D1 published thread' },
      { path = 'f.txt', line = 20, side = 'RIGHT', body = 'D2 published thread, resolved' },
    },
  })
  local owner, name = live.REPO:match('(.+)/(.+)')
  local threads = live.graphql(
    'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:10){nodes{id comments(first:1){nodes{body}}}}}}}',
    { o = owner, r = name, n = pr.number }
  ).repository.pullRequest.reviewThreads.nodes
  for _, t in ipairs(threads) do
    if t.comments.nodes[1].body:find('^D2') then
      live.graphql('mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}', { t = t.id })
    end
  end
  local review = live.graphql(add_review, {
    pr = pr.id,
    c = Q1,
    t = { { path = 'f.txt', startLine = 5, line = 7, side = 'RIGHT', startSide = 'RIGHT', body = 'E1 pending on Q1 R5-7' } },
  }).addPullRequestReview.pullRequestReview.id
  live.graphql(
    [[mutation($r:ID!,$c:GitObjectID!,$p:Int!,$b:String!){
      addPullRequestReviewComment(input:{pullRequestReviewId:$r,commitOID:$c,path:"f.txt",position:$p,body:$b}){comment{id}}}]],
    { r = review, c = Q2, p = live.position(dir, MERGE_BASE, Q2, 'f.txt', 20), b = 'E3 pending on Q2 R20 (legacy position)' }
  )
end

--- An empty PR (no threads, no pending review) - for the push scenarios,
--- so pushed drafts are the *only* content. Live: the fresh PR as is.
local function setup_empty()
  if live.enabled then
    return
  end
  child.lua(([[
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
    _G.__fake_state = state
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(dir, MERGE_BASE, BASE, HEAD_SHA, BASE, HEAD_SHA))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      dir = clone_pending()
      if live.enabled then
        live.open_pr(dir, MERGE_BASE, HEAD_SHA)
      end
      child.fn.chdir(dir)
    end,
    post_case = function()
      if live.enabled then
        live.close()
      end
      leak.check(child, snapshot)
      if dir then
        vim.fn.delete(dir, 'rf')
      end
    end,
  },
})

local function wins()
  return ui.wins(child)
end

local function open_pr()
  ui.arm_ready(child, 'render')
  child.cmd('Diffy pr')
  ui.wait_ready(child, live.timeout)
end

--- Focus the tree, put the cursor on `path`'s row and press `<CR>`.
local function open_file(path)
  local w = wins()
  child.api.nvim_set_current_win(w.tree)
  for i, row in ipairs(ui.panel(child, 'tree')) do
    if row.text:find(path, 1, true) then
      child.api.nvim_win_set_cursor(w.tree, { i, 0 })
      break
    end
  end
  ui.arm_ready(child, 'review')
  child.type_keys('<CR>')
  ui.wait_ready(child, live.timeout)
end

--- Select log entry `idx` (1-based, newest first) as a single commit.
local function select_commit(idx)
  local w = wins()
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, ('call cursor(%d, 1)'):format(idx))
  child.type_keys('<CR>')
  ui.wait_ready(child, live.timeout)
end

local function select_all()
  local w = wins()
  child.api.nvim_set_current_win(w.log)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(w.log, 'call cursor(1, 1)')
  child.type_keys('a')
  ui.wait_ready(child, live.timeout)
end

-- Opening a float (`gc`/`K`+`r`) leaves the child transiently `blocking`
-- (AGENTS.md): arm/wait through raw `child.api` calls there.
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

local function wait_ready_raw()
  ui.wait_ready_raw(child, live.timeout)
end

--- GitHub's state of the PR's reviews: `{ pending = bool, submitted =
--- { { state, body }, … } }` (the fake's recorded db, or the live API).
local function remote_reviews()
  if live.enabled then
    local owner, name = live.REPO:match('(.+)/(.+)')
    local pr = live.graphql(
      'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviews(last:50){nodes{state body}}}}}',
      { o = owner, r = name, n = pr_number() }
    ).repository.pullRequest
    local out = { pending = false, submitted = {} }
    for _, r in ipairs(pr.reviews.nodes) do
      if r.state == 'PENDING' then
        out.pending = true
      else
        table.insert(out.submitted, { state = r.state, body = r.body })
      end
    end
    return out
  end
  return child.api.nvim_exec_lua(
    [[
    local db = (_G.__fake_state._db or {})[4] or { pending = {}, reviews = {} }
    local out = { pending = next(db.pending) ~= nil, submitted = {} }
    for _, r in ipairs(db.reviews) do
      table.insert(out.submitted, { state = r.state, body = r.body })
    end
    return out
  ]],
    {}
  )
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
  ui.wait_ready(child, live.timeout)
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
  -- §9.4, §12.7
  setup_empty()
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
  local path = dir .. '/.git/diffy/' .. branch .. '/pr-' .. pr_number() .. '.json'
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
  -- §9.4, §12.7
  setup_empty()
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
  local draft_path = dir .. '/.git/diffy/' .. branch .. '/pr-' .. pr_number() .. '.json'
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
  -- §9.4
  setup_empty()
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
  local draft_path = dir .. '/.git/diffy/' .. branch .. '/pr-' .. pr_number() .. '.json'
  if vim.fn.filereadable(draft_path) == 1 then
    local text = table.concat(vim.fn.readfile(draft_path), '\n')
    MiniTest.expect.equality(text:find('follow-up', 1, true), nil)
  end

  child.cmd('Diffy close')
end

T['§9.4/§12.7: pull restores a pending comment (eagerly remapped for display) at its original commit and line'] = function()
  -- §9.4, §12.7
  setup_pending()
  open_pr()
  open_file('f.txt')

  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child, live.timeout)

  local branch = ui.git(dir, { 'rev-parse', '--abbrev-ref', 'HEAD' })
  local path = dir .. '/.git/diffy/' .. branch .. '/pr-' .. pr_number() .. '.json'
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
  -- §9.4, §12.7
  setup_pending()
  open_pr()
  open_file('f.txt')

  -- pull first (contract's own safety net): recreating the pending review
  -- on push/submit must not silently drop the pre-existing E1/E2/E3/E4
  ui.arm_ready(child, 'review')
  child.cmd('Diffy review pull')
  ui.wait_ready(child, live.timeout)

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
  MiniTest.expect.equality(d1_line:find('[resolved]', 1, true) ~= nil, true)
  MiniTest.expect.equality(d2_line ~= nil, true)
  MiniTest.expect.equality(d2_line:find('[resolved]', 1, true), nil)

  arm_ready_raw('compose')
  child.cmd('Diffy review submit comment')
  wait_ready_raw()
  child.type_keys('looks good', '<Esc>')
  child.type_keys('<C-s>')
  -- push+submit consumes the pending review on GitHub (§9.4)
  local function submitted()
    local r = remote_reviews()
    if r.pending then
      return false
    end
    for _, s in ipairs(r.submitted) do
      if s.body == 'looks good' then
        return true
      end
    end
    return false
  end
  MiniTest.expect.equality(vim.wait(live.timeout, submitted, live.enabled and 1000 or 10), true)

  child.cmd('Diffy close')
end

return T
