-- Review UI shared by every backend: signs + mirrored virt_lines summaries,
-- the thread float (`K`/`<CR>`), the compose float (`gc`), `]t`/`[t`, the
-- display toggles (`<leader>dt`/`ds`/`dr`), `gP` (GitHub PR description),
-- and the jump used by `:Diffy threads` (review/threads.lua).
--
-- `session.review` (nil until `M.ensure` runs, `false` if this session's
-- range kind doesn't support review, else a table):
--   backend   the backend module (`review/local.lua` for `:Diffy`/`:Diffy
--             branch`, `review/github.lua` for `:Diffy pr`)
--   branch    backend-resolved persistence scope key
--   threads   Thread[] (see review/model.lua)
--   inline    whether decorations are currently drawn (`<leader>dt`)
--   summaries whether summaries are drawn under commented lines, or only
--             signs (`<leader>ds`)
--   hide_resolved  whether resolved threads are left out (`<leader>dr`)
--   pr        GitHub only: `{number, title, body, author, created_at, base,
--             head_sha, conversation, reviews, pending}`, `gP`'s source.
--   merge_base, _diff_cache  GitHub only: placement plumbing, not for UI use.
-- A backend module exposes: `name`, `capabilities = {resolve, suggestions,
-- people}` (`people`: comments come from several people, so the float shows
-- names and avatars; else every comment is the user's), `branch(session)`,
-- `author(root)`, optionally `avatar_url(login)`,
-- `place(session, thread) -> nil | {win='left'|'right', start_line,
--   end_line}` (the only backend-specific step of decorate()), and, for
--   authoring, `load(session, branch) -> Thread[]`, `save(session, branch,
--   threads)`, `clear(session, branch)`, `export(session, cb)`. `gc`/`r`/`x`
--   etc. are no-ops (with a notice) while a backend lacks `save`.
local session_mod = require('diffy.session')
local model = require('diffy.review.model')
local run = require('diffy.git.run')
local highlight = require('diffy.highlight')
local avatar = require('diffy.avatar')

local M = {}

local function review_available(session)
  local kind = session.range and session.range.kind
  return kind == 'default' or kind == 'branch' or kind == 'pr'
end

--- Lazily resolve the backend, branch and persisted threads for `session`.
--- Returns the `session.review` table, or nil if review isn't available for
--- this session's range kind. For `kind='pr'`, `:Diffy pr` has already
--- populated `session.review` asynchronously before any render, so this
--- only seeds an empty thread list rather than fetching synchronously.
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
    session.review = { backend = backend, branch = backend.branch(session), threads = {}, inline = true, summaries = true }
    return session.review
  end
  local backend = require('diffy.review.local')
  local branch = backend.branch(session)
  session.review = {
    backend = backend,
    branch = branch,
    threads = backend.load(session, branch),
    inline = true,
    summaries = true,
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

-- row(l) = l + Σ diff_filler(k) for k ≤ l; equal rows in the two windows are
-- counterpart lines. Returns `win`'s line -> row and row -> line maps.
local function row_map(win)
  return vim.api.nvim_win_call(win, function()
    local row, line, filler = {}, {}, 0
    for l = 1, vim.api.nvim_buf_line_count(0) do
      filler = filler + vim.fn.diff_filler(l)
      row[l] = l + filler
      line[l + filler] = l
    end
    return { row = row, line = line }
  end)
end

--- One summary line: `💬 author +N: first line of the comment`, cut to
--- `width` so threads on the same line can be told apart. A resolved one
--- reads `✓ author +N: …`, dimmed. `hl`, when given, colours the whole line
--- (open or relevant thread, see `paint`).
local function summary_chunks(thread, width, hl)
  local first = thread.comments[1]
  local head = (first and first.author or 'unknown') .. (#thread.comments > 1 and (' +%d'):format(#thread.comments - 1) or '')
  -- both two cells wide, so resolved and open summaries line up
  local icon = thread.resolved and '✓ ' or '\240\159\146\172'
  local text_hl = thread.resolved and 'DiffyThreadSummaryResolved' or 'DiffyThreadSummary'
  local chunks = {
    { icon .. ' ', hl or (thread.resolved and 'DiffyThreadResolved' or text_hl) },
    { head, hl or text_hl },
  }
  local line = first and vim.split(first.body or '', '\n', { plain = true })[1] or ''
  local room = width - vim.fn.strdisplaywidth(icon .. ' ' .. head) - 2
  if line ~= '' and room >= 8 then
    table.insert(chunks, { ': ' .. highlight.truncate(line, room), hl or (thread.resolved and text_hl or 'Comment') })
  end
  return chunks
end

--- Threads covering the cursor line of the current window, if it's a diff
--- window: the "relevant" ones whose summaries stand out.
local function relevant_threads(session)
  local win = vim.api.nvim_get_current_win()
  local open = session.review and session.review._open
  if open and win == open.float then
    win = open.src
  end
  if win ~= session.wins.left and win ~= session.wins.right then
    return {}
  end
  return M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
end

--- (Re)draw the summary virt_lines recorded by `M.decorate`, highlighting
--- the open thread and the others covering the cursor line.
local function paint(session)
  local review = session.review
  if not (review and review._draw) then
    return
  end
  local ns = session_mod.namespace(session, 'review')
  local relevant = {}
  for _, t in ipairs(relevant_threads(session)) do
    relevant[t] = true
  end
  local open = review._open and review._open.thread
  for _, d in ipairs(review._draw) do
    if vim.api.nvim_buf_is_valid(d.buf) then
      local vlines = {}
      for _, t in ipairs(d.threads) do
        local hl = (t == open and 'DiffyThreadCurrent') or (relevant[t] and 'DiffyThreadRelevant') or nil
        table.insert(vlines, summary_chunks(t, d.width, hl))
      end
      for _ = #vlines + 1, d.n do
        table.insert(vlines, { { '', 'Normal' } })
      end
      d.id = vim.api.nvim_buf_set_extmark(d.buf, ns, d.line - 1, 0, { id = d.id, virt_lines = vlines })
    end
  end
end

--- Open any closed fold covering `lnum` in `win`: a thread placed on an
--- unchanged line (inside a diff fold) must stay visible, as github.com
--- adds a context hunk for it.
local function open_fold_if_closed(win, lnum)
  vim.api.nvim_win_call(win, function()
    if vim.fn.foldclosed(lnum) ~= -1 then
      vim.cmd(('%dfoldopen!'):format(lnum))
    end
  end)
end

--- The order threads are drawn in and `]t` walks, top to bottom: by the
--- line their summary hangs under (the range's last), then oldest first.
--- Total, so ties can't come out in a different order each time.
local function by_place(a, b)
  if a._place.end_line ~= b._place.end_line then
    return a._place.end_line < b._place.end_line
  end
  local sa, sb = model.started(a), model.started(b)
  if sa ~= sb then
    return sa < sb
  end
  if a._place.start_line ~= b._place.start_line then
    return a._place.start_line < b._place.start_line
  end
  return tostring(a.id) < tostring(b.id)
end

--- Which of `threads` (covering one line) to show first: the oldest one
--- still open, else the oldest.
local function first_thread(threads)
  local pick
  for _, t in ipairs(threads) do
    if not pick or (pick.resolved and not t.resolved) then
      pick = t
    elseif not pick.resolved == not t.resolved and model.started(t) < model.started(pick) then
      pick = t
    end
  end
  return pick
end

--- Float config over the diff window opposite `src_win`, its top level with
--- `line`'s screen row, so the commented code stays in view. `height` text
--- rows plus `edges` title/footer rows are kept inside that window. Falls
--- back to below the cursor when there's no other diff window.
local function beside(session, src_win, line, height, edges)
  local other = src_win == session.wins.left and session.wins.right
    or src_win == session.wins.right and session.wins.left
    or nil
  if not (other and vim.api.nvim_win_is_valid(other)) then
    local width = math.max(20, math.min(70, vim.o.columns - 4))
    return { relative = 'cursor', row = 1, col = 0, width = width, height = math.max(1, math.min(height, vim.o.lines - 4 - edges)) }
  end
  -- getwininfo's height leaves out the winbar, nvim_win_get_height doesn't
  local info = vim.fn.getwininfo(other)[1]
  local h = info.height
  height = math.max(1, math.min(height, h - edges))
  local pos = vim.fn.screenpos(src_win, line, 1)
  local text_top = vim.fn.screenpos(other, vim.fn.line('w0', other), 1).row
  local row = 0
  if pos.row > 0 and text_top > 0 then
    row = pos.row - text_top
  end
  row = math.max(0, math.min(row, h - height - edges))
  -- `bufpos` anchors col 0 at the first text column, past the gutter
  return { relative = 'win', win = other, bufpos = { vim.fn.line('w0', other) - 1, 0 }, row = row, col = 0, width = math.max(10, info.width - info.textoff - 2), height = height }
end

--- Make room under the framed float `top` (placed by `beside`) for another
--- framed float of up to `height` rows, shrinking and lifting `top` as
--- needed with its end kept in view. Returns that float's config, or nil
--- when `top` isn't anchored to a window.
local function stack_below(top, height)
  local t = vim.api.nvim_win_get_config(top)
  if t.relative ~= 'win' then
    return nil
  end
  local room = vim.fn.getwininfo(t.win)[1].height
  -- both frames, and at least three rows of `top`
  height = math.max(1, math.min(height, room - 7))
  local top_height = math.max(1, math.min(t.height, room - height - 4))
  local row = math.max(0, math.min(t.row, room - top_height - height - 4))
  vim.api.nvim_win_set_config(top, { relative = 'win', win = t.win, bufpos = t.bufpos, row = row, col = t.col, height = top_height, footer = '' })
  vim.api.nvim_win_call(top, function()
    vim.cmd('normal! G')
  end)
  return { relative = 'win', win = t.win, bufpos = t.bufpos, row = row + top_height + 2, col = t.col, width = t.width, height = height }
end

--- Hover: the cursor on a commented line of a diff window opens that line's
--- thread in a preview float (focus stays in the diff); off every thread,
--- the preview closes. Registered once per session.
local function setup_hover(session)
  local review = session.review
  if review._hover then
    return
  end
  review._hover = true
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = session.augroup,
    callback = function()
      if session.closed or not review.inline then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win ~= session.wins.left and win ~= session.wins.right then
        return
      end
      local threads = M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
      local open = review._open
      if #threads == 0 then
        if open then
          M.close_thread(session)
        else
          paint(session)
        end
      elseif open and open.src == win and vim.tbl_contains(threads, open.thread) then
        paint(session)
      else
        M.show_thread(session, first_thread(threads))
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = session.augroup,
    callback = function()
      local open = review._open
      local win = vim.api.nvim_get_current_win()
      if open and win ~= open.float and win ~= review._reply_win and win ~= session.wins.left and win ~= session.wins.right then
        M.close_thread(session)
      end
    end,
  })
end

--- Redraw every thread's sign + summary for the current file/pair (call
--- after `diffpair.show`), and the counterpart blank lines that keep the
--- two windows aligned. Placement comes from `review.backend.place`, cached
--- on `thread._place` (session-only, not persisted) for `M.threads_at`,
--- `M.next_thread` and `M.goto_thread`.
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
    review._draw = nil
    run.ready({ session = session.id, event = 'review' })
    return
  end

  local placed = { left = {}, right = {} }
  for _, thread in ipairs(review.threads) do
    thread._detached = nil
    thread._place = nil
    if thread.anchor.path == session.current_path and not (review.hide_resolved and thread.resolved) then
      local place = review.backend.place(session, thread)
      local win = place and wins[place.win]
      if win and vim.api.nvim_win_is_valid(win) then
        thread._place = place
        table.insert(placed[place.win], thread)
      end
    end
  end

  -- Summaries per side, keyed by screen row so both windows get the same
  -- number of virt_lines at each aligned row: a side's own summaries, padded
  -- with blanks up to the other side's count (never the sum of both).
  -- Without summaries, only the signs.
  local rows = {}
  for _, name in ipairs({ 'left', 'right' }) do
    local win = wins[name]
    if win and vim.api.nvim_win_is_valid(win) and #placed[name] > 0 then
      local buf = vim.api.nvim_win_get_buf(win)
      local line_rows = row_map(win)
      table.sort(placed[name], by_place)
      for _, t in ipairs(placed[name]) do
        vim.api.nvim_buf_set_extmark(buf, ns, t._place.start_line - 1, 0, {
          sign_text = t.resolved and '✓' or '\240\159\146\172',
          sign_hl_group = t.resolved and 'DiffyThreadResolved' or 'Comment',
          -- on a line shared with a resolved thread, the open one's sign shows
          priority = t.resolved and 4000 or 4096,
        })
        open_fold_if_closed(win, t._place.start_line)
        open_fold_if_closed(win, t._place.end_line)
        if review.summaries ~= false then
          local row = line_rows.row[t._place.end_line]
          rows[row] = rows[row] or {}
          rows[row][name] = rows[row][name] or { line = t._place.end_line, threads = {} }
          table.insert(rows[row][name].threads, t)
        end
      end
    end
  end
  local maps, draw = {}, {}
  for row, entry in pairs(rows) do
    local n = math.max(entry.left and #entry.left.threads or 0, entry.right and #entry.right.threads or 0)
    for _, name in ipairs({ 'left', 'right' }) do
      local win = wins[name]
      if win and vim.api.nvim_win_is_valid(win) then
        maps[name] = maps[name] or row_map(win)
        local e = entry[name]
        local line = e and e.line or maps[name].line[row]
        if line then
          open_fold_if_closed(win, line)
          table.insert(draw, {
            buf = vim.api.nvim_win_get_buf(win),
            line = line,
            n = n,
            threads = e and e.threads or {},
            width = require('diffy.highlight').text_width(win),
          })
        end
      end
    end
  end
  review._draw = draw
  setup_hover(session)
  if review.backend.avatar_url then
    local urls = {}
    for _, t in ipairs(review.threads) do
      for _, c in ipairs(t.comments) do
        local url = c.author and review.backend.avatar_url(c.author)
        if url then
          table.insert(urls, url)
        end
      end
    end
    avatar.request(urls, function() end)
  end

  -- keep the open thread open if it's still placed, re-anchored to its new spot
  local open = review._open
  if open then
    local focused = vim.api.nvim_get_current_win() == open.float
    if open.thread._place and vim.api.nvim_win_is_valid(session.wins[open.thread._place.win] or -1) then
      M.show_thread(session, open.thread, { focus = focused })
    else
      M.close_thread(session)
    end
  end
  paint(session)
  run.ready({ session = session.id, event = 'review' })
end

--- `<leader>dt`: toggle inline decorations without touching drafts.
function M.toggle_inline(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.inline = not review.inline
  if not review.inline then
    M.close_thread(session)
  end
  M.decorate(session)
end

--- `<leader>ds`: summaries under commented lines on/off; the signs stay,
--- and hovering a sign still previews its thread.
function M.toggle_summaries(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.summaries = review.summaries == false
  M.decorate(session)
end

--- `<leader>dr`: resolved threads on/off.
function M.toggle_resolved(session)
  local review = M.ensure(session)
  if not review then
    return
  end
  review.hide_resolved = not review.hide_resolved
  local n = 0
  for _, t in ipairs(review.threads) do
    if t.resolved then
      n = n + 1
    end
  end
  M.decorate(session)
  vim.notify(('diffy: %d resolved thread%s %s'):format(n, n == 1 and '' or 's', review.hide_resolved and 'hidden' or 'shown'))
end

--- Diff window and line where `thread` is drawn in the current view.
local function thread_anchor(session, thread)
  local p = thread._place
  if p and session.wins[p.win] and vim.api.nvim_win_is_valid(session.wins[p.win]) then
    return session.wins[p.win], p.end_line
  end
  return vim.api.nvim_get_current_win(), thread.anchor.end_line
end

-- ---------------------------------------------------------------------
-- comment cards: the thread float and `gP`

local CARD_WIDTH = 100
local CARD_HL = table.concat({
  'NormalFloat:DiffyThread',
  'FloatBorder:DiffyThreadBorder',
  'FloatTitle:DiffyThreadHeader',
  'FloatFooter:DiffyThreadBorder',
  'FoldColumn:DiffyThread',
  'EndOfBuffer:DiffyThread',
}, ',')

--- A card title, set in the top border like a tab.
local function card_title(text, width)
  return { { ' ' .. highlight.truncate(text, width - 4) .. ' ', 'DiffyThreadHeader' } }
end

--- A float drawn as a card: its own background inside a thin frame, wrapped text.
local function card_window(win)
  vim.wo[win].winhighlight = CARD_HL
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  -- a cut preview ends mid-paragraph: no `@@@` marker there
  vim.wo[win].fillchars = 'eob: ,lastline: '
end

--- "just now", "5 min ago", "3 hours ago", "yesterday", "4 days ago", then
--- the date.
local function ago(t)
  local e = model.epoch(t)
  if not e then
    return ''
  end
  local d = os.time() - e
  if d < 60 then
    return 'just now'
  elseif d < 3600 then
    return ('%d min ago'):format(math.floor(d / 60))
  elseif d < 86400 then
    local h = math.floor(d / 3600)
    return h == 1 and '1 hour ago' or ('%d hours ago'):format(h)
  elseif d < 2 * 86400 then
    return 'yesterday'
  elseif d < 7 * 86400 then
    return ('%d days ago'):format(math.floor(d / 86400))
  end
  local day = ('%s %d'):format(os.date('%b', e), tonumber(os.date('%d', e)))
  return os.date('%Y', e) == os.date('%Y') and day or ('%s, %s'):format(day, os.date('%Y', e))
end

--- A body as github.com shows it: without HTML comments, the web UI's CRs
--- or surrounding blank lines.
local function body_lines(body)
  local text = (body or ''):gsub('\r', ''):gsub('<!%-%-.-%-%->', '')
  local lines = vim.split(text, '\n', { plain = true })
  while #lines > 0 and vim.trim(lines[#lines]) == '' do
    table.remove(lines)
  end
  while #lines > 0 and vim.trim(lines[1]) == '' do
    table.remove(lines, 1)
  end
  return lines
end

local BADGES = {
  draft = { 'draft', 'DiffyThreadDraft' },
  pending = { 'pending', 'DiffyThreadPending' },
  sent = { 'sent', 'DiffyThreadSent' },
}

local function card_ns(session)
  return session_mod.namespace(session, 'review_card')
end

--- Header strip of one card: avatar slot (once drawable), author, age, and
--- right-aligned badges. Painted again when the avatar arrives.
local function paint_header(session, buf, head)
  local H = 'DiffyThreadHeader'
  local left = { { ' ', H } }
  if head.url and avatar.ready(head.url) then
    -- the image is one row tall, so a bit over two cells wide
    table.insert(left, { '   ', H })
    head.slot = true
  end
  table.insert(left, { head.name, { H, highlight.author(head.name), 'DiffyThreadAuthor' } })
  local when = ago(head.comment.created_at)
  if when ~= '' then
    table.insert(left, { '  ' .. when, { H, 'DiffyThreadTime' } })
  end
  head.left_id = vim.api.nvim_buf_set_extmark(buf, card_ns(session), head.row, 0, {
    id = head.left_id,
    virt_text = left,
    virt_text_pos = 'inline',
    hl_mode = 'combine',
    line_hl_group = H,
  })
  if #head.badges > 0 and not head.right_id then
    local right = {}
    for _, b in ipairs(head.badges) do
      table.insert(right, { b[1], { H, b[2] } })
      table.insert(right, { '  ', H })
    end
    right[#right][1] = ' '
    head.right_id = vim.api.nvim_buf_set_extmark(buf, card_ns(session), head.row, 0, {
      virt_text = right,
      virt_text_pos = 'right_align',
      hl_mode = 'combine',
    })
  end
end

--- Fill `buf` with one card per comment: a header strip, then the markdown
--- body. The header is virtual text on an empty line, so each body parses
--- as markdown on its own. `opts.people`: names and avatars (else every
--- comment is "You"); `opts.badges`: extra badges on the first header;
--- `opts.avatar_url(login)`. Returns the headers.
local function fill_cards(session, buf, comments, opts)
  local lines, heads, code, labels = {}, {}, {}, {}
  for i, c in ipairs(comments) do
    local badges = {}
    if BADGES[c.state] then
      table.insert(badges, BADGES[c.state])
    end
    if i == 1 then
      vim.list_extend(badges, opts.badges or {})
    end
    table.insert(heads, {
      row = #lines,
      comment = c,
      name = opts.people and (c.author or 'unknown') or 'You',
      badges = badges,
      url = opts.people and opts.avatar_url and c.author and opts.avatar_url(c.author) or nil,
    })
    table.insert(lines, '')
    local fence
    for _, l in ipairs(body_lines(c.body)) do
      local marker = l:match('^%s*(```+)') or l:match('^%s*(~~~+)')
      if fence then
        if marker and marker:sub(1, 1) == fence.char and #marker >= fence.len and vim.trim(l):match('^[`~]+$') then
          if fence.label then
            fence.label.empty = fence.empty
          end
          fence = nil
        else
          table.insert(code, { row = #lines, suggestion = fence.label ~= nil })
          fence.empty = false
        end
      elseif marker then
        local info = vim.trim(vim.trim(l):sub(#marker + 1))
        fence = { char = marker:sub(1, 1), len = #marker, empty = true }
        if info == 'suggestion' then
          -- under the line before the fence: fence lines are concealed
          fence.label = { row = #lines - 1 }
          table.insert(labels, fence.label)
        end
      end
      -- one cell of padding; markdown allows up to three before any block
      table.insert(lines, ' ' .. l)
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ns = card_ns(session)
  for _, h in ipairs(heads) do
    paint_header(session, buf, h)
  end
  for _, cl in ipairs(code) do
    vim.api.nvim_buf_set_extmark(buf, ns, cl.row, 0, {
      virt_text = { { '▎', cl.suggestion and 'DiffyThreadSuggestion' or 'DiffyThreadCodeBar' } },
      virt_text_pos = 'overlay',
    })
  end
  for _, lb in ipairs(labels) do
    local text = lb.empty and ' Suggested change: remove these lines' or ' Suggested change'
    vim.api.nvim_buf_set_extmark(buf, ns, lb.row, 0, { virt_lines = { { { text, 'DiffyThreadSuggestion' } } } })
  end
  pcall(vim.treesitter.start, buf, 'markdown')
  return heads
end

--- Draw the avatars of the card window (`review._cards`) where its headers
--- are on screen; clear them once it's gone or its tab isn't current.
local function draw_avatars(session)
  local cards = session.review and session.review._cards
  if not (cards and vim.api.nvim_win_is_valid(cards.win)) or vim.api.nvim_get_current_tabpage() ~= session.tab then
    avatar.clear(session.id)
    return
  end
  -- a float anchored to a buffer line only moves when its window scrolls on
  -- redraw: measure after it
  vim.cmd('redraw')
  local items = {}
  for _, h in ipairs(cards.heads) do
    if h.slot then
      local pos = vim.fn.screenpos(cards.win, h.row + 1, 1)
      if pos.row > 0 then
        -- after the header's padding cell
        table.insert(items, { url = h.url, row = pos.row, col = pos.col + 1 })
      end
    end
  end
  avatar.place(session.id, items)
end

local function schedule_avatars(session)
  vim.schedule(function()
    if not session.closed then
      draw_avatars(session)
    end
  end)
end

--- Make `win` (showing `buf`, filled by `fill_cards`) the card window whose
--- avatars are drawn, fetching the ones not cached yet.
local function show_avatars(session, win, buf, heads)
  local review = session.review
  review._cards = { win = win, heads = heads }
  if not review._avatar_track then
    review._avatar_track = true
    -- images sit at screen cells: follow the window, leave with the tab
    vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'VimResized', 'TabEnter' }, {
      group = session.augroup,
      callback = function()
        schedule_avatars(session)
      end,
    })
    vim.api.nvim_create_autocmd('TabLeave', {
      group = session.augroup,
      callback = function()
        avatar.clear(session.id)
      end,
    })
  end
  local urls = {}
  for _, h in ipairs(heads) do
    if h.url then
      table.insert(urls, h.url)
    end
  end
  avatar.request(urls, function()
    local cards = review._cards
    if not (cards and cards.win == win and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    for _, h in ipairs(heads) do
      if not h.slot and h.url and avatar.ready(h.url) then
        paint_header(session, buf, h)
      end
    end
    schedule_avatars(session)
  end)
  schedule_avatars(session)
end

--- Stop drawing avatars for `win` (any card window when nil).
local function hide_avatars(session, win)
  local review = session.review
  if review and review._cards and (not win or review._cards.win == win) then
    review._cards = nil
    avatar.clear(session.id)
  end
end

--- Key hints for a card's footer, `{ {key, label, drop = n}, ... }`. Hints
--- with a `drop` rank go, lowest first, until the rest fit `width`.
local function key_hints(keys, width)
  local shown = vim.list_extend({}, keys)
  local function size()
    local n = 2
    for i, k in ipairs(shown) do
      n = n + vim.fn.strdisplaywidth(k[1] .. ' ' .. k[2]) + (i < #shown and 3 or 0)
    end
    return n
  end
  while width and size() > width do
    local worst
    for i, k in ipairs(shown) do
      if k.drop and (not worst or k.drop < shown[worst].drop) then
        worst = i
      end
    end
    if not worst then
      break
    end
    table.remove(shown, worst)
  end
  -- title/footer chunks don't take the border's background: stack it in
  local chunks = { { ' ', 'DiffyThread' } }
  for i, k in ipairs(shown) do
    table.insert(chunks, { k[1], { 'DiffyThread', 'DiffyThreadKey' } })
    table.insert(chunks, { ' ' .. k[2] .. (i < #shown and '   ' or ' '), { 'DiffyThread', 'DiffyThreadHint' } })
  end
  return chunks
end

-- ---------------------------------------------------------------------
-- compose float (`gc`)

--- Open a floating markdown compose buffer over the diff window opposite
--- `anchor_win`, level with `anchor_line`, so the code being commented stays
--- visible; with `opts.above` (the thread float), right under that float
--- instead, so the thread stays in view. `<C-s>`/`:w` calls `on_save(lines)`
--- and closes; `q` cancels. `opts.on_close()` runs once it's closed, either
--- way. `opts.prefill` seeds the buffer (editing a draft).
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

  local cfg = opts.above and vim.api.nvim_win_is_valid(opts.above) and stack_below(opts.above, 8)
  if cfg then
    -- the thread moved and scrolled: its avatars follow
    schedule_avatars(session)
  else
    cfg = beside(session, anchor_win, anchor_line, 8, 2)
  end
  cfg.width = math.min(cfg.width, CARD_WIDTH)
  cfg.style = 'minimal'
  cfg.border = 'rounded'
  cfg.zindex = 200
  cfg.title = card_title(opts.title or 'New comment', cfg.width)
  local keys = { { '<C-s>', 'save' }, { 'q', 'cancel' } }
  if opts.suggestion then
    table.insert(keys, { '<C-g>s', 'suggest a change', drop = 1 })
  end
  cfg.footer = key_hints(keys, cfg.width)
  local win = vim.api.nvim_open_win(buf, false, cfg)
  -- before focusing it: entering it mustn't close the thread above
  session.review._reply_win = opts.above and win or nil
  vim.api.nvim_set_current_win(win)
  card_window(win)
  vim.wo[win].foldcolumn = '1'

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    vim.cmd('stopinsert')
    if session.review._reply_win == win then
      session.review._reply_win = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if opts.on_close and not session.closed then
      opts.on_close()
    end
  end
  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    -- `:q` and friends: deferred, closing windows from WinClosed races
    callback = function()
      vim.schedule(close)
    end,
  })

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
  if not session.current_path or not vim.w[win].diffy_path then
    vim.notify('diffy: no file on this side to comment on', vim.log.levels.WARN)
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
  end, {
    suggestion = suggestion,
    title = start_line == end_line and ('Comment on line %d'):format(start_line) or ('Comment on lines %d–%d'):format(start_line, end_line),
  })
end

--- Reply to an existing `thread`: appends a new comment on save. From the
--- thread float, the reply box opens under it and the thread stays in
--- view; closing the box (saved or not) goes back into the thread.
function M.reply(session, thread)
  local review = session.review
  if type(review.backend.save) ~= 'function' then
    vim.notify(('diffy: replying isn\'t implemented yet for %s'):format(review.backend.name), vim.log.levels.WARN)
    return
  end
  local backend = review.backend
  local open = review._open
  local above = open and open.thread == thread and vim.api.nvim_win_is_valid(open.float) and open.float or nil
  local win, line = thread_anchor(session, thread)
  M.open_compose(session, win, line, function(body)
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
  end, {
    title = backend.capabilities.people and thread.comments[1] and ('Reply to %s'):format(thread.comments[1].author) or 'Reply',
    above = above,
    on_close = above and function()
      M.show_thread(session, thread, { focus = true })
    end,
  })
end

--- Edit `comment` (must be `state == 'draft'`, checked by the caller) of
--- `thread`, replacing its body on save.
function M.edit_comment(session, thread, comment)
  local review = session.review
  local backend = review.backend
  local win, line = thread_anchor(session, thread)
  M.open_compose(session, win, line, function(body)
    comment.body = table.concat(body, '\n')
    backend.save(session, review.branch, review.threads)
    M.decorate(session)
  end, { prefill = vim.split(comment.body, '\n', { plain = true }), title = 'Edit draft' })
end

-- ---------------------------------------------------------------------
-- thread float (`K`/`<CR>`)

--- Threads whose placed range covers `lnum` of `win` (one of the session's
--- diff windows), in the order they're drawn.
function M.threads_at(session, win, lnum)
  local review = session.review
  local out = {}
  if not review then
    return out
  end
  for _, t in ipairs(review.threads) do
    if t._place and session.wins[t._place.win] == win and lnum >= t._place.start_line and lnum <= t._place.end_line then
      table.insert(out, t)
    end
  end
  table.sort(out, by_place)
  return out
end

local function range_ns(session)
  return session_mod.namespace(session, 'review_range')
end

--- Close the thread float and drop its range highlight, without repainting.
local function close_float(session)
  local review = session.review
  local open = review and review._open
  if not open then
    return
  end
  review._open = nil
  hide_avatars(session, open.float)
  if vim.api.nvim_win_is_valid(open.float) then
    pcall(vim.api.nvim_win_close, open.float, true)
  end
  if vim.api.nvim_win_is_valid(open.src) then
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(open.src), range_ns(session), 0, -1)
  end
end

--- Close the open thread (if any); focus goes back to its diff window when
--- it was in the float.
function M.close_thread(session)
  local review = session.review
  local open = review and review._open
  if not open then
    return
  end
  local was_focused = vim.api.nvim_get_current_win() == open.float
  close_float(session)
  if was_focused and vim.api.nvim_win_is_valid(open.src) then
    vim.api.nvim_set_current_win(open.src)
  end
  paint(session)
end

--- Threads of `win`'s side in the order `]t`/`[t` walk them.
local function side_threads(session, win)
  local side = M.side_of(session, win)
  local out = {}
  for _, t in ipairs(session.review and session.review.threads or {}) do
    if t._place and t._place.win == side then
      table.insert(out, t)
    end
  end
  table.sort(out, by_place)
  return out
end

--- Fill `buf` with `thread` as comment cards (as in the thread float), for
--- any window showing it. `opts.avatars` reserves room for the avatars.
--- Returns the headers.
function M.render_thread(session, buf, thread, opts)
  local backend = session.review.backend
  local badges = {}
  if thread.outdated then
    table.insert(badges, { 'outdated', 'DiffyThreadOutdated' })
  end
  if thread.resolved then
    table.insert(badges, { '✓ resolved', 'DiffyThreadResolved' })
  end
  return fill_cards(session, buf, thread.comments, {
    people = backend.capabilities.people,
    badges = badges,
    avatar_url = opts and opts.avatars and backend.avatar_url or nil,
  })
end

--- Show `thread` alone in the thread float: over the other diff
--- window, level with the thread, with its code range highlighted in its
--- own window. `opts.focus` moves the cursor into it (`K`); otherwise it's
--- a preview and focus stays in the diff.
function M.show_thread(session, thread, opts)
  opts = opts or {}
  local review = session.review
  local backend = review.backend
  local place = thread._place
  local src = place and session.wins[place.win]
  if not (src and vim.api.nvim_win_is_valid(src)) then
    return
  end
  close_float(session)

  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  local seq = session._review_buf_seq
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/thread/%d'):format(session.id, seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'thread_' .. seq, buf)
  local heads = M.render_thread(session, buf, thread, { avatars = true })

  local order = side_threads(session, src)
  local idx = 1
  for i, t in ipairs(order) do
    if t == thread then
      idx = i
    end
  end
  local edges = 2
  local cfg = beside(session, src, place.start_line, vim.api.nvim_buf_line_count(buf), edges)
  cfg.width = math.min(cfg.width, CARD_WIDTH)
  cfg.style = 'minimal'
  cfg.zindex = 50
  if opts.focus then
    local keys = {}
    if type(backend.save) == 'function' then
      table.insert(keys, { 'r', 'reply' })
    end
    local last = thread.comments[#thread.comments]
    if last and last.state == 'draft' then
      table.insert(keys, { 'e', 'edit', drop = 3 })
      table.insert(keys, { 'dd', 'delete', drop = 2 })
    end
    if backend.capabilities.resolve then
      table.insert(keys, { 'x', thread.resolved and 'unresolve' or 'resolve', drop = 4 })
    end
    if #order > 1 then
      table.insert(keys, { ']t [t', ('%d/%d'):format(idx, #order), drop = 1 })
    end
    table.insert(keys, { 'q', 'close' })
    cfg.footer = key_hints(keys, cfg.width)
  end
  cfg.border = 'rounded'
  local fwin = vim.api.nvim_open_win(buf, opts.focus or false, cfg)
  card_window(fwin)
  vim.wo[fwin].conceallevel = 2
  vim.wo[fwin].concealcursor = 'nc'
  -- the real height once wrapping, concealed fences and labels are known
  local rows = vim.api.nvim_win_text_height(fwin, {}).all
  local fit_cfg = {}
  if not opts.focus then
    -- a hover shouldn't bury the other side: cut long previews
    local room = cfg.win and vim.fn.getwininfo(cfg.win)[1].height or vim.o.lines
    local cap = math.max(6, math.floor(room / 2))
    if rows > cap then
      fit_cfg.footer = key_hints({ { 'K', ('%d more lines'):format(rows - cap) } }, cfg.width)
      rows = cap
    end
  end
  local fit = beside(session, src, place.start_line, rows, edges)
  vim.api.nvim_win_set_config(fwin, vim.tbl_extend('force', fit_cfg, {
    relative = fit.relative,
    win = fit.win,
    bufpos = fit.bufpos,
    row = fit.row,
    col = fit.col,
    width = math.min(fit.width, CARD_WIDTH),
    height = fit.height,
  }))
  review._open = { thread = thread, src = src, float = fwin, buf = buf }
  if backend.capabilities.people then
    show_avatars(session, fwin, buf, heads)
  end

  local rns = range_ns(session)
  pcall(vim.api.nvim__ns_set, rns, { wins = { src } })
  local src_buf = vim.api.nvim_win_get_buf(src)
  for l = place.start_line, math.min(place.end_line, vim.api.nvim_buf_line_count(src_buf)) do
    -- on the number column: DiffAdd/DiffText would hide a line_hl_group
    vim.api.nvim_buf_set_extmark(src_buf, rns, l - 1, 0, { number_hl_group = 'DiffyThreadRange', priority = 250 })
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(fwin),
    once = true,
    callback = function()
      if review._open and review._open.float == fwin then
        close_float(session)
        vim.schedule(function()
          if not session.closed then
            paint(session)
          end
        end)
      end
    end,
  })

  local map = session_mod.map
  map(session, 'n', 'q', function()
    M.close_thread(session)
  end, { buffer = buf, desc = 'close thread' })
  map(session, 'n', ']t', function()
    M.next_thread(session, 1)
  end, { buffer = buf, desc = 'next thread' })
  map(session, 'n', '[t', function()
    M.next_thread(session, -1)
  end, { buffer = buf, desc = 'previous thread' })
  map(session, 'n', 'r', function()
    M.reply(session, thread)
  end, { buffer = buf, desc = 'reply' })
  map(session, 'n', 'e', function()
    local last = thread.comments[#thread.comments]
    if not last or last.state ~= 'draft' then
      vim.notify('diffy: only a draft comment can be edited', vim.log.levels.WARN)
      return
    end
    M.close_thread(session)
    M.edit_comment(session, thread, last)
  end, { buffer = buf, desc = 'edit draft' })
  map(session, 'n', 'dd', function()
    local last = thread.comments[#thread.comments]
    if not last or last.state ~= 'draft' then
      vim.notify('diffy: only a draft comment can be deleted', vim.log.levels.WARN)
      return
    end
    M.close_thread(session)
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
  end, { buffer = buf, desc = 'delete draft' })
  if backend.capabilities.resolve then
    map(session, 'n', 'x', function()
      if type(backend.resolve_thread) == 'function' then
        backend.resolve_thread(session, thread, not thread.resolved, function() end)
        return
      end
      thread.resolved = not thread.resolved
      backend.save(session, review.branch, review.threads)
      M.decorate(session)
    end, { buffer = buf, desc = 'resolve/unresolve thread' })
  end

  paint(session)
  run.ready({ session = session.id, event = 'thread' })
end

--- `K`/`<CR>`: enter the thread at the cursor line (the one previewed, or
--- the first covering the line). No-op off every thread.
function M.open_thread(session)
  local win = vim.api.nvim_get_current_win()
  local threads = M.threads_at(session, win, vim.api.nvim_win_get_cursor(win)[1])
  if #threads == 0 then
    return
  end
  local open = session.review._open
  local thread = (open and open.src == win and vim.tbl_contains(threads, open.thread)) and open.thread or first_thread(threads)
  M.show_thread(session, thread, { focus = true })
end

--- Jump to `thread` from anywhere in the session: open its file in the
--- diff, put the cursor on it and enter it. Shows what it takes to see it
--- (resolved threads, inline comments) and says why when it can't be
--- shown in the current selection.
function M.goto_thread(session, thread)
  local review = session.review
  local redraw = false
  if not review.inline then
    review.inline, redraw = true, true
  end
  if thread.resolved and review.hide_resolved then
    review.hide_resolved, redraw = false, true
  end
  if session.current_path ~= thread.anchor.path then
    if not require('diffy.panels.tree').open_path(session, thread.anchor.path) then
      vim.notify(('diffy: %s has no changes in this selection'):format(thread.anchor.path), vim.log.levels.WARN)
      return
    end
  elseif redraw then
    M.decorate(session)
  end
  local place = thread._place
  local win = place and session.wins[place.win]
  if not (win and vim.api.nvim_win_is_valid(win)) then
    local where = ''
    if review.backend.visible_in then
      local visible = review.backend.visible_in(session, thread)
      where = #visible > 0 and (' (it is in: %s)'):format(table.concat(visible, ', ')) or ''
    elseif thread._detached then
      where = ': its lines were changed or deleted'
    end
    vim.notify(('diffy: this thread isn\'t in the current view%s'):format(where), vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { place.start_line, 0 })
  M.show_thread(session, thread, { focus = true })
end

--- `]t`/`[t` (from a diff window or the thread float): open the next or
--- previous thread of that window, one at a time, stacked threads included,
--- moving the diff cursor to it. No-op past the first/last one.
function M.next_thread(session, delta)
  local review = session.review
  if not review then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local open = review._open
  local in_float = open and cur == open.float
  local win = in_float and open.src or cur
  if not M.side_of(session, win) then
    return
  end
  local order = side_threads(session, win)
  local target
  if open and open.src == win then
    for i, t in ipairs(order) do
      if t == open.thread then
        target = order[i + delta]
      end
    end
  else
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    if delta > 0 then
      for _, t in ipairs(order) do
        if t._place.start_line > lnum then
          target = t
          break
        end
      end
    else
      for i = #order, 1, -1 do
        if order[i]._place.start_line < lnum then
          target = order[i]
          break
        end
      end
    end
  end
  if not target then
    return
  end
  vim.api.nvim_win_set_cursor(win, { target._place.start_line, 0 })
  M.show_thread(session, target, { focus = in_float })
end

--- One-time keymap setup for a diff-window buffer (on every left/right
--- swap): `gc`, `K`/`<CR>`, `]t`/`[t`, the display toggles, the thread
--- lists (`<leader>dc`/`df`), `gP`. These apply on any diff buffer, real
--- file or blob alike.
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
  map(session, 'n', '<leader>ds', function()
    M.toggle_summaries(session)
  end, { buffer = buf, desc = 'review: toggle thread summaries (signs stay)' })
  map(session, 'n', '<leader>dr', function()
    M.toggle_resolved(session)
  end, { buffer = buf, desc = 'review: toggle resolved threads' })
  map(session, 'n', '<leader>dc', function()
    require('diffy.review.threads').open(session, {})
  end, { buffer = buf, desc = 'review: every thread of the review' })
  map(session, 'n', '<leader>df', function()
    require('diffy.review.threads').open(session, { 'file' })
  end, { buffer = buf, desc = 'review: threads of this file' })
  map(session, 'n', 'gP', function()
    M.open_pr_description(session)
  end, { buffer = buf, desc = 'review: PR description' })
end

-- ---------------------------------------------------------------------
-- `gP`: GitHub PR description + conversation comments

--- `gP`: read-only float with the PR's description and conversation
--- (`review.pr`), one card per message. Only available for a `:Diffy pr`
--- session.
function M.open_pr_description(session)
  local review = session.review
  if not review or review.backend.name ~= 'github' or not review.pr then
    vim.notify('diffy: `gP` is only available in :Diffy pr', vim.log.levels.WARN)
    return
  end
  local pr = review.pr
  local messages = {
    { author = pr.author, created_at = pr.created_at, body = vim.trim(pr.body or '') ~= '' and pr.body or '_No description provided._' },
  }
  vim.list_extend(messages, pr.conversation)

  local buf = vim.api.nvim_create_buf(false, true)
  session._review_buf_seq = (session._review_buf_seq or 0) + 1
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/pr/%d'):format(session.id, session._review_buf_seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  session_mod.register_buffer(session, 'pr_' .. session._review_buf_seq, buf)
  local heads = fill_cards(session, buf, messages, { people = true, avatar_url = review.backend.avatar_url })

  local width = math.max(40, math.min(CARD_WIDTH, vim.o.columns - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = 'minimal',
    border = 'rounded',
    title = card_title(('#%d %s'):format(pr.number, pr.title or ''), width),
    footer = key_hints({ { 'q', 'close' } }, width),
    zindex = 200,
  })
  card_window(win)
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nc'
  local height = math.max(1, math.min(vim.api.nvim_win_text_height(win, {}).all, vim.o.lines - 6))
  vim.api.nvim_win_set_config(win, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height - 2) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
  })
  show_avatars(session, win, buf, heads)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      hide_avatars(session, win)
    end,
  })
  session_mod.map(session, 'n', 'q', function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end, { buffer = buf, desc = 'close PR description' })
end

--- `:Diffy review submit`'s body float, centered since a review body isn't
--- anchored to any line. `<C-s>`/`:w` calls `on_save(body)` (a single
--- string, blank if the buffer was left empty) and closes; `q` cancels
--- (`on_save` never runs).
function M.open_submit_body(session, on_save, title)
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
    title = card_title(title or 'Submit review', width),
    footer = key_hints({ { '<C-s>', 'submit' }, { 'q', 'cancel' } }, width),
    zindex = 200,
  })
  card_window(win)
  vim.wo[win].foldcolumn = '1'

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

return M
