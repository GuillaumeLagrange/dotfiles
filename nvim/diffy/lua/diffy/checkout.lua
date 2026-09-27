-- Full checkout of a single log commit onto the real worktree, so its right
-- side gets a real, LSP-navigable buffer. Writes a recovery state file before
-- touching HEAD and restores the original branch when the user leaves it
-- (selecting elsewhere, `X` again, closing the tab, exit).
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')

local M = {}

-- session.id -> { root, gitdir, branch }, mirroring the live `session.checkout`
-- fields for every session with an active full checkout. Kept independent of
-- `session.sessions` (which `session.teardown` may already have emptied by
-- the time `VimLeavePre` runs) so the exit handler below never depends on
-- autocmd registration order between this module and session.lua's reaper.
local active = {}

local function state_path(gitdir)
  return gitdir .. '/diffy/checkout.json'
end

local function write_state(gitdir, state)
  vim.fn.mkdir(gitdir .. '/diffy', 'p')
  vim.fn.writefile({ vim.json.encode(state) }, state_path(gitdir))
end

local function read_state(gitdir)
  local path = state_path(gitdir)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, vim.fn.readfile(path)[1] or '')
  if not ok or type(decoded) ~= 'table' then
    return nil
  end
  return decoded
end

local function delete_state(gitdir)
  vim.fn.delete(state_path(gitdir))
end

-- Check out `branch` and delete the state file on success; `cb(ok)` is optional.
local function checkout_branch(root, gitdir, branch, session, cb)
  run.git({ 'checkout', '--quiet', branch }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local ok = res.code == 0
      if ok then
        delete_state(gitdir)
      end
      if cb then
        cb(ok)
      end
    end,
  })
end

--- Whether an interrupted full checkout's state file exists for `gitdir`.
function M.pending(gitdir)
  return read_state(gitdir) ~= nil
end

local function current_branch(root, cb, session)
  run.git({ 'symbolic-ref', '--short', '-q', 'HEAD' }, {
    cwd = root,
    session = session,
    notify_on_error = false,
    on_exit = function(res)
      cb(res.code == 0 and vim.trim(res.stdout or '') or nil)
    end,
  })
end

local function render_tree(session)
  require('diffy.panels.tree').render(session, function()
    run.ready({ session = session.id, event = 'checkout' })
  end)
end

--- `X` on the single selected commit: check out its tree onto the real
--- worktree so its right side becomes a real file. Refuses if the
--- tree has tracked changes; HEAD is left untouched in that case.
function M.enter(session)
  local sel = session.sel
  local entry = sel and sel.top == sel.bottom and session.entries[sel.top]
  if not entry or entry.kind ~= 'commit' then
    vim.notify('diffy: `X` needs a single selected commit', vim.log.levels.WARN)
    return
  end

  repo.is_clean(session.root, nil, function(clean, err)
    if not clean then
      local why = clean == nil and ('git status failed: ' .. err) or 'commit or stash tracked changes first'
      vim.notify('diffy: cannot check out — ' .. why, vim.log.levels.ERROR)
      run.ready({ session = session.id, event = 'checkout' })
      return
    end
    current_branch(session.root, function(branch)
      local state = { branch = branch or session.head_sha, head = session.head_sha, commit = entry.sha }
      write_state(session.gitdir, state)
      run.git({ 'checkout', '--quiet', '--detach', entry.sha }, {
        cwd = session.root,
        session = session,
        on_exit = function(res)
          if res.code ~= 0 then
            delete_state(session.gitdir)
            run.ready({ session = session.id, event = 'checkout' })
            return
          end
          session.checkout = { branch = state.branch, head = state.head, commit = state.commit, sel_idx = sel.top }
          session.checkout_sha = entry.sha
          active[session.id] = { root = session.root, gitdir = session.gitdir, branch = state.branch }
          render_tree(session)
        end,
      })
    end, session)
  end, session)
end

--- Leave the checked-out commit (`X` again, moving the log selection away,
--- closing the tab): restore the saved branch and delete the state file.
--- `cb(ok)`; on `false` (tree became dirty since the checkout) HEAD stays on
--- the checked-out commit and nothing is deleted.
function M.leave(session, cb)
  if not session.checkout then
    cb(true)
    return
  end
  repo.is_clean(session.root, nil, function(clean, err)
    if not clean then
      local why = clean == nil and ('git status failed: ' .. err)
        or 'tracked changes present, commit or stash them first'
      vim.notify('diffy: cannot leave the checked-out commit — ' .. why, vim.log.levels.ERROR)
      cb(false)
      return
    end
    checkout_branch(session.root, session.gitdir, session.checkout.branch, session, function(ok)
      if not ok then
        cb(false)
        return
      end
      session.checkout = nil
      session.checkout_sha = nil
      active[session.id] = nil
      cb(true)
    end)
  end, session)
end

--- `X`: enter or leave the checkout of the currently selected commit.
function M.toggle(session)
  if session.checkout then
    M.leave(session, function(ok)
      if ok then
        render_tree(session)
      end
    end)
  else
    M.enter(session)
  end
end

--- Hook for `session.on_select` (init.lua): if a checkout is active and the
--- new selection is no longer that same single commit, leave it first.
--- `cb()` runs once it is safe to render the new selection; on refusal the
--- selection snaps back to the checked-out commit and `cb` is not called.
function M.before_select(session, cb)
  local co = session.checkout
  if not co then
    cb()
    return
  end
  local sel = session.sel
  if sel.top == sel.bottom and sel.top == co.sel_idx then
    cb()
    return
  end
  M.leave(session, function(ok)
    if ok then
      cb()
    else
      session.sel = { top = co.sel_idx, bottom = co.sel_idx }
      require('diffy.panels.log').render(session)
      run.ready({ session = session.id, event = 'select' })
    end
  end)
end

--- Best-effort restore when a session tears down with a checkout still
--- active via `:tabclose`/`:q`/a wiped panel buffer (not while nvim is
--- exiting; see the `VimLeavePre` handler below). The window/tab is already
--- gone, so there is nothing left to refuse into: a dirty tree just leaves
--- the state file for `:Diffy restore`, with a warning explaining why.
-- `session` is not passed to `repo.is_clean`/`run.git`: it is already
-- closed, which would turn their callbacks into no-ops.
function M.leave_on_teardown(session)
  if not session.checkout then
    return
  end
  local root, gitdir, co = session.root, session.gitdir, session.checkout
  repo.is_clean(root, nil, function(clean, err)
    if not clean then
      local why = clean == nil and ('git status failed: ' .. err) or 'tracked changes present'
      vim.notify(
        ('diffy: left commit %s checked out (%s) — clean the tree and run `:Diffy restore`'):format(co.commit:sub(1, 7), why),
        vim.log.levels.WARN
      )
      return
    end
    checkout_branch(root, gitdir, co.branch)
  end)
  active[session.id] = nil
end

-- nvim is exiting: `VimLeavePre` handlers have no later event-loop turn to
-- run an async callback in, so git runs synchronously here, including the
-- clean-tree check.
local function restore_sync(info)
  local status = vim.system({ 'git', 'status', '--porcelain=v2', '-z' }, { cwd = info.root, text = true }):wait()
  if status.code ~= 0 then
    return
  end
  for _, e in ipairs(parse.status_v2(status.stdout or '')) do
    if e.kind ~= 'untracked' and e.kind ~= 'ignored' then
      return -- dirty: leave the state file for `:Diffy restore`
    end
  end
  local checkout = vim.system({ 'git', 'checkout', '--quiet', info.branch }, { cwd = info.root }):wait()
  if checkout.code == 0 then
    delete_state(info.gitdir)
  end
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('diffy_checkout_reaper', { clear = true }),
  callback = function()
    for _, info in pairs(active) do
      restore_sync(info)
    end
  end,
})

--- `:Diffy restore`: recover from an interrupted full checkout for the repo
--- at the current cwd - reads the state file, checks out the saved branch,
--- and deletes it. Works with no diffy session open, since nvim may have
--- been killed since the checkout.
function M.restore(_args)
  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
      run.ready({ event = 'restore' })
      return
    end
    local gitdir = vim.fn.FugitiveExtractGitDir(root)
    local state = read_state(gitdir)
    if not state then
      vim.notify('diffy: nothing to restore', vim.log.levels.WARN)
      run.ready({ event = 'restore' })
      return
    end
    checkout_branch(root, gitdir, state.branch, nil, function(ok)
      if ok then
        vim.notify('diffy: restored branch ' .. state.branch, vim.log.levels.INFO)
      end
      run.ready({ event = 'restore' })
    end)
  end)
end

return M
