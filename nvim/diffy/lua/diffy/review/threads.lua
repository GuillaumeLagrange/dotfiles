-- `:Diffy threads`: the review's threads, all of them or one file's. In
-- snacks.nvim's picker when it's installed (fuzzy over every comment, the
-- thread previewed as in the float, <CR> jumps into it), else the quickfix
-- list.
local model = require('diffy.review.model')
local ui = require('diffy.review.ui')
local highlight = require('diffy.highlight')

local M = {}

local function state_of(t)
  return t.resolved and 'resolved' or (t.outdated and 'outdated') or (t._detached and 'detached') or 'open'
end

local function first_line(t)
  return t.comments[1] and vim.split(t.comments[1].body or '', '\n', { plain = true })[1] or ''
end

--- Threads matching `filters` (`author`, `state`, `review`, `path`), by
--- file, then line, then age.
local function collect(review, filters)
  local out = {}
  for _, t in ipairs(review.threads) do
    local author = t.comments[1] and t.comments[1].author or ''
    if
      (not filters.author or filters.author == author)
      and (not filters.state or filters.state == state_of(t))
      and (not filters.review or filters.review == (t.review_id or ''))
      and (not filters.path or filters.path == t.anchor.path)
    then
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b)
    if a.anchor.path ~= b.anchor.path then
      return a.anchor.path < b.anchor.path
    end
    local la, lb = a.anchor.start_line or 0, b.anchor.start_line or 0
    if la ~= lb then
      return la < lb
    end
    return model.started(a) < model.started(b)
  end)
  return out
end

local function to_quickfix(session, threads, title)
  local review = session.review
  local items = {}
  for _, t in ipairs(threads) do
    local first = first_line(t)
    if vim.fn.strchars(first) > 60 then
      first = vim.fn.strcharpart(first, 0, 59) .. '…'
    end
    local text = ('[%s] %s: %s'):format(state_of(t), model.summary_text(t), first)
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
  vim.fn.setqflist({}, ' ', { title = title, items = items })
  vim.cmd('copen')
end

-- two cells each, so the columns after them line up
local ICONS = {
  open = { '\240\159\146\172', 'DiffyThreadSummary' },
  resolved = { '✓ ', 'DiffyThreadResolved' },
  outdated = { '◌ ', 'DiffyThreadOutdated' },
  detached = { '✗ ', 'DiffyThreadOutdated' },
}

--- A thread's picker columns: state, location, author (+replies), what
--- isn't published yet, first line.
local function columns(session, t, with_path)
  local first = t.comments[1]
  local line = t.anchor.start_line and tostring(t.anchor.start_line) or nil
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

--- Picker rows with every column padded to its widest cell, so the first
--- lines start at the same column.
local function rows(session, threads, with_path)
  local cols, w = {}, { loc = 0, who = 0, badges = 0 }
  for i, t in ipairs(threads) do
    local c = columns(session, t, with_path)
    cols[i] = c
    w.loc = math.max(w.loc, width_of(c.loc))
    w.who = math.max(w.who, vim.fn.strdisplaywidth(c.author .. c.replies))
    local b = 0
    for j, badge in ipairs(c.badges) do
      b = b + #badge[1] + (j > 1 and 1 or 0)
    end
    w.badges = math.max(w.badges, b)
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
      local b = 0
      for j, badge in ipairs(c.badges) do
        table.insert(chunks, { (j > 1 and ' ' or '') .. badge[1], badge[2] })
        b = b + #badge[1] + (j > 1 and 1 or 0)
      end
      table.insert(chunks, { (' '):rep(w.badges - b + 2) })
    end
    table.insert(chunks, { c.text, c.state == 'open' and 'Normal' or 'DiffyThreadSummaryResolved' })
    out[i] = chunks
  end
  return out
end

local function pick(snacks, session, threads, title, with_path)
  local chunks = rows(session, threads, with_path)
  local items = {}
  for i, t in ipairs(threads) do
    -- matched on everything a reader could remember a thread by
    local words = { t.anchor.path }
    for _, c in ipairs(t.comments) do
      table.insert(words, c.author or '')
      table.insert(words, c.body or '')
    end
    table.insert(items, {
      text = table.concat(words, ' '),
      thread = t,
      chunks = chunks[i],
      -- for snacks' own actions, e.g. sending the list to the quickfix
      file = session.root .. '/' .. t.anchor.path,
      pos = { math.max(1, t.anchor.start_line or 1), 0 },
    })
  end
  snacks.picker.pick({
    title = title,
    items = items,
    format = function(item)
      return item.chunks
    end,
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:minimal()
      ui.render_thread(session, ctx.buf, ctx.item.thread)
      ctx.preview:wo({ wrap = true, linebreak = true, breakindent = true, conceallevel = 2, concealcursor = 'nvic' })
      local t = ctx.item.thread
      ctx.preview:set_title(t.anchor.start_line and ('%s:%d'):format(t.anchor.path, t.anchor.start_line) or t.anchor.path)
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

--- `:Diffy threads [file] [author=<name>] [state=<open|resolved|outdated|
--- detached>] [review=<id>]`: `file` keeps the file shown in the diff. For
--- GitHub, the quickfix text also says which commits show each thread.
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
    elseif a == 'file' then
      if not session.current_path then
        vim.notify('diffy: no file shown in the diff', vim.log.levels.WARN)
        return
      end
      filters.path = session.current_path
    end
  end
  local threads = collect(review, filters)
  local title = filters.path and ('Threads in ' .. filters.path) or 'Review threads'
  local ok, snacks = pcall(require, 'snacks')
  if ok and type(snacks) == 'table' and snacks.picker then
    if #threads == 0 then
      vim.notify('diffy: no threads' .. (filters.path and (' in ' .. filters.path) or ''))
      return
    end
    pick(snacks, session, threads, title, not filters.path)
  else
    to_quickfix(session, threads, title)
  end
end

return M
