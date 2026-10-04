-- `:Fixit [text]`: hands what the user wants fixed to an omp worker (the `omp-fixit` CLI,
-- modules/headless/omp-fixit.sh) with a snapshot of this nvim taken when the command ran: what the
-- user typed, ran and saw, the windows, the config and cwd repos, and whatever plugins registered
-- with `add_context` (diffy's sessions). Without text, a float takes it.
local M = {}

local uv = vim.uv

M.config = {
  dir = vim.fn.stdpath('state') .. '/fixit',
  config_dir = vim.fn.resolve(vim.fn.stdpath('config')),
  max_keys = 400,
}

M.providers = {}

--- The config commit checked out when this nvim started: code committed later isn't loaded until
--- a restart.
local loaded_head

local keys = {}
local key_head = 0
local started = uv.hrtime()

local function now_ms()
  return uv.hrtime() / 1e6
end

local function cap(s, n)
  if not s or #s <= n then
    return s
  end
  return s:sub(1, n) .. ('\n[truncated %d bytes]'):format(#s - n)
end

local function sh(cmd, cwd)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = cwd, text = true, env = { GIT_OPTIONAL_LOCKS = '0' } }):wait(3000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return res.stdout
end

local function trim(s)
  return s and vim.trim(s) or nil
end

-- Makes anything JSON-encodable: functions/userdata become strings, tables that aren't lists get
-- string keys, deep structures are cut.
local function sanitize(v, depth)
  local t = type(v)
  if t == 'string' or t == 'number' or t == 'boolean' or v == nil or v == vim.NIL then
    return v
  end
  if t ~= 'table' then
    return '<' .. t .. '>'
  end
  if depth <= 0 then
    return '<table>'
  end
  local out = {}
  if vim.islist(v) then
    for i, x in ipairs(v) do
      out[i] = sanitize(x, depth - 1)
    end
    return out
  end
  for k, x in pairs(v) do
    out[tostring(k)] = sanitize(x, depth - 1)
  end
  return next(out) and out or vim.empty_dict()
end

-- One line per burst of keys in the same mode, timed relative to now.
local function keys_log()
  local n = #keys
  local t = now_ms()
  local lines, cur, cur_mode, cur_start, prev_t = {}, {}, nil, nil, nil
  local function flush()
    if #cur > 0 then
      lines[#lines + 1] = ('%8.2fs %-3s %s'):format((cur_start - t) / 1000, cur_mode, table.concat(cur))
    end
    cur = {}
  end
  for i = 1, n do
    local e = keys[(key_head + i - 1) % n + 1]
    if e.mode ~= cur_mode or (prev_t and e.t - prev_t > 1000) then
      flush()
      cur_mode, cur_start = e.mode, e.t
    end
    cur[#cur + 1] = e.k
    prev_t = e.t
  end
  flush()
  return lines
end

local function repo_state(dir)
  local root = trim(sh({ 'git', 'rev-parse', '--show-toplevel' }, dir))
  if not root then
    return nil
  end
  local gitdir = trim(sh({ 'git', 'rev-parse', '--absolute-git-dir' }, root))
  local in_progress = {}
  for _, f in ipairs({ 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply' }) do
    if gitdir and uv.fs_stat(gitdir .. '/' .. f) then
      in_progress[#in_progress + 1] = f
    end
  end
  return {
    root = root,
    head = trim(sh({ 'git', 'rev-parse', 'HEAD' }, root)),
    branch = trim(sh({ 'git', 'branch', '--show-current' }, root)),
    in_progress = in_progress,
    status = cap(sh({ 'git', 'status', '--porcelain=v1', '--branch', '--untracked-files=all' }, root), 8000),
    staged_diff = cap(sh({ 'git', 'diff', '--cached', '--binary' }, root), 64000),
    unstaged_diff = cap(sh({ 'git', 'diff', '--binary' }, root), 64000),
  }
end

local function config_state()
  local dir = M.config.config_dir
  local root = trim(sh({ 'git', 'rev-parse', '--show-toplevel' }, dir))
  if not root then
    return { dir = dir }
  end
  return {
    dir = dir,
    repo = root,
    loaded_head = loaded_head,
    head = trim(sh({ 'git', 'rev-parse', 'HEAD' }, root)),
    uncommitted = cap(sh({ 'git', 'diff', 'HEAD', '--', dir }, root), 64000),
    untracked = sh({ 'git', 'ls-files', '--others', '--exclude-standard', '--', dir }, root),
  }
end

local function plugins()
  local out = vim.empty_dict()
  local ok, list = pcall(vim.pack.get, nil, { info = false })
  for _, p in ipairs(ok and list or {}) do
    if p.active then
      out[p.spec.name] = p.rev
    end
  end
  return out
end

local function windows()
  local api = vim.api
  local cur = api.nvim_get_current_win()
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    local name = api.nvim_buf_get_name(buf)
    local bt = vim.bo[buf].buftype
    local cursor = api.nvim_win_get_cursor(win)
    local w = {
      win = win,
      current = win == cur,
      float = api.nvim_win_get_config(win).relative ~= '',
      buf = buf,
      name = name,
      filetype = vim.bo[buf].filetype,
      buftype = bt,
      modified = vim.bo[buf].modified,
      line_count = api.nvim_buf_line_count(buf),
      cursor = cursor,
      topline = vim.fn.line('w0', win),
      width = api.nvim_win_get_width(win),
      height = api.nvim_win_get_height(win),
      diff = vim.wo[win].diff,
      winbar = vim.wo[win].winbar ~= '' and vim.wo[win].winbar or nil,
    }
    -- scratch buffers (panels, floats) are UI state no file on disk reproduces
    if bt == 'nofile' or name:match('^%a+://') then
      local first = math.max(0, cursor[1] - 20)
      w.lines_from = first + 1
      w.lines = api.nvim_buf_get_lines(buf, first, cursor[1] + 20, false)
    end
    out[#out + 1] = w
  end
  return out
end

local function tabs()
  local out = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    out[#out + 1] = {
      n = i,
      current = tab == vim.api.nvim_get_current_tabpage(),
      windows = #vim.api.nvim_tabpage_list_wins(tab),
      buffer = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)),
    }
  end
  return out
end

local function tail_lines(s, n)
  local lines = vim.split(s or '', '\n', { trimempty = true })
  return vim.list_slice(lines, math.max(1, #lines - n + 1))
end

--- Register extra context: `fn()` returns a JSON-encodable value stored under `extra[name]` of
--- every snapshot, or nil to leave it out.
function M.add_context(name, fn)
  M.providers[name] = fn
end

--- Snapshot of this nvim.
function M.snapshot()
  local ctx = {}
  local function add(name, fn)
    local ok, v = pcall(fn)
    ctx[name] = ok and v or { snapshot_error = tostring(v) }
  end
  local v = vim.version()
  ctx.time = os.date('%Y-%m-%dT%H:%M:%S%z')
  ctx.nvim = ('%d.%d.%d%s'):format(v.major, v.minor, v.patch, v.prerelease and ('-' .. v.prerelease) or '')
  ctx.uptime_s = math.floor((uv.hrtime() - started) / 1e9)
  ctx.cwd = vim.fn.getcwd()
  ctx.mode = vim.api.nvim_get_mode().mode
  add('config', config_state)
  add('plugins', plugins)
  add('repo', function()
    return repo_state(ctx.cwd)
  end)
  add('keys', keys_log)
  add('cmdline_history', function()
    local out = {}
    for i = 1, 15 do
      local h = vim.fn.histget(':', -i)
      if h == '' then
        break
      end
      out[#out + 1] = h
    end
    return out
  end)
  add('messages', function()
    return tail_lines(vim.api.nvim_exec2('messages', { output = true }).output, 40)
  end)
  add('tabs', tabs)
  add('layout', vim.fn.winlayout)
  add('windows', windows)
  ctx.extra = {}
  for name, fn in pairs(M.providers) do
    local ok, val = pcall(fn)
    if not ok then
      ctx.extra[name] = { snapshot_error = tostring(val) }
    elseif val ~= nil then
      ctx.extra[name] = val
    end
  end
  return ctx
end

local function write_json(path, v)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'w'))
  f:write(vim.json.encode(sanitize(v, 12), { indent = '  ', sort_keys = true }), '\n')
  f:close()
end

local function prompt_for(text, providers)
  local lines = {
    'The user sent this from their nvim:',
    '',
    text,
    '',
    'The state file below is their nvim when they sent it: `keys` and `cmdline_history` are what led to it,',
    '`messages` and `windows` what they saw, `config` the nvim config (in this repo, under nvim/) as loaded.',
  }
  if vim.tbl_contains(providers, 'diffy') then
    lines[#lines + 1] = "`extra.diffy` is diffy's state: diffy is its own repo at ~/projects/diffy, follow its AGENTS.md there."
  end
  vim.list_extend(lines, {
    'Do what they ask, at the root, proven by a test where the code has a suite. If the wish is unclear or',
    'conflicts with existing behaviour, ask instead of guessing. Call `fixit_title` once you know what it is about.',
  })
  return table.concat(lines, '\n')
end

--- Start an omp on `text` with `snapshot` (default: one taken now), from the config's repo.
function M.send(text, snapshot)
  snapshot = snapshot or M.snapshot()
  local path = ('%s/%s-%04x.json'):format(M.config.dir, os.date('%Y%m%dT%H%M%S'), math.random(0, 0xffff))
  write_json(path, snapshot)
  local cwd = snapshot.config.repo or M.config.config_dir
  local cmd = { 'omp-fixit', '--context', path, 'fixit', cwd, prompt_for(text, vim.tbl_keys(snapshot.extra)) }
  local ok, err = pcall(vim.system, cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        vim.notify(('fixit: omp on it in zellij session %s'):format(vim.trim(res.stdout)))
      else
        vim.notify('fixit: ' .. vim.trim(res.stderr), vim.log.levels.WARN)
      end
    end)
  end)
  if not ok then
    vim.notify('fixit: ' .. tostring(err), vim.log.levels.WARN)
  end
end

-- A float to write the text in; the snapshot is taken before it opens, so it shows what the user
-- was looking at.
local function ask(snapshot)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(10, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = ' Fixit: what should change? ',
    footer = ' <C-s> send · q cancel ',
    footer_pos = 'right',
  })
  -- a new window inherits the current one's options, and diffy's windows don't wrap
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  local function close()
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    if text == '' then
      vim.notify('fixit: empty, nothing sent', vim.log.levels.WARN)
    else
      M.send(text, snapshot)
    end
  end, { buffer = buf, desc = 'Send to fixit' })
  vim.keymap.set('n', 'q', close, { buffer = buf, desc = 'Cancel fixit' })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, desc = 'Cancel fixit' })
  vim.cmd.startinsert()
end

local function on_key(_, typed)
  if not typed or typed == '' then
    return
  end
  local e = { t = now_ms(), mode = vim.api.nvim_get_mode().mode, k = vim.fn.keytrans(typed) }
  if #keys < M.config.max_keys then
    keys[#keys + 1] = e
  else
    key_head = key_head % #keys + 1
    keys[key_head] = e
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  -- async: startup doesn't wait on git; pcall: vim.system raises on a missing cwd
  pcall(vim.system, { 'git', 'rev-parse', 'HEAD' }, { cwd = M.config.config_dir, text = true }, function(res)
    if res.code == 0 then
      loaded_head = vim.trim(res.stdout)
    end
  end)
  vim.on_key(on_key, vim.api.nvim_create_namespace('fixit'))
  vim.api.nvim_create_user_command('Fixit', function(args)
    local snapshot = M.snapshot()
    if args.args ~= '' then
      M.send(args.args, snapshot)
    else
      ask(snapshot)
    end
  end, { nargs = '?', desc = 'Hand what should be fixed to an omp, with this nvim’s state' })
end

return M
