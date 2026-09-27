-- The file tree panel (contract §5): the diff between the current
-- selection's (left, right), grouped by directory (single-child dirs
-- flattened), with rename pairs and +n/-m counts.
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')

local M = {}

local function dirname(path)
  return path:match('^(.*)/[^/]+$') or ''
end

--- name-status + numstat for the current selection, merged by path, plus
--- untracked files (only when the selection is exactly Unstaged, §5).
local function build_diff_entries(session, cb)
  local diff_args = repo.diff_args(session.pair.left, session.pair.right)
  local ns_args = { 'diff', '-z', '-M', '--name-status' }
  vim.list_extend(ns_args, diff_args)
  local num_args = { 'diff', '-z', '-M', '--numstat' }
  vim.list_extend(num_args, diff_args)

  run.git(ns_args, {
    cwd = session.root,
    on_exit = function(res1)
      if res1.code ~= 0 then
        cb(nil, vim.trim(res1.stderr or ''))
        return
      end
      local ns_list = parse.name_status(res1.stdout or '')
      run.git(num_args, {
        cwd = session.root,
        on_exit = function(res2)
          if res2.code ~= 0 then
            cb(nil, vim.trim(res2.stderr or ''))
            return
          end
          local by_path = {}
          for _, e in ipairs(parse.numstat(res2.stdout or '')) do
            by_path[e.path] = e
          end
          local entries = {}
          for _, e in ipairs(ns_list) do
            local n = by_path[e.path]
            table.insert(entries, {
              status = e.status,
              path = e.path,
              old_path = e.old_path,
              added = n and n.added or nil,
              removed = n and n.removed or nil,
            })
          end
          if session.pair.left == 'INDEX' and session.pair.right == 'WORKTREE' then
            for _, s in ipairs(session.status_entries or {}) do
              if s.kind == 'untracked' then
                table.insert(entries, { status = '?', path = s.path })
              end
            end
          end
          table.sort(entries, function(a, b)
            return a.path < b.path
          end)
          cb(entries, nil)
        end,
      })
    end,
  })
end

--- Group a flat entry list into display rows: a directory containing 2+
--- entries gets one collapsible header row followed by its indented
--- children; a directory with exactly one entry is flattened away (the
--- entry is shown directly, its own path carrying the directory prefix).
local function group_rows(entries)
  local groups, order = {}, {}
  for _, e in ipairs(entries) do
    local dir = dirname(e.path)
    if not groups[dir] then
      groups[dir] = {}
      table.insert(order, dir)
    end
    table.insert(groups[dir], e)
  end
  table.sort(order)

  local rows = {}
  for _, dir in ipairs(order) do
    local list = groups[dir]
    if dir == '' or #list == 1 then
      for _, e in ipairs(list) do
        table.insert(rows, { kind = 'file', entry = e, depth = 0 })
      end
    else
      table.insert(rows, { kind = 'dir', name = dir, depth = 0 })
      for _, e in ipairs(list) do
        table.insert(rows, { kind = 'file', entry = e, depth = 1 })
      end
    end
  end
  return rows
end

local function row_text(row)
  local indent = ('  '):rep(row.depth)
  if row.kind == 'dir' then
    return indent .. row.name .. '/'
  end
  local e = row.entry
  local name = e.path
  if e.status == 'R' or e.status == 'C' then
    name = (e.old_path or '?') .. ' \226\134\146 ' .. e.path
  end
  local counts = ''
  if e.added or e.removed then
    counts = ('  +%d -%d'):format(e.added or 0, e.removed or 0)
  end
  return ('%s%s %s%s'):format(indent, e.status, name, counts)
end

--- Per-file real-file/dirty context (§3) built from `session.status_entries`.
local function clean_ctx(session)
  local dirty = {}
  for _, s in ipairs(session.status_entries or {}) do
    if s.kind ~= 'untracked' and s.kind ~= 'ignored' then
      dirty[s.path] = true
      if s.old_path then
        dirty[s.old_path] = true
      end
    end
  end
  return {
    head_sha = session.head_sha,
    checkout_sha = session.checkout_sha,
    is_clean = function(path)
      return not dirty[path]
    end,
  }
end

--- Open the diff pair for tree row `row` (a `{kind='file', entry=...}`).
function M.open_row(session, row)
  if not row or row.kind ~= 'file' then
    return
  end
  local diffpair = require('diffy.diffpair')
  local e = row.entry
  local ctx = clean_ctx(session)

  local left_spec, right_spec
  if e.status == 'A' or e.status == '?' then
    left_spec = nil
  else
    left_spec = { rev = session.pair.left, path = e.old_path or e.path }
  end
  if e.status == 'D' then
    right_spec = nil
  else
    local right_rev = session.pair.right
    if selection.right_is_real(session.pair, e.path, ctx) then
      right_rev = 'WORKTREE'
    end
    right_spec = { rev = right_rev, path = e.path }
  end

  session.current_path = e.path
  diffpair.show(session, left_spec, right_spec)
end

local function render_buffer(session)
  local buf = session.bufs.tree
  local lines = {}
  for _, row in ipairs(session.tree_rows) do
    table.insert(lines, row_text(row))
  end
  if #lines == 0 then
    lines = { '(no changes)' }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[session.wins.tree].foldmethod = 'indent'
  vim.wo[session.wins.tree].foldenable = true
  vim.wo[session.wins.tree].foldlevel = 99
end

local function file_rows(session)
  local out = {}
  for i, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' then
      table.insert(out, i)
    end
  end
  return out
end

--- (Re)build and render the tree for the current selection, then open the
--- pair for whichever file was showing before (if still present) or the
--- first file, so the diff windows never sit on a stale render. `cb`, if
--- given, runs once rendering (including the diff pair) has finished -
--- callers that signal `DiffyReady` must wait for it, since this is async.
function M.render(session, cb)
  build_diff_entries(session, function(entries, err)
    if not entries then
      vim.notify('diffy: ' .. tostring(err), vim.log.levels.ERROR)
      if cb then
        cb()
      end
      return
    end
    session.tree_rows = group_rows(entries)
    render_buffer(session)

    local target
    for _, i in ipairs(file_rows(session)) do
      if session.tree_rows[i].entry.path == session.current_path then
        target = i
        break
      end
    end
    if not target then
      target = file_rows(session)[1]
    end

    if target then
      session.current_file_line = target
      M.open_row(session, session.tree_rows[target])
    else
      require('diffy.diffpair').clear(session)
      session.current_path = nil
    end
    if cb then
      cb()
    end
  end)
end

--- `<CR>`/`o`: open the pair for the entry at the cursor.
function M.select_at_cursor(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  local row = session.tree_rows[lnum]
  if row and row.kind == 'file' then
    session.current_file_line = lnum
    M.open_row(session, row)
    require('diffy.git.run').ready({ session = session.id, event = 'open_row' })
  end
end

--- `]f`/`[f` (also from the diff windows): move to and open the
--- next/previous file entry.
function M.move_file(session, delta)
  local files = file_rows(session)
  if #files == 0 then
    return
  end
  local cur = session.current_file_line
  local pos
  for i, lnum in ipairs(files) do
    if lnum == cur then
      pos = i
      break
    end
  end
  local next_pos
  if not pos then
    next_pos = delta > 0 and 1 or #files
  else
    next_pos = pos + delta
  end
  if next_pos < 1 or next_pos > #files then
    return
  end
  local lnum = files[next_pos]
  session.current_file_line = lnum
  if vim.api.nvim_win_is_valid(session.wins.tree) then
    pcall(vim.api.nvim_win_set_cursor, session.wins.tree, { lnum, 0 })
  end
  M.open_row(session, session.tree_rows[lnum])
  require('diffy.git.run').ready({ session = session.id, event = 'open_row' })
end

--- `gf`: open the real worktree file for the entry at the cursor in the
--- tab that was active before the diffy tab was opened.
function M.open_real_file(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  local row = session.tree_rows[lnum]
  if not row or row.kind ~= 'file' then
    return
  end
  local path = row.entry.path
  if row.entry.status == 'D' then
    vim.notify('diffy: no worktree file for a deleted path', vim.log.levels.WARN)
    return
  end
  local abspath = session.root .. '/' .. path
  if session.prev_tab and vim.api.nvim_tabpage_is_valid(session.prev_tab) then
    vim.api.nvim_set_current_tabpage(session.prev_tab)
  else
    vim.cmd('tabnew')
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(abspath))
end

--- One-time keymap setup for the tree buffer.
function M.setup(session)
  local map = require('diffy.session').map
  local buf = session.bufs.tree
  map(session, 'n', '<CR>', function()
    M.select_at_cursor(session)
  end, { buffer = buf, desc = 'open pair' })
  map(session, 'n', 'o', function()
    M.select_at_cursor(session)
  end, { buffer = buf, desc = 'open pair' })
  map(session, 'n', ']f', function()
    M.move_file(session, 1)
  end, { buffer = buf, desc = 'next file' })
  map(session, 'n', '[f', function()
    M.move_file(session, -1)
  end, { buffer = buf, desc = 'previous file' })
  map(session, 'n', 'gf', function()
    M.open_real_file(session)
  end, { buffer = buf, desc = 'open real file' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
end

return M
