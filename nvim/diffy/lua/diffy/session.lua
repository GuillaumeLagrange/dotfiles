-- One session per tabpage: registry, augroup, namespaces, buffer-local
-- keymap tracking, idempotent teardown.
--
-- Session fields:
--   id       unique integer, also used in buffer names (`diffy://<id>/…`)
--            and the augroup name (`diffy_session_<id>`)
--   tab      the owning tabpage handle
--   augroup  this session's augroup id; deleted whole on teardown
--   ns       name -> namespace id
--   wins     name -> window handle for every managed window
--   bufs     name -> buffer handle for every managed buffer
--   keymaps  {buf, mode, lhs} list of buffer-local keymaps set via `M.map`
--   gen      bumped by `panels/tree.lua`'s `M.render` on every call; an
--            async continuation started for an earlier value is stale and
--            must no-op (`git/run.lua`'s `opts.gen`), so rapid selection
--            changes (J/K/...) end up showing the last one regardless of git
--            subprocess completion order
--   closed   set once teardown has run; guards re-entrancy and (via
--            `git/run.lua`'s `opts.session`) makes any async continuation
--            still in flight for this session a no-op
local M = {}

-- id -> session
M.sessions = {}
local next_id = 0

--- Session owning `tab`, or nil.
function M.for_tab(tab)
  for _, s in pairs(M.sessions) do
    if s.tab == tab then
      return s
    end
  end
  return nil
end

--- Session owning the current tabpage, or nil.
function M.current()
  return M.for_tab(vim.api.nvim_get_current_tabpage())
end

--- Namespace `name` for `session`, created on first use. Namespaces
--- themselves are never destroyed (nvim has no such API); teardown instead
--- clears every extmark placed in them, wherever the buffer lives.
function M.namespace(session, name)
  session.ns[name] = session.ns[name] or vim.api.nvim_create_namespace(('diffy/%d/%s'):format(session.id, name))
  return session.ns[name]
end

--- Set a buffer-local keymap and record it for teardown/`unmap_buffer`.
--- `opts.buffer` is required. All diffy keymaps get a `diffy: ` prefixed
--- `desc`, which the leak check relies on to find stragglers.
function M.map(session, modes, lhs, rhs, opts)
  opts = vim.deepcopy(opts or {})
  assert(opts.buffer, 'session.map: opts.buffer is required')
  opts.desc = 'diffy: ' .. (opts.desc or lhs)
  for _, mode in ipairs(type(modes) == 'table' and modes or { modes }) do
    vim.keymap.set(mode, lhs, rhs, opts)
    table.insert(session.keymaps, { buf = opts.buffer, mode = mode, lhs = lhs })
  end
end

--- Remove every tracked keymap on `buf` (e.g. when a real-file buffer
--- leaves a diffy window).
function M.unmap_buffer(session, buf)
  for i = #session.keymaps, 1, -1 do
    local km = session.keymaps[i]
    if km.buf == buf then
      pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
      table.remove(session.keymaps, i)
    end
  end
end

-- Deferred to the next event-loop tick: a `WinClosed`/`BufWipeout` callback
-- can fire while a native multi-window closer (`:tabclose`, `:qa`) is still
-- midway through closing this same tab's other windows; force-closing them
-- from inside that nested callback races the native loop (nvim reports
-- E444 on a now-misnumbered tab). Scheduling runs teardown only once the
-- triggering command has fully finished, by which point a `:tabclose` has
-- already closed everything itself and teardown's window/tab steps are
-- no-ops, while a lone `:q` still has its siblings open for teardown to
-- close.
local function watch_close(session, win)
  local au_id = vim.api.nvim_create_autocmd('WinClosed', {
    group = session.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        M.teardown(session)
      end)
    end,
  })
  session._win_watchers = session._win_watchers or {}
  session._win_watchers[win] = au_id
end

local function watch_wipe(session, buf)
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = session.augroup,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        M.teardown(session)
      end)
    end,
  })
end

--- Register a managed window under `name` (`session.wins[name]`). Closing
--- any managed window (`:q`, `:close`, …) tears down the whole session.
function M.register_window(session, name, win)
  session.wins[name] = win
  watch_close(session, win)
end

--- Reverse of `register_window`: stop watching `session.wins[name]` for
--- auto-teardown and drop it from the registry, without closing it (the
--- caller closes it). Used when a window is replaced without ending the
--- session, e.g. the conflict layout reverting to the 2-window pair.
function M.unregister_window(session, name)
  local win = session.wins[name]
  if win and session._win_watchers and session._win_watchers[win] then
    pcall(vim.api.nvim_del_autocmd, session._win_watchers[win])
    session._win_watchers[win] = nil
  end
  session.wins[name] = nil
end

--- Register a managed buffer under `name` (`session.bufs[name]`).
--- `bufhidden=wipe` always. Pass
--- `opts.panel = true` for buffers whose own `:bwipe` should tear down the
--- whole session (tree/log); diff-content buffers get swapped constantly by
--- refreshes and must NOT trigger teardown when wiped.
function M.register_buffer(session, name, buf, opts)
  opts = opts or {}
  session.bufs[name] = buf
  vim.bo[buf].bufhidden = 'wipe'
  if opts.panel then
    watch_wipe(session, buf)
  end
end

--- Create a new, uniquely-named scratch buffer (`diffy://<id>/<name>/<n>`)
--- for panel/diff content. Each needs a fresh name: the outgoing buffer
--- (`bufhidden=wipe`) may still be alive until the window is actually
--- repointed at the new one.
function M.scratch_buf(session, name)
  session._buf_seq = (session._buf_seq or 0) + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, ('diffy://%d/%s/%d'):format(session.id, name, session._buf_seq))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  return buf
end

local function panel_width()
  return require('diffy').config.panel_width
end

local PANEL_LABELS = { tree = ' Files', log = ' Commits' }

--- Window-local look of a panel window: nothing but the rows.
local function setup_panel_window(win, name)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.statuscolumn = ''
  wo.wrap = false
  wo.list = false
  wo.colorcolumn = ''
  wo.spell = false
  wo.cursorline = true
  wo.winfixwidth = true
  wo.statusline = PANEL_LABELS[name]
end

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Reset window sizes: fixed-width panel column (log = min(#entries,
--- 40% of the column), tree the rest), diff area split evenly over what's
--- left (the full width while the panel column is hidden). Called on open,
--- on `R`, on `VimResized` and on panel toggle.
function M.relayout(session)
  local w = session.wins
  local shown = valid_win(w.tree)
  if not shown and not session.panel_hidden then
    return
  end
  local width = panel_width()
  if shown then
    vim.api.nvim_win_set_width(w.tree, width)
  end
  local left, right = w.left, w.right
  if valid_win(left) and valid_win(right) then
    -- only the side-by-side pair; the conflict layout sizes its own windows
    if vim.fn.win_screenpos(left)[1] == vim.fn.win_screenpos(right)[1] then
      local diff_width = vim.o.columns - (shown and (width + 1) or 0)
      vim.api.nvim_win_set_width(left, math.floor((diff_width - 1) / 2))
    end
  end
  if not shown then
    return
  end
  session.column_height = vim.api.nvim_win_get_height(w.tree)
  if valid_win(w.log) then
    session.column_height = session.column_height + vim.api.nvim_win_get_height(w.log)
    if session.entries and #session.entries > 0 then
      local h = math.max(1, math.min(#session.entries, math.floor(session.column_height * 0.4)))
      vim.api.nvim_win_set_height(w.log, h)
    end
  end
end

--- Hide the panel column without ending the session: the
--- windows' teardown watchers are dropped first and the panel buffers kept
--- (`bufhidden=hide`) so they come back unchanged.
function M.hide_panels(session)
  if session.panel_hidden then
    return
  end
  session._panel_cursor = {}
  local to_close = {}
  for _, name in ipairs({ 'tree', 'log' }) do
    local win = session.wins[name]
    if valid_win(win) then
      session._panel_cursor[name] = vim.api.nvim_win_get_cursor(win)
      local au = session._win_watchers and session._win_watchers[win]
      if au then
        pcall(vim.api.nvim_del_autocmd, au)
        session._win_watchers[win] = nil
      end
      vim.bo[session.bufs[name]].bufhidden = 'hide'
      table.insert(to_close, win)
    end
  end
  session.panel_hidden = true
  for _, win in ipairs(to_close) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  M.relayout(session)
end

--- Re-open the panel column with the same tree/log buffers and cursors.
function M.show_panels(session)
  if not session.panel_hidden then
    return
  end
  session._nav_guard = (session._nav_guard or 0) + 1
  local tree_win = vim.api.nvim_open_win(session.bufs.tree, false, { win = -1, split = 'left', width = panel_width() })
  local log_win = vim.api.nvim_open_win(session.bufs.log, false, { win = tree_win, split = 'below', height = 10 })
  session._nav_guard = session._nav_guard - 1
  for name, win in pairs({ tree = tree_win, log = log_win }) do
    vim.bo[session.bufs[name]].bufhidden = 'wipe'
    M.register_window(session, name, win)
    setup_panel_window(win, name)
    local cur = session._panel_cursor and session._panel_cursor[name]
    if cur then
      pcall(vim.api.nvim_win_set_cursor, win, cur)
    end
  end
  session.panel_hidden = false
  M.relayout(session)
  if session.tree_rows then
    require('diffy.panels.tree').redraw(session)
  end
  if session.entries then
    require('diffy.panels.log').render(session)
  end
end

function M.toggle_panels(session)
  if session.panel_hidden then
    M.show_panels(session)
  else
    M.hide_panels(session)
  end
end

--- Buffer-local panel-toggle key (configurable) on `buf`.
function M.map_toggle(session, buf)
  local lhs = require('diffy').config.keymaps.toggle_panel
  if lhs and lhs ~= '' then
    M.map(session, 'n', lhs, function()
      M.toggle_panels(session)
    end, { buffer = buf, nowait = true, desc = 'toggle panels' })
  end
end

--- Open a new session: its own tabpage with tree and log panels stacked in
--- a fixed-width left column and left/right diff windows filling the rest,
--- all holding placeholder buffers until content is rendered.
--- @param opts { root?: string, range?: table }  `root` is the repo root
---   (absolute path); `range` is the log range spec (see panels/log.lua's
---   `build_entries`).
function M.open(opts)
  opts = opts or {}
  next_id = next_id + 1
  local session = {
    id = next_id,
    tab = nil,
    prev_tab = vim.api.nvim_get_current_tabpage(),
    root = opts.root,
    gitdir = opts.root and vim.fn.FugitiveExtractGitDir(opts.root) or nil,
    range = opts.range,
    augroup = vim.api.nvim_create_augroup(('diffy_session_%d'):format(next_id), { clear = true }),
    ns = {},
    wins = {},
    bufs = {},
    keymaps = {},
    gen = 0,
    closed = false,
  }

  -- open the tab on a diffy buffer so tabnew's listed [No Name] never exists
  local left_buf = M.scratch_buf(session, 'left')
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, { 'diffy: nothing loaded yet' })
  vim.cmd(('tab sbuffer %d'):format(left_buf))
  session.tab = vim.api.nvim_get_current_tabpage()

  local left_win = vim.api.nvim_get_current_win()
  M.register_buffer(session, 'left', left_buf)
  M.register_window(session, 'left', left_win)

  local right_buf = M.scratch_buf(session, 'right')
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { 'diffy: nothing loaded yet' })
  local right_win = vim.api.nvim_open_win(right_buf, false, { win = left_win, split = 'right' })
  M.register_buffer(session, 'right', right_buf)
  M.register_window(session, 'right', right_win)

  local tree_buf = M.scratch_buf(session, 'tree')
  local tree_win = vim.api.nvim_open_win(tree_buf, false, { win = -1, split = 'left', width = panel_width() })
  M.register_buffer(session, 'tree', tree_buf, { panel = true })
  M.register_window(session, 'tree', tree_win)

  local log_buf = M.scratch_buf(session, 'log')
  local log_win = vim.api.nvim_open_win(log_buf, false, { win = tree_win, split = 'below', height = 10 })
  M.register_buffer(session, 'log', log_buf, { panel = true })
  M.register_window(session, 'log', log_win)

  setup_panel_window(tree_win, 'tree')
  setup_panel_window(log_win, 'log')
  -- panel indentation is layout, not code scope (mini.indentscope)
  vim.b[tree_buf].miniindentscope_disable = true
  vim.b[log_buf].miniindentscope_disable = true
  require('diffy.highlight').setup()
  M.relayout(session)
  vim.api.nvim_create_autocmd('VimResized', {
    group = session.augroup,
    callback = function()
      M.relayout(session)
    end,
  })

  vim.api.nvim_set_current_win(left_win)

  M.sessions[session.id] = session
  return session
end

--- Idempotent teardown: closes managed windows/buffers, deletes the
--- augroup, removes tracked keymaps, clears extmarks in this session's
--- namespaces from every buffer, and closes the tab if still open. Windows
--- and the tab may already be gone.
function M.teardown(session)
  if not session or session.closed then
    return
  end
  session.closed = true
  M.sessions[session.id] = nil

  -- best-effort restore of an active full checkout; skipped while nvim is
  -- exiting, where checkout.lua's VimLeavePre handler does it synchronously.
  if session.checkout and vim.v.exiting == vim.NIL then
    require('diffy.checkout').leave_on_teardown(session)
  end

  pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
  -- images are drawn on the terminal, outside any window
  if package.loaded['diffy.avatar'] then
    require('diffy.avatar').clear(session.id)
  end

  for _, km in ipairs(session.keymaps) do
    if km.buf and vim.api.nvim_buf_is_valid(km.buf) then
      pcall(vim.keymap.del, km.mode, km.lhs, { buffer = km.buf })
    end
  end
  session.keymaps = {}

  if next(session.ns) then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      for _, ns in pairs(session.ns) do
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
      end
    end
  end

  for _, win in pairs(session.wins) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in pairs(session.bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  if vim.api.nvim_tabpage_is_valid(session.tab) then
    local ok, tabnr = pcall(vim.api.nvim_tabpage_get_number, session.tab)
    if ok then
      pcall(vim.cmd, tabnr .. 'tabclose')
    end
  end
end

-- Plugin-wide infrastructure, independent of any one session's lifetime.
-- Named without the `diffy_session_` prefix so the leak check (which looks
-- for that prefix) never flags it.
local reaper_group = vim.api.nvim_create_augroup('diffy_reaper', { clear = true })

vim.api.nvim_create_autocmd('TabClosed', {
  group = reaper_group,
  desc = 'diffy: reap sessions whose tab closed directly (:tabclose, :qa)',
  callback = function()
    for _, s in pairs(M.sessions) do
      if not vim.api.nvim_tabpage_is_valid(s.tab) then
        M.teardown(s)
      end
    end
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = reaper_group,
  desc = 'diffy: tear down every open session before exiting',
  callback = function()
    for _, s in pairs(M.sessions) do
      M.teardown(s)
    end
  end,
})

return M
