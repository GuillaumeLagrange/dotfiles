-- The log panel: builds the entry list (Unstaged,
-- Staged, commits), renders it, and owns the contiguous-selection keys.
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')
local hl = require('diffy.highlight')

local M = {}

local LOG_PRETTY = '--pretty=format:%H%x1f%P%x1f%s'

local function log_args(expr, limit)
  local args = { 'log', '-z', '--date-order', LOG_PRETTY }
  if limit then
    vim.list_extend(args, { '-n', tostring(limit) })
  end
  if expr then
    table.insert(args, expr)
  end
  return args
end

--- `:Diffy file`: commits touching `path`, tracked across renames.
local function file_log_args(path)
  return { 'log', '-z', '--follow', '--date-order', LOG_PRETTY, '--', path }
end

local function commit_entries(root, args, cb, session)
  run.git(args, {
    cwd = root,
    session = session,
    on_exit = function(res)
      if res.code ~= 0 then
        cb(nil, vim.trim(res.stderr or ''))
        return
      end
      local out = {}
      for _, c in ipairs(parse.log(res.stdout or '')) do
        table.insert(out, {
          kind = 'commit',
          sha = c.sha,
          parents = c.parents,
          subject = c.subject,
          merge = c.merge,
          rev = c.sha,
        })
      end
      cb(out, nil)
    end,
  })
end

local function worktree_prefix(spec)
  if spec.kind == 'range' or spec.kind == 'file' or spec.kind == 'pr' then
    return {}
  end
  return {
    { kind = 'unstaged', label = 'Unstaged', rev = 'WORKTREE' },
    { kind = 'staged', label = 'Staged', rev = 'INDEX' },
  }
end

local function prefixed(prefix, commits)
  local out = vim.deepcopy(prefix)
  vim.list_extend(out, commits)
  return out
end

--- Branch/PR views: record the merge-base as `entries.base` and flag
--- the commits that contain it (`has_base`), i.e. those after a merge of
--- the base branch, so a selection down to the oldest commit diffs against
--- the merge-base like github.com instead of showing merged-in base changes.
local function with_base(root, mb, entries, cb, session)
  run.git({ 'rev-list', '--ancestry-path', mb .. '..HEAD' }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local contains = {}
      for sha in (res.stdout or ''):gmatch('%x+') do
        contains[sha] = true
      end
      for _, e in ipairs(entries) do
        if e.kind == 'commit' then
          e.has_base = contains[e.sha] or false
        end
      end
      entries.base = mb
      cb(entries, nil)
    end,
  })
end

--- Commits since the merge-base of `base` and HEAD, after `prefix`.
local function merge_base_entries(root, base, prefix, cb, session)
  repo.merge_base(root, base, 'HEAD', function(mb, err)
    if not mb then
      cb(nil, err)
      return
    end
    commit_entries(root, log_args(mb .. '..HEAD'), function(commits, err2)
      if not commits then
        cb(nil, err2)
        return
      end
      with_base(root, mb, prefixed(prefix, commits), cb, session)
    end, session)
  end, session)
end

--- Every name `path` has ever had (renames), sorted, so the tree's diff
--- calls can be pathspec-restricted to just this file while still letting
--- git detect a rename across adjacent commits.
local function follow_pathspec(root, path, cb, session)
  run.git({ 'log', '--follow', '-z', '--name-status', '--pretty=format:%H', '--', path }, {
    cwd = root,
    session = session,
    on_exit = function(res)
      local names = { [path] = true }
      if res.code == 0 then
        for _, rec in ipairs(parse.log_name_status(res.stdout or '')) do
          if rec.path then
            names[rec.path] = true
          end
          if rec.old_path then
            names[rec.old_path] = true
          end
        end
      end
      local pathspec = {}
      for name in pairs(names) do
        table.insert(pathspec, name)
      end
      table.sort(pathspec)
      cb(pathspec)
    end,
  })
end

--- Build the log entry list for range spec `spec` (`{kind='default'}`,
--- `{kind='branch', base=ref_or_nil}`, or `{kind='range', expr='A..B'}`).
--- `cb(entries, err)`. `session`, if given, is threaded to every git/gh call
--- so the whole chain no-ops once that session is torn down.
function M.build_entries(root, spec, cb, session)
  local prefix = worktree_prefix(spec)
  if spec.kind == 'range' then
    commit_entries(root, log_args(spec.expr), cb, session)
  elseif spec.kind == 'branch' then
    repo.resolve_base(root, spec.base, function(base, err)
      if not base then
        cb(nil, err)
        return
      end
      merge_base_entries(root, base, prefix, cb, session)
    end, session)
  elseif spec.kind == 'pr' then
    -- `spec.base` is already the PR's resolved `baseRefName`, and there is
    -- no Unstaged/Staged prefix (readiness guarantees a clean tree at the PR head).
    merge_base_entries(root, spec.base, prefix, cb, session)
  elseif spec.kind == 'file' then
    commit_entries(root, file_log_args(spec.path), function(commits, err)
      if not commits then
        cb(nil, err)
        return
      end
      follow_pathspec(root, spec.path, function(pathspec)
        commits.follow_pathspec = pathspec
        cb(commits, nil)
      end, session)
    end, session)
  else
    repo.default_range(root, function(range_spec)
      commit_entries(root, log_args(range_spec.expr, range_spec.n), function(commits, err)
        if not commits then
          cb(nil, err)
          return
        end
        cb(prefixed(prefix, commits), nil)
      end, session)
    end, session)
  end
end

--- Default selection for `spec` over `entries`: `Unstaged`
--- alone for `:Diffy`, all commits (excluding Unstaged/Staged) for
--- `:Diffy branch`, everything for an explicit range.
function M.default_selection(entries, spec)
  if #entries == 0 then
    return nil
  end
  if spec.kind == 'default' then
    return { top = 1, bottom = 1 }
  end
  if spec.kind == 'file' then
    local top = selection.first_selectable(entries)
    if not top then
      return nil
    end
    return { top = top, bottom = top }
  end
  local first_commit = 1
  if spec.kind == 'branch' then
    first_commit = 3 -- past Unstaged/Staged
  end
  local top = selection.first_selectable(entries)
  local bottom = selection.last_selectable(entries)
  if not top or not bottom then
    return { top = first_commit, bottom = #entries }
  end
  if top < first_commit then
    top = first_commit
  end
  return { top = top, bottom = bottom }
end

local function short(sha)
  return sha:sub(1, 7)
end

local MARK = '▌'

--- One log row fitted to `width` cells: `text` plus highlight spans.
local function entry_line(entry, selected, width)
  local head = (selected and MARK or ' ') .. ' '
  if entry.kind ~= 'commit' then
    local label = entry.kind == 'unstaged' and 'Unstaged' or 'Staged'
    local text = head .. hl.truncate(label, width - 2)
    return text, { { #head, #text, 'DiffyLabel' } }
  end
  local sha = short(entry.sha)
  local text = head .. sha .. ' ' .. hl.truncate(entry.subject, width - 2 - #sha - 1)
  if entry.merge then
    return text, {}
  end
  return text, { { #head, #head + #sha, 'DiffySha' } }
end

local function log_width(session)
  return hl.panel_width(session.wins.log, session.log_width)
end

local function is_merge(entry)
  return entry.kind == 'commit' and entry.merge
end

--- (Re)render the full entry list: merges dimmed, the active
--- contiguous selection marked. Call after entries/selection change.
function M.render(session)
  local buf = session.bufs.log
  local width = log_width(session)
  session.log_width = width
  local sel = session.sel
  local function selected(i)
    return sel ~= nil and i >= sel.top and i <= sel.bottom
  end
  local lines, all_spans = {}, {}
  for i, e in ipairs(session.entries) do
    lines[i], all_spans[i] = entry_line(e, selected(i), width)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = session.ns.log_render
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, e in ipairs(session.entries) do
    if is_merge(e) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'DiffyMerge' })
    end
    if selected(i) then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'DiffySelection' })
    end
    for _, sp in ipairs(all_spans[i]) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
    end
  end
end

local function clamp_range(entries, top, bottom)
  top, bottom = math.max(1, top), math.min(#entries, bottom)
  while top <= bottom and is_merge(entries[top]) do
    top = top + 1
  end
  while bottom >= top and is_merge(entries[bottom]) do
    bottom = bottom - 1
  end
  return top, bottom
end

--- Select `top..bottom` trimmed of merge endpoints; no-op if nothing is left.
local function select_clamped(session, top, bottom)
  top, bottom = clamp_range(session.entries, top, bottom)
  if top > bottom then
    return
  end
  session.sel = { top = top, bottom = bottom }
  session.on_select(session)
end

--- <CR> in normal mode: select the single entry under the cursor.
function M.select_line(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.log)[1]
  select_clamped(session, lnum, lnum)
end

--- `<CR>` in visual/visual-line mode: select the marked line range.
function M.select_visual(session)
  vim.cmd('normal! \27') -- <Esc>, leave visual mode so the marks settle
  local a = vim.api.nvim_buf_get_mark(session.bufs.log, '<')[1]
  local b = vim.api.nvim_buf_get_mark(session.bufs.log, '>')[1]
  select_clamped(session, math.min(a, b), math.max(a, b))
end

--- `a`: select every selectable entry (first..last non-merge endpoint).
function M.select_all(session)
  local top = selection.first_selectable(session.entries)
  local bottom = selection.last_selectable(session.entries)
  if not top or not bottom or top > bottom then
    return
  end
  session.sel = { top = top, bottom = bottom }
  session.on_select(session)
end

--- `J`/`K` (also `]r`/`[r` from the diff windows): collapse the current
--- selection to a single entry and move it to the next/previous non-merge
--- entry (`delta = 1` moves toward older commits, `-1` toward newer).
function M.move_selection(session, delta)
  local sel = session.sel
  if not sel then
    return
  end
  local idx = delta > 0 and sel.bottom or sel.top
  local i = idx + delta
  while i >= 1 and i <= #session.entries and is_merge(session.entries[i]) do
    i = i + delta
  end
  if i < 1 or i > #session.entries then
    return
  end
  session.sel = { top = i, bottom = i }
  session.on_select(session)
end

function M.setup(session)
  session.ns.log_render = require('diffy.session').namespace(session, 'log_render')
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      local win = session.wins.log
      if session.entries and win and vim.api.nvim_win_is_valid(win) and log_width(session) ~= session.log_width then
        M.render(session)
      end
    end,
  })

  local buf = session.bufs.log
  local map = require('diffy.session').map
  map(session, 'n', '<CR>', function()
    M.select_line(session)
  end, { buffer = buf, desc = 'select entry' })
  map(session, { 'v', 'x' }, '<CR>', function()
    M.select_visual(session)
  end, { buffer = buf, desc = 'select range' })
  map(session, 'n', 'a', function()
    M.select_all(session)
  end, { buffer = buf, desc = 'select all' })
  map(session, 'n', 'J', function()
    M.move_selection(session, 1)
  end, { buffer = buf, desc = 'select next commit' })
  map(session, 'n', 'K', function()
    M.move_selection(session, -1)
  end, { buffer = buf, desc = 'select previous commit' })
  map(session, 'n', 'X', function()
    require('diffy.checkout').toggle(session)
  end, { buffer = buf, desc = 'full checkout' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
  require('diffy.session').map_toggle(session, buf)
end

return M
