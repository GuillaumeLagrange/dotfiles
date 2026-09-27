-- §9.4, §12.7 (phase 7A): the GitHub backend's read side through `:Diffy
-- pr` - placement tracked across commits (outdated/hidden/tracked-to-head),
-- opening the fold around a thread placed on an unchanged line, and the
-- readiness refusal (dirty tree / HEAD != PR head).
--
-- Fixture repo: a `git bundle` of the real sandbox PRs #2's `base/placement`
-- and `sandbox/placement` branches (`tests/fixtures/github/placement.bundle`,
-- fetched read-only from `GuillaumeLagrange/diffy-tests`, never rebuilt/
-- pushed from here) gives commits with the *exact* shas the recorded
-- GraphQL fixture (`tests/fixtures/github/pr2.json`, saved verbatim from
-- `gh api graphql --input -` against the real PR #2) refers to - this is
-- what keeps the placement test deterministic and fully offline (§11.1)
-- while still exercising real line-tracking `git diff` calls against real
-- history, not a hand-rolled approximation of it. The GitHub *transport*
-- (`review/github.lua`'s `M.transport`) is the only thing faked
-- (`tests/helpers/fake_github.lua`, contract §11.4) - git and nvim are real.
-- `make test-gh`: only the refusal cases run live (fresh PR per case).
local leak = require('tests.helpers.leak')
local live = require('tests.helpers.github_live')
local ui = require('tests.helpers.ui')

local child = MiniTest.new_child_neovim()
local snapshot
local dir

local BUNDLE = vim.fn.getcwd() .. '/tests/fixtures/github/placement.bundle'
local PR2_FIXTURE = vim.fn.getcwd() .. '/tests/fixtures/github/pr2.json'
local HEAD_SHA = '865a58547f2547547f78345248fca0a6d03ebaf6' -- P7, sandbox/placement's tip
local BASE = 'base/placement'

local function git(cwd, args)
  local res = vim.system(vim.list_extend({ 'git' }, args), { cwd = cwd, text = true }):wait()
  assert(res.code == 0, table.concat(args, ' ') .. '\n' .. (res.stderr or ''))
  return vim.trim(res.stdout or '')
end

--- A fresh clone of the sandbox's real placement history (exact shas,
--- offline) with a plausible `origin` remote (never fetched from - only its
--- URL is parsed, for `owner/repo`) and `sandbox/placement` checked out.
local function clone_placement()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, 'p')
  git(d, { 'init', '-q', '-b', 'main' })
  git(d, { 'config', 'user.name', 'diffy' })
  git(d, { 'config', 'user.email', 'diffy@example.com' })
  git(d, { 'remote', 'add', 'origin', 'https://github.com/GuillaumeLagrange/diffy-tests.git' })
  git(d, {
    'fetch',
    '-q',
    BUNDLE,
    'refs/remotes/origin/base/placement:refs/heads/base/placement',
    'refs/remotes/origin/sandbox/placement:refs/heads/sandbox/placement',
  })
  git(d, { 'checkout', '-q', 'sandbox/placement' })
  return d
end

--- Swap `review/github.lua`'s transport for the fake (contract §11.4),
--- loaded with the real PR #2 read fixture and a `find_pr` entry matching
--- `sandbox/placement`.
local function install_fake(c)
  c.lua(([[
    local fake = require('tests.helpers.fake_github')
    local state = fake.load_fixture(%q, 2)
    state.find_pr = { ['sandbox/placement'] = { number = 2, baseRefName = %q, headRefOid = %q } }
    _G.__fake_state = state
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(PR2_FIXTURE, BASE, HEAD_SHA))
end

--- Adds a published thread on head `line` of f.txt to the fake PR #2
--- (before `:Diffy pr` reads it).
local function serve_thread_at(line)
  child.lua(([[
    local pr = _G.__fake_state.reads[2].repository.pullRequest
    local head = %q
    table.insert(pr.reviewThreads.nodes, {
      id = 'PRRT_far', isResolved = false, path = 'f.txt', diffSide = 'RIGHT',
      line = %d, originalLine = %d,
      comments = { nodes = { {
        id = 'PRRC_far', author = { login = 'x' }, body = 'far from any change',
        createdAt = '2026-09-27T07:00:00Z', line = %d, originalLine = %d,
        commit = { oid = head }, originalCommit = { oid = head },
      } } },
    })
  ]]):format(HEAD_SHA, line, line, line, line))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ '-u', 'tests/minimal_init.lua' })
      snapshot = leak.snapshot(child)
      dir = clone_placement()
      child.fn.chdir(dir)
      if live.enabled then
        live.open_pr(dir, git(dir, { 'rev-parse', BASE }), HEAD_SHA)
      else
        install_fake(child)
      end
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
  ui.wait_ready(child)
end

local function lines_with_signs(side)
  local out = {}
  for _, t in ipairs(ui.threads_visible(child, side)) do
    out[t.line] = true
  end
  return out
end

T['§9.4: placement tracks a thread across commits (shown at head/its own view) and hides+outdates one whose line later changed'] = function()
  -- §9.4. Live: PR #2's between-pushes state can't be recreated; recorded fixtures cover it (§11.4).
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  open_pr()
  open_file('f.txt')

  -- P1 (entries index 7, oldest of the 7 PR commits): both B1 (R10) and
  -- B2 (R11) were written here, at their own line
  select_commit(7)
  local at_p1 = lines_with_signs('right')
  MiniTest.expect.equality(at_p1[10], true)
  MiniTest.expect.equality(at_p1[11], true)

  -- P2 (index 6): P2 re-edited line 11, so B1 (unaffected line 10) is
  -- still tracked and visible; B2 is hidden (contract §9.4: "both
  -- endpoints... mappable, in either direction" - B2's single line isn't)
  select_commit(6)
  local at_p2 = lines_with_signs('right')
  MiniTest.expect.equality(at_p2[10], true)
  MiniTest.expect.equality(at_p2[11], nil)

  -- head (default "all" selection): B1 tracked through P6's +3 top insert
  -- to R13; B2 stays hidden (it can't be tracked to HEAD either - outdated)
  ui.arm_ready(child, 'select')
  child.fn.win_execute(wins().log, 'call cursor(1, 1)')
  child.type_keys('a') -- select-all, the default full-PR view
  ui.wait_ready(child)
  local at_head = lines_with_signs('right')
  MiniTest.expect.equality(at_head[13], true)
  MiniTest.expect.equality(at_head[11], nil)
  MiniTest.expect.equality(at_head[10], nil)

  -- `:Diffy threads`: B2 (outdated, §9.1) lists only its own P1 view, never `head`
  child.cmd('Diffy threads')
  local qf = child.lua_get('vim.tbl_map(function(e) return e.text end, vim.fn.getqflist())')
  local b2_line
  for _, text in ipairs(qf) do
    if text:find(': B2 ', 1, true) then
      b2_line = text
    end
  end
  MiniTest.expect.equality(b2_line ~= nil, true)
  MiniTest.expect.equality(b2_line:find('head', 1, true), nil)
  MiniTest.expect.equality(b2_line:find('786410a', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['§9.4: a thread placed on a line unchanged in the viewed commit opens the fold around it'] = function()
  -- §9.4
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  -- f.txt's head changes cluster around 10-18/50-53/70/90; line 30 sits in
  -- a closed fold between them, far from PR #2's recorded threads
  serve_thread_at(30)
  open_pr()
  open_file('f.txt')

  local closed = child.lua_get(([[
    vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(30) end)
  ]]):format(wins().right))
  MiniTest.expect.equality(closed, -1)

  child.cmd('Diffy close')
end

local function expect_refused()
  vim.wait(live.timeout, function()
    return child.lua_get('_G.__warned') == true
  end, 10)
  MiniTest.expect.equality(child.lua_get('_G.__warned'), true)
  MiniTest.expect.equality(child.fn.tabpagenr('$'), 1)
  MiniTest.expect.equality(ui.diffy_buffers(child), {})
end

local function capture_warnings()
  child.lua([[_G.__warned = false; vim.notify = function(_, level) if level == vim.log.levels.WARN or level == vim.log.levels.ERROR then _G.__warned = true end end]])
end

T[':Diffy pr refuses to open when local HEAD differs from the PR head on GitHub'] = function()
  -- §9.4
  git(dir, { 'commit', '--amend', '-q', '--allow-empty', '-m', 'local-only amend' })
  capture_warnings()
  child.cmd('Diffy pr')
  expect_refused()
end

T[':Diffy pr refuses to open when the tree is dirty'] = function()
  -- §9.4
  vim.fn.writefile({ 'dirty' }, dir .. '/f.txt')
  capture_warnings()
  child.cmd('Diffy pr')
  expect_refused()
end

return T
