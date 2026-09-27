-- `:Diffy threads`: the review's threads, all of them, the selection's or
-- one file's. In snacks.nvim's picker when it's installed (fuzzy over every
-- comment, previewed with the code they're on, <CR> jumps into it), else the
-- quickfix list.
local model = require('diffy.review.model')
local ui = require('diffy.review.ui')
local highlight = require('diffy.highlight')
local session_mod = require('diffy.session')

local M = {}

-- rows of code in a preview; the middle of a longer range is cut
local SNIPPET_ROWS = 14
-- quickfix text keeps this many chars of a thread's first line
local QF_FIRST_LINE_MAX = 60

local function state_of(t)
  return t.resolved and 'resolved' or (t.outdated and 'outdated') or (t._detached and 'detached') or 'open'
end

local function first_line(t)
  return t.comments[1] and vim.split(t.comments[1].body or '', '\n', { plain = true })[1] or ''
end

--- Entries `{ thread, line }` matching `filters` (`author`, `state`,
--- `review`, `path`), by file, then line, then age. With `filters.view`,
--- only threads shown in the current selection, at the line shown there.
local function collect(session, filters)
  local review = session.review
  local files = {}
  for _, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' then
      files[row.entry.path] = true
    end
  end
  local out = {}
  for _, t in ipairs(review.threads) do
    local author = t.comments[1] and t.comments[1].author or ''
    local line = t.anchor.start_line
    local keep = (not filters.author or filters.author == author)
      and (not filters.state or filters.state == state_of(t))
      and (not filters.review or filters.review == (t.review_id or ''))
      and (not filters.path or filters.path == t.anchor.path)
    if keep and filters.view then
      local place = files[t.anchor.path] and review.backend.view_place(session, t)
      keep = place ~= nil
      line = place and place.start_line
    end
    if keep then
      table.insert(out, { thread = t, line = line })
    end
  end
  table.sort(out, function(a, b)
    if a.thread.anchor.path ~= b.thread.anchor.path then
      return a.thread.anchor.path < b.thread.anchor.path
    end
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    return model.started(a.thread) < model.started(b.thread)
  end)
  return out
end

local function to_quickfix(session, entries, title)
  local review = session.review
  local items = {}
  for _, e in ipairs(entries) do
    local t = e.thread
    local first = first_line(t)
    if vim.fn.strchars(first) > QF_FIRST_LINE_MAX then
      first = vim.fn.strcharpart(first, 0, QF_FIRST_LINE_MAX - 1) .. '…'
    end
    local text = ('[%s] %s: %s'):format(state_of(t), model.summary_text(t), first)
    if review.backend.visible_in then
      local visible = review.backend.visible_in(session, t)
      text = text .. (' (%s)'):format(#visible > 0 and table.concat(visible, ', ') or 'nowhere inline')
    end
    table.insert(items, {
      filename = session.root .. '/' .. t.anchor.path,
      lnum = math.max(1, e.line or 1),
      text = text,
    })
  end
  vim.fn.setqflist({}, ' ', { title = title, items = items })
  vim.cmd('copen')
end

-- two cells each, so the columns after them line up
local ICONS = {
  open = { model.COMMENT_ICON, 'DiffyThreadSummary' },
  resolved = { '✓ ', 'DiffyThreadResolved' },
  outdated = { '◌ ', 'DiffyThreadOutdated' },
  detached = { '✗ ', 'DiffyThreadOutdated' },
}

--- A thread's picker columns: state, location, author (+replies), what
--- isn't published yet, first line.
local function columns(session, e, with_path)
  local t = e.thread
  local first = t.comments[1]
  local line = e.line and tostring(e.line) or nil
  local loc
  if with_path then
    loc = { { t.anchor.path, 'DiffyDirectory' }, { line and (':' .. line) or ' (file)', 'LineNr' } }
  else
    loc = { { line and ('line ' .. line) or 'file', 'LineNr' } }
  end
  local badges = {}
  local seen = {}
  for _, c in ipairs(t.comments) do
    if (c.state == 'draft' or c.state == 'pending') and not seen[c.state] then
      seen[c.state] = true
      table.insert(badges, { c.state, c.state == 'draft' and 'DiffyThreadDraft' or 'DiffyThreadPending' })
    end
  end
  return {
    state = state_of(t),
    loc = loc,
    author = session.review.backend.capabilities.people and (first and first.author or 'unknown') or 'You',
    replies = #t.comments > 1 and (' +%d'):format(#t.comments - 1) or '',
    badges = badges,
    text = first_line(t),
  }
end

local function width_of(chunks)
  local n = 0
  for _, c in ipairs(chunks) do
    n = n + vim.fn.strdisplaywidth(c[1])
  end
  return n
end

-- badges are space-separated
local function badges_width(badges)
  local n = 0
  for j, badge in ipairs(badges) do
    n = n + #badge[1] + (j > 1 and 1 or 0)
  end
  return n
end

--- Picker rows with every column padded to its widest cell, so the first
--- lines start at the same column.
local function rows(session, entries, with_path)
  local cols, w = {}, { loc = 0, who = 0, badges = 0 }
  for i, e in ipairs(entries) do
    local c = columns(session, e, with_path)
    cols[i] = c
    w.loc = math.max(w.loc, width_of(c.loc))
    w.who = math.max(w.who, vim.fn.strdisplaywidth(c.author .. c.replies))
    w.badges = math.max(w.badges, badges_width(c.badges))
  end
  local out = {}
  for i, c in ipairs(cols) do
    local chunks = { { ICONS[c.state][1] .. ' ', ICONS[c.state][2] } }
    vim.list_extend(chunks, c.loc)
    table.insert(chunks, { (' '):rep(w.loc - width_of(c.loc) + 2) })
    table.insert(chunks, { c.author, highlight.author(c.author) })
    table.insert(chunks, { c.replies, 'DiffyThreadTime' })
    table.insert(chunks, { (' '):rep(w.who - vim.fn.strdisplaywidth(c.author .. c.replies) + 2) })
    if w.badges > 0 then
      for j, badge in ipairs(c.badges) do
        table.insert(chunks, { (j > 1 and ' ' or '') .. badge[1], badge[2] })
      end
      table.insert(chunks, { (' '):rep(w.badges - badges_width(c.badges) + 2) })
    end
    table.insert(chunks, { c.text, c.state == 'open' and 'Normal' or 'DiffyThreadSummaryResolved' })
    out[i] = chunks
  end
  return out
end

--- The code a thread is on, as a fenced block in the file's language (the
--- preview's markdown highlighting injects it), lines cut to `width`.
--- Returns the lines and, per 1-based line, its snippet row.
local function code_block(t, width)
  local snippet = model.snippet(t, SNIPPET_ROWS)
  if not snippet then
    return nil
  end
  -- a fence longer than any backtick run in the code
  local fence = 3
  for _, r in ipairs(snippet) do
    for run in (r.text or ''):gmatch('`+') do
      fence = math.max(fence, #run + 1)
    end
  end
  fence = ('`'):rep(fence)
  local lines, at = { fence .. (vim.filetype.match({ filename = t.anchor.path }) or '') }, {}
  for _, r in ipairs(snippet) do
    if r.gap then
      at[#lines] = at[#lines] or {}
      at[#lines].gap = r.gap
    else
      table.insert(lines, highlight.truncate(r.text, width))
      at[#lines] = { row = r }
    end
  end
  table.insert(lines, fence)
  table.insert(lines, '')
  return lines, at
end

local function preview(session, ctx)
  local t = ctx.item.thread
  ctx.preview:reset()
  ctx.preview:minimal()
  -- '%5s' line number + 2 spaces, see the virt_text below
  local gutter = 7
  local lines, at = code_block(t, math.max(20, vim.api.nvim_win_get_width(ctx.win) - gutter - 1))
  ui.render_thread(session, ctx.buf, t, { preamble = lines })
  local ns = session_mod.namespace(session, 'review_snippet')
  for i, a in pairs(at or {}) do
    if a.row then
      local r = a.row
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, i - 1, 0, {
        -- the commented lines' numbers stand out, as in the diff
        virt_text = { { ('%5s'):format(r.n or ''), r.range and 'DiffyThreadRange' or 'LineNr' }, { '  ' } },
        virt_text_pos = 'inline',
        line_hl_group = r.kind == 'add' and 'DiffAdd' or r.kind == 'del' and 'DiffDelete' or nil,
      })
    end
    if a.gap then
      vim.api.nvim_buf_set_extmark(ctx.buf, ns, i - 1, 0, {
        virt_lines = { { { ('%s⋯ %d more line%s'):format((' '):rep(gutter), a.gap, a.gap == 1 and '' or 's'), 'Comment' } } },
      })
    end
  end
  ctx.preview:wo({ wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = 'nvic' })
  ctx.preview:set_title(ctx.item.line and ('%s:%d'):format(t.anchor.path, ctx.item.line) or t.anchor.path)
end

local function pick(snacks, session, entries, title, with_path)
  local chunks = rows(session, entries, with_path)
  local items = {}
  for i, e in ipairs(entries) do
    local t = e.thread
    -- matched on everything a reader could remember a thread by
    local words = { t.anchor.path }
    for _, c in ipairs(t.comments) do
      table.insert(words, c.author or '')
      table.insert(words, c.body or '')
    end
    table.insert(items, {
      text = table.concat(words, ' '),
      thread = t,
      line = e.line,
      chunks = chunks[i],
      -- for snacks' own actions, e.g. sending the list to the quickfix
      file = session.root .. '/' .. t.anchor.path,
      pos = { math.max(1, e.line or 1), 0 },
    })
  end
  snacks.picker.pick({
    title = title,
    items = items,
    format = function(item)
      return item.chunks
    end,
    preview = function(ctx)
      preview(session, ctx)
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          if not session.closed then
            ui.goto_thread(session, item.thread)
          end
        end)
      end
    end,
  })
end

--- `:Diffy threads [file|selection] [author=<name>] [state=<open|resolved|
--- outdated|detached>] [review=<id>]`: `selection` keeps the threads shown
--- in the selected range, `file` those of the file in the diff; without
--- either, every thread of the review. For GitHub, the quickfix text also
--- says which commits show each thread.
function M.open(session, args)
  local review = ui.ensure(session)
  if not review then
    vim.notify('diffy: review is only available in :Diffy, :Diffy branch and :Diffy pr', vim.log.levels.WARN)
    return
  end
  local filters = {}
  for _, a in ipairs(args or {}) do
    local k, v = a:match('^(%a+)=(.*)$')
    if k then
      filters[k] = v
    elseif a == 'selection' then
      filters.view = true
    elseif a == 'file' then
      if not session.current_path then
        vim.notify('diffy: no file shown in the diff', vim.log.levels.WARN)
        return
      end
      filters.view, filters.path = true, session.current_path
    end
  end
  local entries = collect(session, filters)
  local title = filters.path and ('Threads in ' .. filters.path)
    or filters.view and 'Threads in the selection'
    or 'Review threads'
  local ok, snacks = pcall(require, 'snacks')
  if ok and type(snacks) == 'table' and snacks.picker then
    if #entries == 0 then
      vim.notify('diffy: no ' .. title:lower())
      return
    end
    pick(snacks, session, entries, title, not filters.path)
  else
    to_quickfix(session, entries, title)
  end
end

return M
