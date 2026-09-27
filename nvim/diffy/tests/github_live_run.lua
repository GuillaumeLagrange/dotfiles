-- `make test-gh` step 2: drive diffy against the *real* PR just opened,
-- through the real `gh` transport (no fake) - compose, push, pull, reply,
-- resolve/unresolve, submit. Env: DIFFY_TESTGH_WORK, DIFFY_TESTGH_PR.
local ok, err = pcall(function()
  local work = vim.env.DIFFY_TESTGH_WORK
  vim.fn.chdir(work .. '/repo')

  local session_mod = require('diffy.session')
  local init = require('diffy.init')
  local ui = require('diffy.review.ui')
  local gh = require('diffy.review.github')

  local function wait_for(pred, timeout, what)
    local done = vim.wait(timeout or 15000, pred, 100)
    if not done then
      error('timed out waiting for: ' .. what)
    end
  end

  init.dispatch.pr({})
  wait_for(function()
    return session_mod.current() ~= nil
  end, 10000, 'session to open')
  local s = session_mod.current()
  wait_for(function()
    return s.review ~= nil and s.review.pr ~= nil
  end, 15000, 'PR review to load')
  print('diffy: test-gh — PR loaded, ' .. #s.review.threads .. ' existing thread(s)')
  wait_for(function()
    return s.tree_rows ~= nil and #s.tree_rows > 0
  end, 15000, 'tree to render')
  require('diffy.panels.tree').open_path(s, 'f.txt')
  vim.wait(500)
  assert(s.current_path == 'f.txt', 'tree did not navigate to f.txt (stayed on ' .. tostring(s.current_path) .. ')')

  -- pick a definitely-valid line via a real diff instead of guessing, so
  -- this stays correct if the fixture ever changes
  local diff_res = vim.system({ 'git', 'diff', '-U0', '-M', s.review.merge_base, s.head_sha, '--', 'f.txt' }, { cwd = s.root, text = true }):wait()
  local new_line = tonumber(diff_res.stdout:match('%+(%d+)'))
  assert(new_line, 'could not determine a valid f.txt line from git diff:\n' .. tostring(diff_res.stdout) .. tostring(diff_res.stderr))

  local win = s.wins.right
  vim.api.nvim_set_current_win(win)
  vim.fn.win_execute(win, ('call cursor(%d, 1)'):format(new_line))
  ui.compose(s, 'n')
  vim.wait(300)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'diffy test-gh: smoke comment' })
  vim.cmd('write')
  vim.wait(500)
  assert(#s.review.threads >= 1, 'draft not composed')

  local push_ok, push_warnings
  gh.push(s, function(ok2, warnings)
    push_ok, push_warnings = ok2, warnings
  end)
  wait_for(function()
    return push_ok ~= nil
  end, 30000, 'push to finish')
  for _, w in ipairs(push_warnings or {}) do
    print('diffy: test-gh — push warning: ' .. w)
  end
  assert(push_ok, 'push failed')
  assert((#(push_warnings or {})) == 0, 'push produced unexpected warnings: ' .. vim.inspect(push_warnings))
  print('diffy: test-gh — pushed OK, pending review id: ' .. tostring(s.review.pr.pending and s.review.pr.pending.id))
  assert(s.review.pr.pending ~= nil, 'no pending review after push')

  -- pull round-trip: must not error, and must find our own draft persisted
  local pull_ok
  gh.pull(s, function(ok2)
    pull_ok = ok2 == nil and false or ok2
  end)
  wait_for(function()
    return pull_ok ~= nil
  end, 15000, 'pull to finish')

  -- find our thread by body prefix, resolve then unresolve it
  local target
  for _, t in ipairs(s.review.threads) do
    if t.comments[1] and t.comments[1].body:find('diffy test-gh', 1, true) then
      target = t
    end
  end
  assert(target ~= nil, 'pushed thread not found after refresh')

  local resolve_ok
  gh.resolve_thread(s, target, true, function(ok2)
    resolve_ok = ok2
  end)
  wait_for(function()
    return resolve_ok ~= nil
  end, 15000, 'resolve to finish')
  assert(resolve_ok, 'resolveReviewThread failed')
  assert(target.resolved == true, 'thread not marked resolved locally')

  local unresolve_ok
  gh.resolve_thread(s, target, false, function(ok2)
    unresolve_ok = ok2
  end)
  wait_for(function()
    return unresolve_ok ~= nil
  end, 15000, 'unresolve to finish')
  assert(unresolve_ok, 'unresolveReviewThread failed')

  -- reply to it
  local reply_saved = false
  ui.open_compose(s, win, target.anchor.end_line, function(body)
    table.insert(target.comments, {
      id = require('diffy.review.model').next_comment_id(s.review.threads),
      author = gh.author(s.root),
      body = table.concat(body, '\n'),
      created_at = os.time(),
      state = 'draft',
    })
    s.review.backend.save(s, s.review.branch, s.review.threads)
    reply_saved = true
  end)
  vim.wait(300)
  local rbuf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, { 'diffy test-gh: reply' })
  vim.cmd('write')
  wait_for(function()
    return reply_saved
  end, 5000, 'reply save')

  local submit_ok, submit_warnings
  gh.submit(s, 'COMMENT', 'diffy test-gh: automated smoke submit', function(ok2, warnings)
    submit_ok, submit_warnings = ok2, warnings
  end)
  wait_for(function()
    return submit_ok ~= nil
  end, 30000, 'submit to finish')
  for _, w in ipairs(submit_warnings or {}) do
    print('diffy: test-gh — submit warning: ' .. w)
  end
  assert(submit_ok, 'submit failed')
  assert(s.review.pr.pending == nil, 'pending review still present after submit')

  print('diffy: test-gh — all scenarios passed')
end)

if not ok then
  io.stderr:write('diffy: test-gh run failed: ' .. tostring(err) .. '\n')
  os.exit(1)
end
os.exit(0)
