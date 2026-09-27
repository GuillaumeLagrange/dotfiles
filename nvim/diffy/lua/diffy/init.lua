-- setup(opts), config defaults, keymap table, and the `:Diffy` dispatcher.
local session = require('diffy.session')

local M = {}

M.config = {
  -- filled in progressively by later phases (staging, navigation, review, …).
  keymaps = {},
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

--- subcommand name -> function(args: string[]). Later phases add pr/file/
--- conflicts/restore/review/threads here; for now they just say so.
M.dispatch = {}

local NOT_YET = {}
for _, name in ipairs(NOT_YET) do
  M.dispatch[name] = function()
    vim.notify(('diffy: `%s` is not implemented yet'):format(name), vim.log.levels.WARN)
  end
end

--- `:Diffy threads [author=<name>] [state=<open|resolved|detached>]
--- [review=<id>]` (§9.2): quickfix list of every thread in the session.
function M.dispatch.threads(args)
  local s = session.current()
  if not s then
    vim.notify('diffy: no session in the current tab', vim.log.levels.WARN)
    return
  end
  require('diffy.review.ui').quickfix(s, args)
end

--- `:Diffy review export|clear` (§9.3, local backend) and
--- `push|pull|submit` (§9.4, GitHub backend).
function M.dispatch.review(args)
  local s = session.current()
  if not s then
    vim.notify('diffy: no session in the current tab', vim.log.levels.WARN)
    return
  end
  local ui = require('diffy.review.ui')
  local review = ui.ensure(s)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  local sub = args[1]
  if sub == 'export' then
    if type(review.backend.export) ~= 'function' then
      vim.notify(('diffy: `review export` isn\'t available for %s'):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    review.backend.export(s, function(ok, result)
      if ok then
        vim.notify('diffy: exported review to ' .. result)
      else
        vim.notify('diffy: ' .. result, vim.log.levels.WARN)
      end
      require('diffy.git.run').ready({ session = s.id, event = 'review' })
    end)
  elseif sub == 'clear' then
    if type(review.backend.clear) ~= 'function' then
      vim.notify(('diffy: `review clear` isn\'t available for %s'):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    review.backend.clear(s, review.branch)
    review.threads = {}
    ui.decorate(s)
    vim.notify('diffy: review cleared')
    require('diffy.git.run').ready({ session = s.id, event = 'review' })
  elseif sub == 'push' then
    if type(review.backend.push) ~= 'function' then
      vim.notify(('diffy: `review push` isn\'t available for %s'):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    review.backend.push(s, function(ok, warnings)
      for _, w in ipairs(warnings or {}) do
        vim.notify('diffy: ' .. w, vim.log.levels.WARN)
      end
      if ok then
        vim.notify('diffy: pushed')
      end
      require('diffy.git.run').ready({ session = s.id, event = 'review' })
    end)
  elseif sub == 'pull' then
    if type(review.backend.pull) ~= 'function' then
      vim.notify(('diffy: `review pull` isn\'t available for %s'):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    review.backend.pull(s, function()
      require('diffy.git.run').ready({ session = s.id, event = 'review' })
    end)
  elseif sub == 'submit' then
    if type(review.backend.submit) ~= 'function' then
      vim.notify(('diffy: `review submit` isn\'t available for %s'):format(review.backend.name), vim.log.levels.WARN)
      return
    end
    local event = ({ comment = 'COMMENT', approve = 'APPROVE', request_changes = 'REQUEST_CHANGES' })[args[2] or 'comment']
    if not event then
      vim.notify('diffy: `review submit` expects comment|approve|request_changes', vim.log.levels.WARN)
      return
    end
    ui.open_submit_body(s, function(body)
      review.backend.submit(s, event, body, function(ok, warnings)
        for _, w in ipairs(warnings or {}) do
          vim.notify('diffy: ' .. w, vim.log.levels.WARN)
        end
        if ok then
          vim.notify('diffy: submitted')
        end
        require('diffy.git.run').ready({ session = s.id, event = 'review' })
      end)
    end)
  else
    vim.notify(('diffy: `review %s` is not implemented yet'):format(sub or ''), vim.log.levels.WARN)
  end
end

function M.dispatch.close()
  local s = session.for_tab(vim.api.nvim_get_current_tabpage())
  if not s then
    vim.notify('diffy: no session in the current tab', vim.log.levels.WARN)
    return
  end
  require('diffy.checkout').leave(s, function(ok)
    if ok then
      session.teardown(s)
      require('diffy.git.run').ready({ session = s.id, event = 'close' })
    end
  end)
end

local function entry_key(e)
  return e.kind .. ':' .. (e.sha or '')
end

-- `R` and diffy's own mutations rebuild everything but keep the selection when
-- its endpoints still exist.
local function keep_selection(old_entries, old_sel, entries)
  if not (old_entries and old_sel) then
    return nil
  end
  local index = {}
  for i, e in ipairs(entries) do
    index[entry_key(e)] = i
  end
  local top = index[entry_key(old_entries[old_sel.top])]
  local bottom = index[entry_key(old_entries[old_sel.bottom])]
  if top and bottom and top <= bottom then
    return { top = top, bottom = bottom }
  end
  return nil
end

--- Build (or rebuild, on `R`) the log/tree/diff-pair content for `s` from
--- its stored `s.root`/`s.range` (contract §2's render pipeline): entries,
--- default/kept selection, HEAD and repo status, then the panels. Fires
--- `User DiffyReady` once rendering finishes.
function M.build(s)
  local log_panel = require('diffy.panels.log')
  local tree_panel = require('diffy.panels.tree')
  local repo = require('diffy.git.repo')
  local run = require('diffy.git.run')
  local selection = require('diffy.selection')

  log_panel.build_entries(s.root, s.range, function(entries, err)
    if not entries then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local kept = keep_selection(s.entries, s.sel, entries)
    s.entries = entries
    s.follow_pathspec = entries.follow_pathspec
    s.sel = kept or log_panel.default_selection(entries, s.range)
    if not s.sel then
      vim.notify('diffy: nothing to show for this selection', vim.log.levels.WARN)
      return
    end
    repo.head_sha(s.root, function(head_sha)
      s.head_sha = head_sha
      repo.status(s.root, function(status_entries)
        s.status_entries = status_entries or {}
        s.pair = selection.resolve(s.entries, s.sel.top, s.sel.bottom)
        if not s.setup_done then
          log_panel.setup(s)
          tree_panel.setup(s)
          require('diffy.navigation').setup(s)
          s.setup_done = true
        end
        local function finish()
          session.relayout(s)
          log_panel.render(s)
          tree_panel.render(s, function()
            run.ready({ session = s.id, event = 'render' })
          end)
        end
        -- §9.4: threads/reviews/description cached per session, refreshed
        -- with `R` (which re-runs the whole of `M.build`) - fetched here,
        -- before the final render, so `review/ui.lua`'s decorate (called
        -- from that render) finds `s.review` already populated.
        if s.range.kind == 'pr' then
          require('diffy.review.github').refresh(s, finish)
        else
          finish()
        end
      end, s)
    end, s)
  end, s)
end

--- Open a new session for `spec` (`{kind='default'|'branch'|'range', ...}`,
--- see panels/log.lua) immediately (the tab/skeleton, contract §1/§2 -
--- teardown paths and the leak check depend on this happening
--- synchronously with the command), then resolve the repo root and build
--- the panels asynchronously once it's known.
function M.start(spec)
  local repo = require('diffy.git.repo')
  local selection = require('diffy.selection')
  local log_panel = require('diffy.panels.log')
  local tree_panel = require('diffy.panels.tree')
  local run = require('diffy.git.run')

  local s = session.open({ range = spec })
  s.on_select = function(sess)
    require('diffy.checkout').before_select(sess, function()
      sess.pair = selection.resolve(sess.entries, sess.sel.top, sess.sel.bottom)
      log_panel.render(sess)
      tree_panel.render(sess, function()
        run.ready({ session = sess.id, event = 'select' })
      end)
    end)
  end
  s.refresh = function(sess)
    M.build(sess)
  end

  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
      session.teardown(s)
      return
    end
    s.root = root
    s.gitdir = vim.fn.FugitiveExtractGitDir(root)
    if spec.abspath then
      local rel = spec.abspath
      if rel:sub(1, #root + 1) == root .. '/' then
        rel = rel:sub(#root + 2)
      end
      spec.path = rel
    end
    if require('diffy.checkout').pending(s.gitdir) then
      vim.notify('diffy: an interrupted full checkout is pending here — run `:Diffy restore`', vim.log.levels.WARN)
    end
    M.build(s)
  end, s)
end

function M.dispatch.branch(args)
  M.start({ kind = 'branch', base = args[1] })
end

--- `:Diffy pr` (§4, §9.4): only on the checked-out branch, only when local
--- HEAD equals the PR head on GitHub and the tree is clean. Log = PR
--- commits (`merge-base(base)..HEAD`); default selection all (no
--- Unstaged/Staged - the readiness check already guarantees none exist).
function M.dispatch.pr(_args)
  local repo = require('diffy.git.repo')
  local run = require('diffy.git.run')
  local github = require('diffy.review.github')
  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
      run.ready({ event = 'pr' })
      return
    end
    github.find_pr(root, function(pr, ferr)
      if not pr then
        vim.notify('diffy: `:Diffy pr` refused - ' .. tostring(ferr), vim.log.levels.WARN)
        run.ready({ event = 'pr' })
        return
      end
      repo.head_sha(root, function(head_sha)
        repo.is_clean(root, nil, function(clean)
          github.pr_readiness(root, head_sha, pr.headRefOid, clean, function(ok, reason)
            if not ok then
              vim.notify('diffy: `:Diffy pr` refused - ' .. reason, vim.log.levels.WARN)
              run.ready({ event = 'pr' })
              return
            end
            M.start({ kind = 'pr', base = pr.baseRefName, pr_number = pr.number })
          end)
        end)
      end)
    end)
  end)
end

function M.dispatch.restore(args)
  require('diffy.checkout').restore(args)
end

--- `:Diffy file [path]` (§4): log = commits touching `path` (`--follow`),
--- default selection the newest commit; `path` defaults to the current
--- buffer's file.
function M.dispatch.file(args)
  local abspath
  if args[1] then
    abspath = vim.fn.fnamemodify(args[1], ':p')
  else
    abspath = vim.api.nvim_buf_get_name(0)
    if abspath == '' then
      vim.notify('diffy: no path given and the current buffer has no file', vim.log.levels.WARN)
      return
    end
  end
  M.start({ kind = 'file', abspath = abspath })
end

--- `:Diffy conflicts` (§8): the 4-window conflict view over every
--- unmerged file, tree-only (no log entries).
function M.dispatch.conflicts()
  require('diffy.conflict').start()
end

--- Open the default session skeleton (§2 layout) for a bare `:Diffy`.
--- `args` beyond the subcommand set is unrecognized here: ranges (`A..B`)
--- are routed by `M.command` before reaching this.
function M.open(args)
  if args and args[1] then
    vim.notify(('diffy: unrecognized argument `%s`'):format(args[1]), vim.log.levels.WARN)
    return
  end
  M.start({ kind = 'default' })
end

--- Entry point for the `:Diffy` command. `fargs` is `opts.fargs` from the
--- user command (already split, no subcommand quoting to worry about).
function M.command(fargs)
  local sub = fargs[1]
  if sub and M.dispatch[sub] then
    M.dispatch[sub](vim.list_slice(fargs, 2))
    return
  end
  if sub and sub:find('..', 1, true) then
    M.start({ kind = 'range', expr = sub })
    return
  end
  M.open(fargs)
end

return M
