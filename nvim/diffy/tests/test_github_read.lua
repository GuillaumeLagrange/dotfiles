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
    require('diffy.review.github').transport = fake.new(state).transport
  ]]):format(PR2_FIXTURE, BASE, HEAD_SHA))
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
  return child.lua_get('require("diffy.session").current().wins')
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

--- Jump the tree/diff pair to `path` (already the current file after a
--- fresh open, since it's the tree's first row - explicit for clarity/
--- robustness across the two views this file uses).
local function open_file(path)
  ui.arm_ready(child, 'review')
  child.lua(([[
    local s = require('diffy.session').current()
    require('diffy.panels.tree').open_path(s, %q)
  ]]):format(path))
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
  -- Live: PR #2's between-pushes state can't be recreated; recorded fixtures cover it (§11.4).
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

  -- `:Diffy threads`: B2 is labelled outdated (contract §9.1's `outdated`
  -- field - this thread also happens to be resolved in the real PR #2
  -- data, so the quickfix `[state]` tag alone can't distinguish it; the
  -- "commits it's visible in" annotation can - not `head`, only its own
  -- P1 view, exactly what §9.4's outdated means: untrackable to HEAD)
  local b2_outdated = child.lua_get([[
    (function()
      for _, t in ipairs(require('diffy.session').current().review.threads) do
        if t.id == 'PRRT_kwDOUtQPis6mYNPI' then
          return t.outdated
        end
      end
    end)()
  ]])
  MiniTest.expect.equality(b2_outdated, true)

  child.cmd('Diffy threads')
  local qf = child.lua_get('vim.tbl_map(function(e) return e.text end, vim.fn.getqflist())')
  local b2_line
  for _, text in ipairs(qf) do
    if text:find('PRRT_kwDOUtQPis6mYNPI', 1, true) then
      b2_line = text
    end
  end
  MiniTest.expect.equality(b2_line ~= nil, true)
  MiniTest.expect.equality(b2_line:find('head', 1, true), nil)
  MiniTest.expect.equality(b2_line:find('786410a', 1, true) ~= nil, true)

  child.cmd('Diffy close')
end

T['§9.4: a thread placed on a line unchanged in the viewed commit opens the fold around it'] = function()
  -- Live: PR #2's between-pushes state can't be recreated; recorded fixtures cover it (§11.4).
  if live.enabled then
    MiniTest.skip('placement: recorded-fixture only')
  end
  -- A hand-built synthetic thread (not the recorded PR #2 ones): a comment
  -- far from every change, guaranteed to fall inside a closed diff fold at
  -- nvim's default foldlevel - the recorded PR #2 threads all sit close
  -- enough to a hunk (within the default 6-line diff context) that none
  -- reliably exercises a *closed* fold. `:Diffy pr` already defaults to
  -- the full-PR view (all 7 commits selected, §4).
  open_pr()
  open_file('f.txt')
  ui.arm_ready(child, 'review')
  -- f.txt's real changes cluster around lines 10-18/50-53/70/90-ish
  -- (head-tracked); line 30 sits untouched between two of those hunks
  child.lua([[
    local s = require('diffy.session').current()
    table.insert(s.review.threads, {
      id = 'synthetic', backend = 'github', resolved = false, outdated = false,
      comments = { { id = 'c', author = 'x', body = 'far from any change', created_at = 0, state = 'published' } },
      anchor = { path = 'f.txt', side = 'new', start_line = 30, end_line = 30, commit = s.head_sha },
      _has_source = true,
    })
    require('diffy.review.ui').decorate(s)
  ]])
  ui.wait_ready(child)

  local win = wins().right
  local closed = child.lua_get(([[
    vim.api.nvim_win_call(%d, function() return vim.fn.foldclosed(30) end)
  ]]):format(win))
  MiniTest.expect.equality(closed, -1)

  child.cmd('Diffy close')
end

T[':Diffy pr refuses when local HEAD differs from the PR head on GitHub'] = function()
  -- amend the checked-out commit locally: HEAD now differs from the
  -- fixture's declared `headRefOid`
  git(dir, { 'commit', '--amend', '-q', '--allow-empty', '-m', 'local-only amend' })
  child.lua([[_G.__notif = nil; vim.notify = function(msg) _G.__notif = msg end]])
  child.cmd('Diffy pr')
  vim.wait(live.timeout, function()
    return child.lua_get('_G.__notif') ~= vim.NIL
  end)
  local msg = child.lua_get('_G.__notif')
  MiniTest.expect.equality(msg:find('refused', 1, true) ~= nil, true)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current()') == vim.NIL, true)
end

T[':Diffy pr refuses when the tree is dirty'] = function()
  vim.fn.writefile({ 'dirty' }, dir .. '/f.txt')
  child.lua([[_G.__notif = nil; vim.notify = function(msg) _G.__notif = msg end]])
  child.cmd('Diffy pr')
  vim.wait(live.timeout, function()
    return child.lua_get('_G.__notif') ~= vim.NIL
  end)
  local msg = child.lua_get('_G.__notif')
  MiniTest.expect.equality(msg:find('refused', 1, true) ~= nil, true)
  MiniTest.expect.equality(msg:find('dirty', 1, true) ~= nil, true)
  MiniTest.expect.equality(child.lua_get('require("diffy.session").current()') == vim.NIL, true)
end

return T
