-- The file tree panel (contract §5): the diff between the current
-- selection's (left, right) as a nested directory tree (collapsible on
-- `za`, chains of single-child dirs flattened into one row), with rename
-- pairs, +n/-m counts and the staging keys (`s`/`u`/`-`/`S`/`U`).
local run = require('diffy.git.run')
local repo = require('diffy.git.repo')
local parse = require('diffy.git.parse')
local selection = require('diffy.selection')

local M = {}

--- name-status + numstat for the current selection, merged by path, plus
--- untracked files (only when the selection is exactly Unstaged, §5).
local function build_diff_entries(session, gen, cb)
  local diff_args = repo.diff_args(session.pair.left, session.pair.right)
  local ns_args = { 'diff', '-z', '-M', '--name-status' }
  vim.list_extend(ns_args, diff_args)
  local num_args = { 'diff', '-z', '-M', '--numstat' }
  vim.list_extend(num_args, diff_args)
  if session.follow_pathspec then
    table.insert(ns_args, '--')
    vim.list_extend(ns_args, session.follow_pathspec)
    table.insert(num_args, '--')
    vim.list_extend(num_args, session.follow_pathspec)
  end

  run.git(ns_args, {
    cwd = session.root,
    session = session,
    gen = gen,
    on_exit = function(res1)
      if res1.code ~= 0 then
        cb(nil, vim.trim(res1.stderr or ''))
        return
      end
      local ns_list = parse.name_status(res1.stdout or '')
      run.git(num_args, {
        cwd = session.root,
        session = session,
        gen = gen,
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
          -- an unmerged path's plain `git diff` (worktree vs index) reports
          -- it twice ('U', then a spurious 'M' from git's own auto-merge
          -- attempt) - keep only the conflict status (§8).
          local unmerged_paths = {}
          for _, e in ipairs(entries) do
            if e.status == 'U' then
              unmerged_paths[e.path] = true
            end
          end
          if next(unmerged_paths) then
            local deduped = {}
            for _, e in ipairs(entries) do
              if e.status == 'U' or not unmerged_paths[e.path] then
                table.insert(deduped, e)
              end
            end
            entries = deduped
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

--- Build a nested directory tree from a flat, path-sorted entry list:
--- `dirs`/`dir_order` hold immediate child directories, `files` the
--- entries whose parent directory is this node.
local function build_tree(entries)
  local root = { dirs = {}, dir_order = {}, files = {} }
  for _, e in ipairs(entries) do
    local node = root
    for seg in e.path:gmatch('([^/]+)/') do
      if not node.dirs[seg] then
        node.dirs[seg] = { dirs = {}, dir_order = {}, files = {} }
        table.insert(node.dir_order, seg)
      end
      node = node.dirs[seg]
    end
    table.insert(node.files, e)
  end
  return root
end

--- `node`'s direct children (files and subdirectories), ordered by name.
local function node_items(node)
  local items = {}
  for _, e in ipairs(node.files) do
    table.insert(items, { key = e.path:match('([^/]+)$') or e.path, kind = 'file', entry = e })
  end
  for _, name in ipairs(node.dir_order) do
    table.insert(items, { key = name, kind = 'dir', name = name, node = node.dirs[name] })
  end
  table.sort(items, function(a, b)
    return a.key < b.key
  end)
  return items
end

--- Lay `node` (full path `path`) out into display rows: a directory whose
--- only content is one subdirectory is merged into `chain` (no row of its
--- own - §5's "chains of single-child dirs flattened into one row"); a
--- directory whose only content is one file is skipped entirely (the file
--- is shown directly, with its path relative to the enclosing header);
--- everything else gets one collapsible header row for the accumulated
--- `chain` (empty at the root, so the root itself never gets a header)
--- followed by its children, one depth deeper - `foldmethod=indent` then
--- folds exactly that header's children on `za`, at every nesting level.
--- `base` is the full path of the nearest enclosing header ('' at root):
--- file rows display their path relative to it.
local function layout(node, path, chain, base, depth, rows)
  local function join(a, b)
    return a == '' and b or (a .. '/' .. b)
  end
  local items = node_items(node)
  if #items == 0 then
    return
  end
  if #items == 1 and items[1].kind == 'dir' then
    local it = items[1]
    layout(it.node, join(path, it.name), join(chain, it.name), base, depth, rows)
    return
  end
  if #items == 1 and items[1].kind == 'file' then
    table.insert(rows, { kind = 'file', entry = items[1].entry, depth = depth, base = base })
    return
  end
  local child_depth, child_base = depth, base
  if chain ~= '' then
    table.insert(rows, { kind = 'dir', name = chain, depth = depth })
    child_depth, child_base = depth + 1, path
  end
  for _, it in ipairs(items) do
    if it.kind == 'file' then
      table.insert(rows, { kind = 'file', entry = it.entry, depth = child_depth, base = child_base })
    else
      layout(it.node, join(path, it.name), it.name, child_base, child_depth, rows)
    end
  end
end

--- Group a flat, path-sorted entry list into display rows (§5): a nested
--- directory tree, each real directory collapsible on its own header row,
--- chains of single-child directories flattened into one row, and a
--- directory holding exactly one file flattened away entirely.
local function group_rows(entries)
  local rows = {}
  layout(build_tree(entries), '', '', '', 0, rows)
  return rows
end

local hl = require('diffy.highlight')

local function relative(path, base)
  if base ~= '' and path:sub(1, #base + 1) == base .. '/' then
    return path:sub(#base + 2)
  end
  return path
end

local function dirname(path)
  return path:match('^(.*)/[^/]*$') or ''
end

local function basename(path)
  return path:match('([^/]+)$') or path
end

--- One display row fitted to `width` cells (§5): `text` plus highlight
--- spans `{start_col, end_col, group}` (byte columns).
local function row_line(row, width)
  local indent = ('  '):rep(row.depth)
  if row.kind == 'dir' then
    local text = hl.truncate(indent .. row.name .. '/', width)
    return text, { { #indent, #text, 'DiffyDirectory' } }
  end
  local e = row.entry
  local counts = ''
  if e.added or e.removed then
    counts = ('+%d -%d'):format(e.added or 0, e.removed or 0)
  end
  local head = indent .. e.status .. ' '
  local avail = width - vim.fn.strdisplaywidth(head) - (counts ~= '' and (#counts + 1) or 0)
  local new_rel = relative(e.path, row.base)
  local name = new_rel
  if (e.status == 'R' or e.status == 'C') and e.old_path then
    if dirname(e.old_path) == dirname(e.path) then
      local dir = relative(dirname(e.path), row.base)
      dir = (dir == '' or dir == row.base) and '' or (dir .. '/')
      name = dir .. basename(e.old_path) .. ' → ' .. basename(e.path)
    else
      local full = relative(e.old_path, row.base) .. ' → ' .. new_rel
      name = vim.fn.strdisplaywidth(full) <= avail and full or new_rel
    end
  end
  name = hl.truncate_left(name, math.max(1, avail))
  local left = head .. name
  local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - #counts)
  local text = counts ~= '' and (left .. (' '):rep(pad) .. counts) or left
  local spans = { { #indent, #indent + #e.status, hl.STATUS[e.status] or 'DiffyChanged' } }
  if counts ~= '' then
    local plus_end = #text - #counts + #tostring(e.added or 0) + 1
    table.insert(spans, { #text - #counts, plus_end, 'DiffyAdded' })
    table.insert(spans, { plus_end + 1, #text, 'DiffyRemoved' })
  end
  row.name_col = { #head, #left }
  return text, spans
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

--- True when the current selection is exactly `Unstaged` (left=index,
--- right=worktree) or exactly `Staged` (left=HEAD, right=index) - the only
--- two selections staging keys operate on (§5).
local function staging_pane(session)
  if session.pair.left == 'INDEX' and session.pair.right == 'WORKTREE' then
    return 'unstaged'
  elseif session.pair.left == 'HEAD' and session.pair.right == 'INDEX' then
    return 'staged'
  end
  return nil
end

local function require_staging_pane(session)
  local pane = staging_pane(session)
  if not pane then
    vim.notify('diffy: staging needs the Unstaged or Staged selection', vim.log.levels.WARN)
  end
  return pane
end

--- Both paths of a rename/copy row, or the single path of any other row.
local function row_paths(row)
  local e = row.entry
  if e.status == 'R' or e.status == 'C' then
    return { e.old_path, e.path }
  end
  return { e.path }
end

local function row_at_cursor(session)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  local row = session.tree_rows[lnum]
  if row and row.kind == 'file' then
    return row
  end
  return nil
end

--- Run `git <verb> -- <paths>` and refresh on success (mutations refresh
--- and re-fire `DiffyReady`, §5).
local function git_paths(session, verb, paths)
  local args = { verb, '--' }
  vim.list_extend(args, paths)
  run.git(args, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      if res.code == 0 and session.refresh then
        session.refresh(session)
      end
    end,
  })
end

--- `s`: stage the file (or both paths of a rename pair) at the cursor, or
--- (§8) mark a conflicted ('U') row resolved (warns if markers remain).
function M.stage(session)
  local row = row_at_cursor(session)
  if row and row.entry.status == 'U' then
    require('diffy.conflict').resolve(session, row.entry.path)
    return
  end
  if not require_staging_pane(session) then
    return
  end
  if not row then
    return
  end
  git_paths(session, 'add', row_paths(row))
end

--- `u`: unstage the file (or both paths of a rename pair) at the cursor.
function M.unstage(session)
  if not require_staging_pane(session) then
    return
  end
  local row = row_at_cursor(session)
  if not row then
    return
  end
  git_paths(session, 'reset', row_paths(row))
end

--- `-`: stage from the `Unstaged` pane, unstage from the `Staged` pane.
function M.toggle(session)
  local pane = require_staging_pane(session)
  if not pane then
    return
  end
  if pane == 'unstaged' then
    M.stage(session)
  else
    M.unstage(session)
  end
end

--- `S`: stage every change (tracked and untracked).
function M.stage_all(session)
  if not require_staging_pane(session) then
    return
  end
  run.git({ 'add', '-A' }, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      if res.code == 0 and session.refresh then
        session.refresh(session)
      end
    end,
  })
end

--- `U`: unstage every staged change.
function M.unstage_all(session)
  if not require_staging_pane(session) then
    return
  end
  run.git({ 'reset' }, {
    cwd = session.root,
    session = session,
    on_exit = function(res)
      if res.code == 0 and session.refresh then
        session.refresh(session)
      end
    end,
  })
end

--- Open the diff pair for tree row `row` (a `{kind='file', entry=...}`),
--- or (§8) the 4-window conflict view for an unmerged ('U') row.
function M.open_row(session, row, opts)
  if not row or row.kind ~= 'file' then
    return
  end
  local e = row.entry
  if e.status == 'U' then
    session.current_path = e.path
    M.mark_current(session)
    require('diffy.conflict').enter(session, e.path, opts)
    return
  end
  if session.conflict_active then
    require('diffy.conflict').leave(session)
  end
  local diffpair = require('diffy.diffpair')
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
  M.mark_current(session)
  diffpair.show(session, left_spec, right_spec)
end

--- Locate the tree row for `path` and open its diff pair, updating the
--- tracked current-file line and cursor position (§6 navigation, phase 4).
--- Returns `true` if `path` is in the current file list, `false` otherwise.
function M.open_path(session, path)
  for i, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' and row.entry.path == path then
      session.current_file_line = i
      if vim.api.nvim_win_is_valid(session.wins.tree) then
        pcall(vim.api.nvim_win_set_cursor, session.wins.tree, { i, 0 })
      end
      M.open_row(session, row)
      return true
    end
  end
  return false
end

--- Highlight the row of the file shown in the diff pair (§5).
function M.mark_current(session)
  local buf = session.bufs.tree
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local ns = require('diffy.session').namespace(session, 'tree_current')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row in ipairs(session.tree_rows or {}) do
    if row.kind == 'file' and row.entry.path == session.current_path and row.name_col then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = 'DiffyCurrentFile' })
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, row.name_col[1], {
        end_col = row.name_col[2],
        hl_group = 'DiffyCurrentFileName',
      })
      return
    end
  end
end

local function tree_width(session)
  local win = session.wins.tree
  if win and vim.api.nvim_win_is_valid(win) then
    return hl.text_width(win) - 1
  end
  return session.tree_width or require('diffy').config.panel_width
end

--- Re-render the current rows fitted to the tree window's width (no git).
function M.redraw(session)
  local buf = session.bufs.tree
  local width = tree_width(session)
  session.tree_width = width
  local lines, all_spans = {}, {}
  for i, row in ipairs(session.tree_rows) do
    local text, spans = row_line(row, width)
    lines[i], all_spans[i] = text, spans
  end
  if #lines == 0 then
    lines = { '(no changes)' }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].shiftwidth = 2
  local ns = require('diffy.session').namespace(session, 'tree_render')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, spans in ipairs(all_spans) do
    for _, sp in ipairs(spans) do
      if sp[2] > sp[1] then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, sp[1], { end_col = sp[2], hl_group = sp[3] })
      end
    end
  end
  local win = session.wins.tree
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].foldmethod = 'indent'
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 99
  end
  M.mark_current(session)
end

local render_buffer = M.redraw

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
  session.gen = (session.gen or 0) + 1
  local gen = session.gen
  build_diff_entries(session, gen, function(entries, err)
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
      M.mark_current(session)
    end
    if cb then
      cb()
    end
  end)
end

--- `<CR>`/`o`: open the pair for the entry at the cursor. `<CR>` passes
--- `opts.focus` to then move to the right diff window (the result window in
--- the conflict view); `o` keeps the cursor in the tree.
function M.select_at_cursor(session, opts)
  local lnum = vim.api.nvim_win_get_cursor(session.wins.tree)[1]
  local row = session.tree_rows[lnum]
  if row and row.kind == 'file' then
    session.current_file_line = lnum
    M.open_row(session, row, opts)
    if opts and opts.focus and row.entry.status ~= 'U' and vim.api.nvim_win_is_valid(session.wins.right) then
      vim.api.nvim_set_current_win(session.wins.right)
    end
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
    M.select_at_cursor(session, { focus = true })
  end, { buffer = buf, desc = 'open pair and focus it' })
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
  map(session, 'n', 's', function()
    M.stage(session)
  end, { buffer = buf, desc = 'stage' })
  map(session, 'n', 'u', function()
    M.unstage(session)
  end, { buffer = buf, desc = 'unstage' })
  map(session, 'n', '-', function()
    M.toggle(session)
  end, { buffer = buf, desc = 'toggle stage' })
  map(session, 'n', 'S', function()
    M.stage_all(session)
  end, { buffer = buf, desc = 'stage all' })
  map(session, 'n', 'U', function()
    M.unstage_all(session)
  end, { buffer = buf, desc = 'unstage all' })
  map(session, 'n', 'R', function()
    if session.refresh then
      session.refresh(session)
    end
  end, { buffer = buf, desc = 'rebuild' })
  require('diffy.session').map_toggle(session, buf)
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      local win = session.wins.tree
      if session.tree_rows and win and vim.api.nvim_win_is_valid(win) and tree_width(session) ~= session.tree_width then
        M.redraw(session)
      end
    end,
  })
end

return M
