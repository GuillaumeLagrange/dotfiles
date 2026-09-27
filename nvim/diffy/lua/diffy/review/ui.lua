-- Review UI (contract §9.2, shared by every backend): signs + mirrored
-- virt_lines summaries, the thread float (`K`/`<CR>`), the compose float
-- (`gc`), `]t`/`[t`, `<leader>dt`, `gP` (GitHub PR description), and
-- `:Diffy threads`'s quickfix list.
--
-- `session.review` (nil until `M.ensure` runs, `false` if this session's
-- range kind doesn't support review, else a table):
--   backend   the backend module (`review/local.lua` for `:Diffy`/`:Diffy
--             branch`, `review/github.lua` for `:Diffy pr`)
--   branch    backend-resolved persistence scope key
--   threads   Thread[] (see review/model.lua)
--   inline    whether decorations are currently drawn (`<leader>dt`)
--   pr        GitHub only: `{number, title, body, base, head_sha,
--             conversation, reviews, pending}` (`review/github.lua`'s
--             `M.refresh`) - `gP`'s source.
--   merge_base, _diff_cache  GitHub only: placement plumbing, not for UI use.
-- A backend module exposes: `name`, `capabilities = {resolve, suggestions}`,
-- `branch(session)`, `author(root)`,
-- `place(session, thread) -> nil | {win='left'|'right', start_line,
--   end_line}` (contract §9.4 placement/§9.3 relocation - the *only*
--   backend-specific step of decorate(), everything else in this file is
--   shared). A backend that also supports authoring (`review/local.lua`
--   today; `review/github.lua` gains this in phase 7B) additionally
--   exposes `load(session, branch) -> Thread[]`, `save(session, branch,
--   threads)`, `clear(session, branch)`, `export(session, cb)` - `gc`/`r`/
--   `x` etc. are no-ops (with a notice) while a backend lacks `save`.
local session_mod = require('diffy.session')
local model = require('diffy.review.model')
local run = require('diffy.git.run')

local M = {}

local function review_available(session)
  local kind = session.range and session.range.kind
  return kind == 'default' or kind == 'branch' or kind == 'pr'
end

--- Lazily resolve the backend, branch and persisted threads for `session`.
--- Returns the `session.review` table, or nil if review isn't available for
--- this session's range kind (contract §9.3/§9.4: `:Diffy`/`:Diffy branch`/
--- `:Diffy pr`). For `kind='pr'`, `init.lua`'s `M.build` has already
--- populated `session.review` via `review/github.lua`'s async `M.refresh`
--- before any render runs, so the lazy-init branch below only matters as a
--- safety net (e.g. a test driving `review/ui.lua` directly without going
--- through `:Diffy pr`) - it seeds an empty thread list rather than
--- attempting a synchronous fetch.
function M.ensure(session)
  if session.review ~= nil then
    return session.review or nil
  end
  if not review_available(session) then
    session.review = false
    return nil
  end
  if session.range.kind == 'pr' then
    local backend = require('diffy.review.github')
    session.review = { backend = backend, branch = backend.branch(session), threads = {}, inline = true }
    return session.review
  end
  local backend = require('diffy.review.local')
  local branch = backend.branch(session)
  session.review = {
    backend = backend,
    branch = branch,
    threads = backend.load(session, branch),
    inline = true,
  }
  return session.review
end

function M.side_of(session, win)
  if win == session.wins.left then
    return 'left'
  elseif win == session.wins.right then
    return 'right'
  end
  return nil
end

-- row(l) = l + (filler lines above l), per contract §9.2/AGENTS.md - the
-- same computation as `tests/helpers/ui.lua`'s `aligned()`, duplicated here
-- (production code can't require test helpers) rather than re-derived.
local function screen_row(win, lnum)
  return vim.api.nvim_win_call(win, function()
    local filler = 0
    for k = 1, lnum do
      filler = filler + vim.fn.diff_filler(k)
    end
    return lnum + filler
  end)
end

--- The line in `other_win` whose row equals `lnum`'s row in `win`, or nil
--- if none matches (e.g. `lnum` has no counterpart at all).
local function counterpart_line(win, lnum, other_win)
  local target = screen_row(win, lnum)
  local other_buf = vim.api.nvim_win_get_buf(other_win)
  local count = vim.api.nvim_buf_line_count(other_buf)
  for l = 1, count do
    if screen_row(other_win, l) == target then
      return l
    end
  end
  return nil
end

--- Open any closed fold covering `lnum` in `win` (contract §9.4: a thread
--- placed on a line unchanged in the current view - inside a diff fold -
--- gets its fold opened, as github.com adds a context hunk for it). `!`
--- opens every nested level; diff folds are flat, but this is harmless
--- either way.
local function open_fold_if_closed(win, lnum)
  vim.api.nvim_win_call(win, function()
    if vim.fn.foldclosed(lnum) ~= -1 then
      vim.cmd(('%dfoldopen!'):format(lnum))
    end
  end)
end

--- Redraw every thread's sign + summary for the current file/pair (call
--- after `diffpair.show`), and the counterpart blank lines that keep the
--- two windows aligned (§9.2). No-op when review isn't available for this
--- session. Placement is entirely `review.backend.place`'s job (local:
--- excerpt relocation within the exact view it was written in, §9.1/§9.3;
--- GitHub: line tracking across commits, §9.4) - this function only draws
--- whatever it returns, caching it on `thread._place` (session-only, not
--- persisted) so `M.thread_at`/`M.next_thread`/`M.quickfix` don't need to
--- recompute placement themselves.
function M.decorate(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  local ns = session_mod.namespace(session, 'review')
  local wins = { left = session.wins.left, right = session.wins.right }
  local live_wins = {}
  for _, w in pairs(wins) do
    if w and vim.api.nvim_win_is_valid(w) then
      table.insert(live_wins, w)
    end
  end
  pcall(vim.api.nvim__ns_set, ns, { wins = live_wins })

  for _, name in ipairs({ 'left', 'right' }) do
    local win = wins[name]
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), ns, 0, -1)
    end
  end

  if not review.inline then
    for _, t in ipairs(review.threads) do
      t._place = nil
    end
    run.ready({ session = session.id, event = 'review' })
    return
  end

  local placed = { left = {}, right = {} }
  for _, thread in ipairs(review.threads) do
    thread._detached = nil
    thread._place = nil
    if thread.anchor.path == session.current_path then
      local place = review.backend.place(session, thread)
      local win = place and wins[place.win]
      if win and vim.api.nvim_win_is_valid(win) then
        thread._place = place
        table.insert(placed[place.win], thread)
      end
    end
  end

  for _, name in ipairs({ 'left', 'right' }) do
    local win = wins[name]
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local by_end = {}
      for _, t in ipairs(placed[name]) do
        vim.api.nvim_buf_set_extmark(buf, ns, t._place.start_line - 1, 0, {
          sign_text = '\240\159\146\172',
          sign_hl_group = 'Comment',
        })
        open_fold_if_closed(win, t._place.start_line)
        by_end[t._place.end_line] = by_end[t._place.end_line] or {}
        table.insert(by_end[t._place.end_line], t)
      end
      local other_name = name == 'left' and 'right' or 'left'
      local other_win = wins[other_name]
      for end_line, threads_here in pairs(by_end) do
        open_fold_if_closed(win, end_line)
        local vlines = {}
        for _, t in ipairs(threads_here) do
          table.insert(vlines, { { model.summary_text(t), 'Comment' } })
        end
        vim.api.nvim_buf_set_extmark(buf, ns, end_line - 1, 0, { virt_lines = vlines })
        if other_win and vim.api.nvim_win_is_valid(other_win) then
          local co = counterpart_line(win, end_line, other_win)
          if co then
            open_fold_if_closed(other_win, co)
            local blanks = {}
            for _ = 1, #vlines do
              table.insert(blanks, { { '', 'Normal' } })
            end
            vim.api.nvim_buf_set_extmark(vim.api.nvim_win_get_buf(other_win), ns, co - 1, 0, { virt_lines = blanks })
          end
        end
      end
    end
  end
  run.ready({ session = session.id, event = 'review' })
end

--- `<leader>dt`: toggle inline decorations without touching drafts.
function M.toggle_inline(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.inline = not review.inline
  M.decorate(session)
end

-- ---------------------------------------------------------------------
-- compose float (`gc`)

--- Open a floating markdown compose buffer anchored below line `anchor_row`
--- of `anchor_win`. `<C-s>`/`:w` calls `on_save(lines)` and closes; `q`
--- cancels (closes without calling `on_save`). `opts.prefill`, if given,
--- seeds the buffer (editing an existing draft).
function M.open_compose(session, anchor_win, anchor_line, on_save, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  local seq = session._review_buf_seq
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/compose/%d'):format(session.id, seq))
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'compose_' .. seq, buf)
  if opts.prefill then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.prefill)
    vim.bo[buf].modified = false
  end

  -- window-relative screen row of the line right below `anchor_line`, via
  -- `screenpos` (works even if that line isn't the current cursor line,
  -- unlike a `winline()` reading) - falls back to the top of the window if
  -- the anchor line is currently scrolled out of view.
  local pos = vim.fn.screenpos(anchor_win, anchor_line, 1)
  local row = 1
  if pos and pos.row > 0 then
    row = pos.row - vim.api.nvim_win_get_position(anchor_win)[1]
  end

  local width = math.max(20, math.min(60, vim.o.columns - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = anchor_win,
    width = width,
    height = 6,
    row = row,
    col = 0,
    style = 'minimal',
    border = 'rounded',
    zindex = 200,
  })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end


  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = session.augroup,
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      on_save(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      close()
    end,
  })

  session_mod.map(session, { 'n', 'i' }, '<C-s>', function()
    vim.cmd('write')
  end, { buffer = buf, desc = 'save comment' })
  session_mod.map(session, 'n', 'q', close, { buffer = buf, desc = 'cancel comment' })
  session_mod.map(session, { 'n', 'i' }, '<C-g>s', function()
    if not opts.suggestion then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local block = { '```suggestion' }
    vim.list_extend(block, opts.suggestion)
    table.insert(block, '```')
    vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, block)
    vim.api.nvim_win_set_cursor(0, { lnum + #block, 0 })
  end, { buffer = buf, desc = 'insert suggestion block' })

  vim.cmd('startinsert')
  run.ready({ session = session.id, event = 'compose' })
end

--- `gc` (normal on a line, `mode='n'`; visual on a range, `mode='v'`):
--- compose a brand-new thread anchored at the cursor line/marked range.
function M.compose(session, mode)
  local win = vim.api.nvim_get_current_win()
  local side = M.side_of(session, win)
  if not side then
    return
  end
  local review = M.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  if type(review.backend.save) ~= 'function' then
    vim.notify(('diffy: composing comments isn\'t implemented yet for %s'):format(review.backend.name), vim.log.levels.WARN)
    return
  end

  local start_line, end_line
  if mode == 'v' then
    vim.cmd('normal! \27') -- <Esc>, so the '< '> marks settle
    local a = vim.api.nvim_buf_get_mark(0, '<')[1]
    local b = vim.api.nvim_buf_get_mark(0, '>')[1]
    start_line, end_line = math.min(a, b), math.max(a, b)
  else
    local l = vim.api.nvim_win_get_cursor(win)[1]
    start_line, end_line = l, l
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local excerpt = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  local rev = side == 'left' and session.pair.left or session.pair.right
  local anchor = {
    path = session.current_path,
    side = side == 'left' and 'old' or 'new',
    start_line = start_line,
    end_line = end_line,
    commit = model.rev_to_commit(rev, session.head_sha),
    excerpt = excerpt,
  }
  local function pin(r)
    return r == 'HEAD' and session.head_sha or r
  end
  local pinned_left, pinned_right = pin(session.pair.left), pin(session.pair.right)

  local suggestion = review.backend.capabilities.suggestions and excerpt or nil
  M.open_compose(session, win, end_line, function(body)
    if vim.trim(table.concat(body, '\n')) == '' then
      return
    end
    local backend = review.backend
    local thread = {
      id = model.next_thread_id(review.threads),
      backend = backend.name,
      anchor = anchor,
      comments = {
        {
          id = model.next_comment_id(review.threads),
          author = backend.author(session.root),
          body = table.concat(body, '\n'),
          created_at = os.time(),
          state = 'draft',
        },
      },
      resolved = false,
      outdated = false,
      _has_source = true,
      -- the pair the comment was written against, for review.md's diff hunk
      view = { left = pinned_left, right = pinned_right },
    }
    table.insert(review.threads, thread)
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
  end, { suggestion = suggestion })
end

--- Reply to an existing `thread`: appends a new comment on save.
function M.reply(session, thread)
  local review = session.review
  if type(review.backend.save) ~= 'function' then
    vim.notify(('diffy: replying isn\'t implemented yet for %s'):format(review.backend.name), vim.log.levels.WARN)
    return
  end
  local backend = review.backend
  local side = model.pair_side(session.pair, session.head_sha, thread.anchor)
  local win = (side and session.wins[side]) or vim.api.nvim_get_current_win()
  M.open_compose(session, win, thread.anchor.end_line, function(body)
    if vim.trim(table.concat(body, '\n')) == '' then
      return
    end
    table.insert(thread.comments, {
      id = model.next_comment_id(review.threads),
      author = backend.author(session.root),
      body = table.concat(body, '\n'),
      created_at = os.time(),
      state = 'draft',
    })
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
  end)
end

--- Edit `comment` (must be `state == 'draft'`, checked by the caller) of
--- `thread`, replacing its body on save.
function M.edit_comment(session, thread, comment)
  local review = session.review
  local backend = review.backend
  local side = model.pair_side(session.pair, session.head_sha, thread.anchor)
  local win = (side and session.wins[side]) or vim.api.nvim_get_current_win()
  M.open_compose(session, win, thread.anchor.end_line, function(body)
    comment.body = table.concat(body, '\n')
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
  end, { prefill = vim.split(comment.body, '\n', { plain = true }) })
end

-- ---------------------------------------------------------------------
-- thread float (`K`/`<CR>`)

--- Thread anchored on `lnum` of `win` (must be one of the session's diff
--- windows), or nil.
function M.thread_at(session, win, lnum)
  local review = session.review
  if not review then
    return nil
  end
  for _, t in ipairs(review.threads) do
    if t._place and session.wins[t._place.win] == win and lnum >= t._place.start_line and lnum <= t._place.end_line then
      return t
    end
  end
  return nil
end

local function render_thread_float(session, thread)
  local review = session.review
  local backend = review.backend
  local lines = {}
  if thread.resolved then
    table.insert(lines, '_resolved_')
    table.insert(lines, '')
  end
  for _, c in ipairs(thread.comments) do
    local when = type(c.created_at) == 'number' and os.date('%Y-%m-%d %H:%M', c.created_at) or tostring(c.created_at)
    table.insert(lines, ('**%s** _%s_ (%s):'):format(c.author, when, c.state))
    vim.list_extend(lines, vim.split(c.body, '\n', { plain = true }))
    table.insert(lines, '')
  end

  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  local seq = session._review_buf_seq
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/thread/%d'):format(session.id, seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'thread_' .. seq, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.max(20, math.min(70, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    zindex = 200,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  session_mod.map(session, 'n', 'q', close, { buffer = buf, desc = 'close thread' })
  session_mod.map(session, 'n', 'r', function()
    close()
    M.reply(session, thread)
  end, { buffer = buf, desc = 'reply' })
  session_mod.map(session, 'n', 'e', function()
    local last = thread.comments[#thread.comments]
    if not last or last.state ~= 'draft' then
      vim.notify('diffy: only a draft comment can be edited', vim.log.levels.WARN)
      return
    end
    close()
    M.edit_comment(session, thread, last)
  end, { buffer = buf, desc = 'edit draft' })
  session_mod.map(session, 'n', 'dd', function()
    local last = thread.comments[#thread.comments]
    if not last or last.state ~= 'draft' then
      vim.notify('diffy: only a draft comment can be deleted', vim.log.levels.WARN)
      return
    end
    table.remove(thread.comments)
    if #thread.comments == 0 then
      for i, t in ipairs(review.threads) do
        if t == thread then
          table.remove(review.threads, i)
          break
        end
      end
    end
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
    close()
  end, { buffer = buf, desc = 'delete draft' })
  if backend.capabilities.resolve then
    session_mod.map(session, 'n', 'x', function()
      if type(backend.resolve_thread) == 'function' then
        backend.resolve_thread(session, thread, not thread.resolved, function(ok)
          if ok then
            close()
          end
        end)
        return
      end
      thread.resolved = not thread.resolved
      backend.save(session, review.branch, review.threads)
      M.decorate(session)
      close()
    end, { buffer = buf, desc = 'resolve/unresolve thread' })
  end
end

--- `K`/`<CR>`: open the float for the thread anchored at the cursor, if
--- any (no-op otherwise, so `K`'s usual keywordprg on a plain line isn't
--- missed for long - review threads are the exception, not everywhere).
function M.open_thread(session)
  local win = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local thread = M.thread_at(session, win, lnum)
  if thread then
    render_thread_float(session, thread)
  end
end

--- `]t`/`[t`: move the cursor to the next/previous thread anchored in the
--- current window's file, wrapping is not needed (edges are simply a
--- no-op past the last/first thread).
function M.next_thread(session, delta)
  local win = vim.api.nvim_get_current_win()
  local side = M.side_of(session, win)
  local review = session.review
  if not side or not review then
    return
  end
  local candidates = {}
  for _, t in ipairs(review.threads) do
    if t._place and t._place.win == side then
      table.insert(candidates, t)
    end
  end
  if #candidates == 0 then
    return
  end
  table.sort(candidates, function(a, b)
    return a._place.start_line < b._place.start_line
  end)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if delta > 0 then
    for _, t in ipairs(candidates) do
      if t._place.start_line > lnum then
        target = t
        break
      end
    end
  else
    for i = #candidates, 1, -1 do
      if candidates[i]._place.start_line < lnum then
        target = candidates[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(win, { target._place.start_line, 0 })
  end
end

--- One-time keymap setup for a diff-window buffer (`diffpair.lua`, on
--- every left/right swap): `gc`, `K`/`<CR>`, `]t`/`[t`, `<leader>dt`. These
--- apply on any diff buffer, real file or blob alike (§9.2).
function M.setup_diff_keymaps(session, buf)
  local map = session_mod.map
  map(session, 'n', 'gc', function()
    M.compose(session, 'n')
  end, { buffer = buf, desc = 'review: new comment' })
  map(session, { 'v', 'x' }, 'gc', function()
    M.compose(session, 'v')
  end, { buffer = buf, desc = 'review: new comment on range' })
  map(session, 'n', 'K', function()
    M.open_thread(session)
  end, { buffer = buf, desc = 'review: open thread' })
  map(session, 'n', '<CR>', function()
    M.open_thread(session)
  end, { buffer = buf, desc = 'review: open thread' })
  map(session, 'n', ']t', function()
    M.next_thread(session, 1)
  end, { buffer = buf, desc = 'review: next thread' })
  map(session, 'n', '[t', function()
    M.next_thread(session, -1)
  end, { buffer = buf, desc = 'review: previous thread' })
  map(session, 'n', '<leader>dt', function()
    M.toggle_inline(session)
  end, { buffer = buf, desc = 'review: toggle inline threads' })
  map(session, 'n', 'gP', function()
    M.open_pr_description(session)
  end, { buffer = buf, desc = 'review: PR description' })
end

-- ---------------------------------------------------------------------
-- `gP`: GitHub PR description + conversation comments (contract §9.4)

--- `gP`: read-only markdown float with the PR's description and
--- conversation comments (`review.pr`, populated by `review/github.lua`'s
--- `M.refresh`). Only available for a `:Diffy pr` session.
function M.open_pr_description(session)
  local review = session.review
  if not review or review.backend.name ~= 'github' or not review.pr then
    vim.notify('diffy: `gP` is only available in :Diffy pr', vim.log.levels.WARN)
    return
  end
  local pr = review.pr
  local lines = { ('# #%d %s'):format(pr.number, pr.title or ''), '' }
  vim.list_extend(lines, vim.split(pr.body or '', '\n', { plain = true }))
  if #pr.conversation > 0 then
    vim.list_extend(lines, { '', '---', '' })
    for _, c in ipairs(pr.conversation) do
      table.insert(lines, ('**%s**:'):format(c.author or 'unknown'))
      vim.list_extend(lines, vim.split(c.body or '', '\n', { plain = true }))
      table.insert(lines, '')
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/pr/%d'):format(session.id, session._review_buf_seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'pr_' .. session._review_buf_seq, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width = math.max(40, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    zindex = 200,
  })
  session_mod.map(session, 'n', 'q', function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end, { buffer = buf, desc = 'close PR description' })
end

--- `:Diffy review submit`'s body float (contract §9.4: "a body composed in
--- a float") - centered, unlike `M.open_compose`'s floats, which anchor
--- below a diff line: a review submission body isn't anchored to any one.
--- `<C-s>`/`:w` calls `on_save(body)` (a single string, blank if the
--- buffer was left empty) and closes; `q` cancels (`on_save` never runs).
function M.open_submit_body(session, on_save)
  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  local seq = session._review_buf_seq
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/submit/%d'):format(session.id, seq))
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'submit_' .. seq, buf)

  local width = math.max(40, math.min(80, vim.o.columns - 4))
  local height = 8
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    zindex = 200,
  })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    vim.cmd('stopinsert')
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = session.augroup,
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      on_save(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
      close()
    end,
  })
  session_mod.map(session, { 'n', 'i' }, '<C-s>', function()
    vim.cmd('write')
  end, { buffer = buf, desc = 'submit review' })
  session_mod.map(session, 'n', 'q', close, { buffer = buf, desc = 'cancel submit' })

  vim.cmd('startinsert')
  run.ready({ session = session.id, event = 'compose' })
end

-- ---------------------------------------------------------------------
-- `:Diffy threads`

--- `:Diffy threads [author=<name>] [state=<open|resolved|outdated|detached>]
--- [review=<id>]`: quickfix list of every thread in the session (incl.
--- detached/outdated ones - §9.2/§9.4), optionally filtered. For GitHub,
--- appends which commits (contract §9.4: "with the commits each thread is
--- visible in") each thread currently shows in.
function M.quickfix(session, args)
  local review = M.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  local filters = {}
  for _, a in ipairs(args or {}) do
    local k, v = a:match('^(%a+)=(.*)$')
    if k then
      filters[k] = v
    end
  end

  local items = {}
  for _, t in ipairs(review.threads) do
    local author = t.comments[1] and t.comments[1].author or ''
    local state = t.resolved and 'resolved' or (t.outdated and 'outdated') or (t._detached and 'detached' or 'open')
    local include = true
    if filters.author and filters.author ~= author then
      include = false
    end
    if filters.state and filters.state ~= state then
      include = false
    end
    if filters.review and filters.review ~= (t.review_id or '') then
      include = false
    end
    if include then
      local text = ('%s [%s] %s'):format(t.id, state, model.summary_text(t))
      if review.backend.visible_in then
        local visible = review.backend.visible_in(session, t)
        text = text .. (' (%s)'):format(#visible > 0 and table.concat(visible, ', ') or 'nowhere inline')
      end
      table.insert(items, {
        filename = session.root .. '/' .. t.anchor.path,
        lnum = math.max(1, t.anchor.start_line or 1),
        text = text,
      })
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'diffy threads', items = items })
  vim.cmd('copen')
end

return M
