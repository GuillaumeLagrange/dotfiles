-- The log panel (contract §2, §3, §4): builds the entry list (Unstaged,
-- Staged, commits), renders it (with collapse-on-blur), and owns the
-- contiguous-selection keys.
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')

local M = {}

local function log_args(expr, limit)
  local args = { 'log', '-z', '--date-order', '--pretty=format:%H%x1f%P%x1f%s' }
  if limit then
    vim.list_extend(args, { '-n', tostring(limit) })
  end
  if expr then
    table.insert(args, expr)
  end
  return args
end

--- `git log -z --follow --date-order --pretty=… -- path` (§4 `:Diffy
--- file`): commits touching `path`, tracked across renames.
local function file_log_args(path)
  return { 'log', '-z', '--follow', '--date-order', '--pretty=format:%H%x1f%P%x1f%s', '--', path }
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

--- Build the log entry list for range spec `spec` (`{kind='default'}`,
--- `{kind='branch', base=ref_or_nil}`, or `{kind='range', expr='A..B'}`).
--- `cb(entries, err)`. `session`, if given, is threaded to every git/gh call
--- so the whole chain no-ops once that session is torn down.
function M.build_entries(root, spec, cb, session)
  local prefix = worktree_prefix(spec)
  if spec.kind == 'range' then
    commit_entries(root, log_args(spec.expr), function(commits, err)
      if not commits then
        cb(nil, err)
        return
      end
      cb(commits, nil)
    end, session)
  elseif spec.kind == 'branch' then
    repo.resolve_base(root, spec.base, function(base, err)
      if not base then
        cb(nil, err)
        return
      end
      repo.merge_base(root, base, 'HEAD', function(mb, err2)
        if not mb then
          cb(nil, err2)
          return
        end
        commit_entries(root, log_args(mb .. '..HEAD'), function(commits, err3)
          if not commits then
            cb(nil, err3)
            return
          end
          local out = vim.deepcopy(prefix)
          vim.list_extend(out, commits)
          cb(out, nil)
        end, session)
      end, session)
    end, session)
  elseif spec.kind == 'pr' then
    -- `:Diffy pr` (§4/§9.4): `spec.base` is already resolved (the PR's
    -- `baseRefName`, from `github.find_pr`) - no `resolve_base` call, and
    -- no Unstaged/Staged prefix (the readiness check already guarantees a
    -- clean tree at the PR head).
    repo.merge_base(root, spec.base, 'HEAD', function(mb, err2)
      if not mb then
        cb(nil, err2)
        return
      end
      commit_entries(root, log_args(mb .. '..HEAD'), function(commits, err3)
        if not commits then
          cb(nil, err3)
          return
        end
        cb(commits, nil)
      end, session)
    end, session)
  elseif spec.kind == 'file' then
    commit_entries(root, file_log_args(spec.path), function(commits, err)
      if not commits then
        cb(nil, err)
        return
      end
      -- every name `path` has ever had (renames), so the tree's diff calls
      -- can be pathspec-restricted to just this file (§8's phase-5 hook)
      -- while still letting git detect a rename across adjacent commits.
      run.git({ 'log', '--follow', '-z', '--name-status', '--pretty=format:%H', '--', spec.path }, {
        cwd = root,
        session = session,
        on_exit = function(res)
          local names = { [spec.path] = true }
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
          commits.follow_pathspec = pathspec
          cb(commits, nil)
        end,
      })
    end, session)
  else
    repo.default_range(root, function(range_spec)
      commit_entries(root, log_args(range_spec.expr, range_spec.n), function(commits, err)
        if not commits then
          cb(nil, err)
          return
        end
        local out = vim.deepcopy(prefix)
        vim.list_extend(out, commits)
        cb(out, nil)
      end, session)
    end, session)
  end
end

--- Default selection for `spec` over `entries` (§4's table): `Unstaged`
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

local function summary_line(session)
  local sel = session.sel
  if not sel then
    return 'diffy: no selection'
  end
  local n = 0
  for i = sel.top, sel.bottom do
    if session.entries[i].kind == 'commit' then
      n = n + 1
    end
  end
  local top, bottom = session.entries[sel.top], session.entries[sel.bottom]
  local left_label = bottom.kind == 'unstaged' and 'worktree'
    or bottom.kind == 'staged' and 'index'
    or short(bottom.sha) .. '^'
  local right_label = top.kind == 'unstaged' and 'worktree' or top.kind == 'staged' and 'index' or short(top.sha)
  if n == 0 then
    return ('%s..%s'):format(left_label, right_label)
  end
  return ('%d commit%s %s..%s'):format(n, n == 1 and '' or 's', left_label, right_label)
end

local function entry_text(entry)
  if entry.kind == 'unstaged' then
    return 'Unstaged'
  elseif entry.kind == 'staged' then
    return 'Staged'
  end
  return short(entry.sha) .. ' ' .. entry.subject
end

--- Full entry list into the log buffer, highlighting merges (dimmed) and
--- the active contiguous selection.
local function render_full(session)
  local buf = session.bufs.log
  local lines = {}
  for _, e in ipairs(session.entries) do
    table.insert(lines, entry_text(e))
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = session.ns.log_render
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, e in ipairs(session.entries) do
    if e.kind == 'commit' and e.merge then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'Comment' })
    end
    if session.sel and i >= session.sel.top and i <= session.sel.bottom then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'Visual' })
    end
  end
end

local function set_height(session, height)
  if vim.api.nvim_win_is_valid(session.wins.log) then
    vim.api.nvim_win_set_height(session.wins.log, height)
  end
end

--- Collapse the log window to its one-line summary (unfocused, §2).
function M.collapse(session)
  local buf = session.bufs.log
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { summary_line(session) })
  vim.bo[buf].modifiable = false
  set_height(session, 1)
end

--- Expand the log window to its full entry list (focused, §2):
--- `min(#entries, 40% of the tree+log column)`.
function M.expand(session)
  render_full(session)
  local height = math.max(1, math.min(#session.entries, math.floor(session.column_height * 0.4)))
  set_height(session, height)
end

--- (Re)render the log panel: full if focused, collapsed otherwise. Call
--- after entries/selection change.
function M.render(session)
  local focused = vim.api.nvim_get_current_win() == session.wins.log
  if focused then
    M.expand(session)
  else
    M.collapse(session)
  end
end

local function clamp_range(entries, top, bottom)
  top, bottom = math.max(1, top), math.min(#entries, bottom)
  while top <= bottom and entries[top].kind == 'commit' and entries[top].merge do
    top = top + 1
  end
  while bottom >= top and entries[bottom].kind == 'commit' and entries[bottom].merge do
    bottom = bottom - 1
  end
  return top, bottom
end

--- <CR> in normal mode: select the single entry under the cursor.
function M.select_line(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.log)[1]
  local top, bottom = clamp_range(session.entries, lnum, lnum)
  if top > bottom then
    return
  end
  session.sel = { top = top, bottom = bottom }
  session.on_select(session)
end

--- `<CR>` in visual/visual-line mode: select the marked line range.
function M.select_visual(session)
  vim.cmd('normal! \27') -- <Esc>, leave visual mode so the marks settle
  local a = vim.api.nvim_buf_get_mark(session.bufs.log, '<')[1]
  local b = vim.api.nvim_buf_get_mark(session.bufs.log, '>')[1]
  local top, bottom = clamp_range(session.entries, math.min(a, b), math.max(a, b))
  if top > bottom then
    return
  end
  session.sel = { top = top, bottom = bottom }
  session.on_select(session)
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
  while i >= 1 and i <= #session.entries and session.entries[i].kind == 'commit' and session.entries[i].merge do
    i = i + delta
  end
  if i < 1 or i > #session.entries then
    return
  end
  session.sel = { top = i, bottom = i }
  session.on_select(session)
end

local function move_cursor_to(session)
  if session.sel and vim.api.nvim_win_is_valid(session.wins.log) then
    local ok = pcall(vim.api.nvim_win_set_cursor, session.wins.log, { session.sel.top, 0 })
    if not ok then
      pcall(vim.api.nvim_win_set_cursor, session.wins.log, { 1, 0 })
    end
  end
end

--- One-time setup: collapse/expand on focus change, and the panel's keys.
function M.setup(session)
  session.ns.log_render = require('diffy.session').namespace(session, 'log_render')

  vim.api.nvim_create_autocmd('WinEnter', {
    group = session.augroup,
    callback = function()
      if vim.api.nvim_get_current_win() == session.wins.log then
        M.expand(session)
        move_cursor_to(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    group = session.augroup,
    callback = function()
      if vim.api.nvim_get_current_win() == session.wins.log then
        M.collapse(session)
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
end

return M
