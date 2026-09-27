-- Review UI (contract §9.2, shared by every backend): signs + mirrored
-- virt_lines summaries, the thread float (`K`/`<CR>`), the compose float
-- (`gc`), `]t`/`[t`, `<leader>dt`, and `:Diffy threads`'s quickfix list.
--
-- `session.review` (nil until `M.ensure` runs, `false` if this session's
-- range kind doesn't support review, else a table):
--   backend   the backend module (`review/local.lua`; a `review/github.lua`
--             would be selected the same way for a later phase)
--   branch    backend-resolved branch/scope name
--   threads   Thread[] (see review/model.lua), backend's own persisted list
--   inline    whether decorations are currently drawn (`<leader>dt`)
-- A backend module exposes: `name`, `capabilities = {resolve, suggestions}`,
-- `branch(session)`, `author(root)`, `load(session, branch)`,
-- `save(session, branch, threads)`, `clear(session, branch)`,
-- `export(session, cb)` (local-only today; a github backend would add
-- push/pull/submit alongside the same shape).
local session_mod = require('diffy.session')
local model = require('diffy.review.model')
local run = require('diffy.git.run')

local M = {}

local function review_available(session)
  local kind = session.range and session.range.kind
  return kind == 'default' or kind == 'branch'
end

--- Lazily resolve the backend, branch and persisted threads for `session`.
--- Returns the `session.review` table, or nil if review isn't available for
--- this session's range kind (contract §9.3: `:Diffy`/`:Diffy branch` only).
function M.ensure(session)
  if session.review ~= nil then
    return session.review or nil
  end
  if not review_available(session) then
    session.review = false
    return nil
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

--- Redraw every thread's sign + summary for the current file/pair (call
--- after `diffpair.show`), and the counterpart blank lines that keep the
--- two windows aligned (§9.2). No-op when review isn't available for this
--- session. Also runs excerpt relocation (§9.1) and marks threads that
--- can't be found `_detached` (session-only bookkeeping, not persisted).
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
    run.ready({ session = session.id, event = 'review' })
    return
  end

  local placed = { left = {}, right = {} }
  for _, thread in ipairs(review.threads) do
    thread._detached = nil
    if thread.anchor.path == session.current_path then
      local side = model.pair_side(session.pair, session.head_sha, thread.anchor)
      local win = side and wins[side]
      if win and vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        if model.relocate(thread.anchor, lines) then
          table.insert(placed[side], thread)
        else
          thread._detached = true
        end
      end
    end
  end

  for _, name in ipairs({ 'left', 'right' }) do
    local win = wins[name]
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local by_end = {}
      for _, t in ipairs(placed[name]) do
        vim.api.nvim_buf_set_extmark(buf, ns, t.anchor.start_line - 1, 0, {
          sign_text = '\240\159\146\172',
          sign_hl_group = 'Comment',
        })
        by_end[t.anchor.end_line] = by_end[t.anchor.end_line] or {}
        table.insert(by_end[t.anchor.end_line], t)
      end
      local other_name = name == 'left' and 'right' or 'left'
      local other_win = wins[other_name]
      for end_line, threads_here in pairs(by_end) do
        local vlines = {}
        for _, t in ipairs(threads_here) do
          table.insert(vlines, { { model.summary_text(t), 'Comment' } })
        end
        vim.api.nvim_buf_set_extmark(buf, ns, end_line - 1, 0, { virt_lines = vlines })
        if other_win and vim.api.nvim_win_is_valid(other_win) then
          local co = counterpart_line(win, end_line, other_win)
          if co then
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
    vim.notify('diffy: review is only available in :Diffy and :Diffy branch', vim.log.levels.WARN)
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
    }
    table.insert(review.threads, thread)
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
  end)
end

--- Reply to an existing `thread`: appends a new comment on save.
function M.reply(session, thread)
  local review = session.review
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
    if not t._detached and t.anchor.path == session.current_path then
      local side = model.pair_side(session.pair, session.head_sha, t.anchor)
      if side and session.wins[side] == win and lnum >= t.anchor.start_line and lnum <= t.anchor.end_line then
        return t
      end
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
    table.insert(lines, ('**%s** _%s_ (%s):'):format(c.author, os.date('%Y-%m-%d %H:%M', c.created_at), c.state))
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
    if not t._detached and t.anchor.path == session.current_path then
      if model.pair_side(session.pair, session.head_sha, t.anchor) == side then
        table.insert(candidates, t)
      end
    end
  end
  if #candidates == 0 then
    return
  end
  table.sort(candidates, function(a, b)
    return a.anchor.start_line < b.anchor.start_line
  end)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if delta > 0 then
    for _, t in ipairs(candidates) do
      if t.anchor.start_line > lnum then
        target = t
        break
      end
    end
  else
    for i = #candidates, 1, -1 do
      if candidates[i].anchor.start_line < lnum then
        target = candidates[i]
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(win, { target.anchor.start_line, 0 })
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
end

-- ---------------------------------------------------------------------
-- `:Diffy threads`

--- `:Diffy threads [author=<name>] [state=<open|resolved|detached>]
--- [review=<id>]`: quickfix list of every thread in the session (incl.
--- detached ones - §9.2), optionally filtered.
function M.quickfix(session, args)
  local review = M.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy and :Diffy branch', vim.log.levels.WARN)
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
    local state = t.resolved and 'resolved' or (t._detached and 'detached' or 'open')
    local include = true
    if filters.author and filters.author ~= author then
      include = false
    end
    if filters.state and filters.state ~= state then
      include = false
    end
    if filters.review then
      include = false -- local threads have no review id to match
    end
    if include then
      table.insert(items, {
        filename = session.root .. '/' .. t.anchor.path,
        lnum = math.max(1, t.anchor.start_line),
        text = ('%s [%s] %s'):format(t.id, state, model.summary_text(t)),
      })
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'diffy threads', items = items })
  vim.cmd('copen')
end

return M
