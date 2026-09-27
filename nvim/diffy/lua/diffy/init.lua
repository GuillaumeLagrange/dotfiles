local session = require('diffy.session')

local function notify_not_repo(err)
  vim.notify('diffy: not a git repository (' .. tostring(err) .. ')', vim.log.levels.ERROR)
end

local M = {}

M.config = {
  -- width of the tree/log column
  panel_width = 40,
  keymaps = {
    -- buffer-local in every diffy window: hide/show the panel column
    toggle_panel = '<leader>e',
    -- … and go to the file tree, showing the column first if it's hidden
    focus_panel = '<leader>E',
  },
  -- copied to `+` by `:Diffy review export`; %s is the absolute path of review.md
  review_prompt = 'Read %s and address each review comment. Reply per comment id with what you changed.',
  -- GitHub avatars in comment headers, on terminals with the kitty graphics
  -- protocol (needs curl and ImageMagick)
  avatars = true,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

--- subcommand name -> function(args: string[])
M.dispatch = {}

local function current_session(where)
  local s = session.current()
  if not s then
    vim.notify(('diffy: no session in %s'):format(where or 'the current tab'), vim.log.levels.WARN)
  end
  return s
end

local function review_ready(s)
  require('diffy.git.run').ready({ session = s.id, event = 'review' })
end

local function backend_supports(review, sub)
  if type(review.backend[sub]) == 'function' then
    return true
  end
  vim.notify(('diffy: `review %s` isn\'t available for %s'):format(sub, review.backend.name), vim.log.levels.WARN)
  return false
end

--- Callback for GitHub backend calls answering `(ok, warnings)`.
local function report_remote(s, done_msg)
  return function(ok, warnings)
    for _, w in ipairs(warnings or {}) do
      vim.notify('diffy: ' .. w, vim.log.levels.WARN)
    end
    if ok then
      vim.notify(done_msg)
    end
    review_ready(s)
  end
end

local SUBMIT_EVENTS = { comment = 'COMMENT', approve = 'APPROVE', request_changes = 'REQUEST_CHANGES' }
local SUBMIT_TITLES = { COMMENT = 'Submit review', APPROVE = 'Approve', REQUEST_CHANGES = 'Request changes' }

--- `:Diffy threads [file] [author=<name>] [state=…] [review=<id>]`: every
--- thread in the session, or the shown file's, in a picker or the quickfix.
function M.dispatch.threads(args)
  local s = current_session()
  if not s then
    return
  end
  require('diffy.review.threads').open(s, args)
end

local review_subcommands = {}

function review_subcommands.export(s, review)
  review.backend.export(s, function(ok, result)
    if ok then
      vim.notify('diffy: exported review to ' .. result)
    else
      vim.notify('diffy: ' .. result, vim.log.levels.WARN)
    end
    review_ready(s)
  end)
end

function review_subcommands.clear(s, review, ui)
  review.backend.clear(s, review.branch)
  review.threads = {}
  ui.decorate(s)
  vim.notify('diffy: review cleared')
  review_ready(s)
end

function review_subcommands.push(s, review)
  review.backend.push(s, report_remote(s, 'diffy: pushed'))
end

function review_subcommands.pull(s, review)
  review.backend.pull(s, function()
    review_ready(s)
  end)
end

function review_subcommands.submit(s, review, ui, args)
  local event = SUBMIT_EVENTS[args[2] or 'comment']
  if not event then
    vim.notify('diffy: `review submit` expects comment|approve|request_changes', vim.log.levels.WARN)
    return
  end
  ui.open_submit_body(s, function(body)
    review.backend.submit(s, event, body, report_remote(s, 'diffy: submitted'))
  end, SUBMIT_TITLES[event])
end

--- `:Diffy review export|clear` (local backend) and
--- `push|pull|submit` (GitHub backend).
function M.dispatch.review(args)
  local s = current_session()
  if not s then
    return
  end
  local ui = require('diffy.review.ui')
  local review = ui.ensure(s)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  local sub = args[1]
  local handler = sub and review_subcommands[sub]
  if not handler then
    vim.notify(('diffy: `review %s` is not implemented yet'):format(sub or ''), vim.log.levels.WARN)
    return
  end
  if backend_supports(review, sub) then
    handler(s, review, ui, args)
  end
end

function M.dispatch.close()
  local s = current_session()
  if not s then
    return
  end
  require('diffy.checkout').leave(s, function(ok)
    if ok then
      session.teardown(s)
      require('diffy.git.run').ready({ session = s.id, event = 'close' })
    end
  end)
end

--- `:Diffy panel`: hide/show the tree/log column.
function M.dispatch.panel()
  local s = current_session('this tab')
  if not s then
    return
  end
  session.toggle_panels(s)
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
--- its stored `s.root`/`s.range`: entries, default/kept selection, HEAD and
--- repo status, then the panels. Fires `User DiffyReady` once rendering
--- finishes.
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
        -- PR threads/reviews/description are cached per session and refreshed
        -- by `R`; fetch them before the final render so its decorate pass
        -- finds `s.review` populated.
        if s.range.kind == 'pr' then
          require('diffy.review.github').refresh(s, finish)
        else
          finish()
        end
      end, s)
    end, s)
  end, s)
end

--- `abspath` relative to `root` when inside it, else unchanged.
local function relative_to(root, abspath)
  if abspath:sub(1, #root + 1) == root .. '/' then
    return abspath:sub(#root + 2)
  end
  return abspath
end

--- Open a new session for `spec` (`{kind='default'|'branch'|'range', ...}`,
--- see panels/log.lua). The tab skeleton is created synchronously so
--- teardown works immediately; the repo root and panels follow async.
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
      notify_not_repo(err)
      session.teardown(s)
      return
    end
    s.root = root
    s.gitdir = vim.fn.FugitiveExtractGitDir(root)
    if spec.abspath then
      spec.path = relative_to(root, spec.abspath)
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

--- `:Diffy pr`: only on the checked-out branch, only when local HEAD equals
--- the PR head on GitHub and the tree is clean. Log = PR commits
--- (`merge-base(base)..HEAD`), all selected by default.
function M.dispatch.pr(_args)
  local repo = require('diffy.git.repo')
  local run = require('diffy.git.run')
  local github = require('diffy.review.github')
  local function refuse(reason)
    vim.notify('diffy: `:Diffy pr` refused - ' .. tostring(reason), vim.log.levels.WARN)
    run.ready({ event = 'pr' })
  end
  repo.root(vim.fn.getcwd(), function(root, err)
    if not root then
      notify_not_repo(err)
      run.ready({ event = 'pr' })
      return
    end
    github.find_pr(root, function(pr, ferr)
      if not pr then
        refuse(ferr)
        return
      end
      repo.head_sha(root, function(head_sha)
        repo.is_clean(root, nil, function(clean)
          github.pr_readiness(root, head_sha, pr.headRefOid, clean, function(ok, reason)
            if not ok then
              refuse(reason)
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

--- `:Diffy file [path]`: log = commits touching `path` (`--follow`),
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

--- `:Diffy conflicts`: the 4-window conflict view over every unmerged file,
--- tree-only (no log entries).
function M.dispatch.conflicts()
  require('diffy.conflict').start()
end

--- Bare `:Diffy`. Ranges (`A..B`) are routed by `M.command` before this, so
--- any argument here is unrecognized.
function M.open(args)
  if args and args[1] then
    vim.notify(('diffy: unrecognized argument `%s`'):format(args[1]), vim.log.levels.WARN)
    return
  end
  M.start({ kind = 'default' })
end

--- Entry point for the `:Diffy` command; `fargs` is the user command's
--- `opts.fargs`.
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
