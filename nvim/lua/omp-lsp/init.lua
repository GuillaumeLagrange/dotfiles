-- Serves omp's `lsp` tool, and the diagnostics after its edits, from this nvim's LSP clients:
-- omp never runs a language server of its own (see ai/omp/extensions/nvim-bridge/).
--
-- nvim connects to the bridge socket of every live omp whose cwd overlaps its own, announces
-- itself with `{"op":"lsp_provide"}` and then answers `{"id","method","params"}` requests with
-- `{"id","result"}` or `{"id","error"}`, NDJSON both ways. Every handler is callback-driven:
-- nothing here waits on the main loop.

local M = {}

local uv = vim.uv
local api = vim.api

-- Overridable so tests stay out of the real session registry.
local RUN_DIR = vim.env.OMP_NVIM_BRIDGE_DIR or vim.fs.normalize('~/.omp/run/nvim-bridge')

M.config = {
  -- Hidden buffers loaded for omp are wiped after this long without a request.
  hidden_ttl_ms = 5 * 60 * 1000,
  -- How long a freshly loaded buffer may take to get a language server attached.
  attach_timeout_ms = 5000,
  -- Diagnostics count as settled once none changed for this long...
  quiet_ms = 600,
  -- ...and never sooner than this after the save, nor this when a push-only server is involved.
  settle_min_ms = 300,
  push_min_ms = 1000,
  -- A burst of omp edits to one buffer is one didSave.
  save_debounce_ms = 150,
  -- Navigating a buffer omp just loaded waits at least this long for its servers to start working.
  fresh_ms = 1000,
}

local function now()
  return uv.hrtime() / 1e6
end

local function json_encode(value)
  return vim.json.encode(value)
end

---------------------------------------------------------------------------------------------------
-- Tracking: what the language servers are busy with, when diagnostics last changed.

---@type table<integer, table<string|integer, string>> client id -> progress token -> title
local progress = {}
---@type table<integer, { t: number, title: string }> client id -> its latest progress event
local last_progress = {}
---@type table<integer, number> bufnr -> time its diagnostics last changed
local changed_at = {}

--- Clients that are language servers, not completion helpers such as Copilot.
---@param bufnr integer
---@return vim.lsp.Client[]
local function lang_clients(bufnr)
  return vim.tbl_filter(function(c)
    return c:supports_method('textDocument/hover', bufnr)
      or c:supports_method('textDocument/definition', bufnr)
      or c:supports_method('textDocument/diagnostic', bufnr)
  end, vim.lsp.get_clients({ bufnr = bufnr }))
end

--- Work in flight, and work that ended too recently to tell a pause between two steps (loading
--- a project is a chain of them) from the end.
---@param clients table<integer, vim.lsp.Client>
---@return string[] titles
local function busy(clients)
  local titles = {}
  for id in pairs(clients) do
    if vim.lsp.get_client_by_id(id) then
      for _, title in pairs(progress[id] or {}) do
        titles[#titles + 1] = title
      end
      local last = last_progress[id]
      if #titles == 0 and last and now() - last.t < M.config.quiet_ms then
        titles[#titles + 1] = last.title
      end
    else
      progress[id] = nil
      last_progress[id] = nil
    end
  end
  table.sort(titles)
  return vim.fn.uniq(titles)
end

--- Polls `check` every 50 ms until it returns true or `budget_ms` runs out.
---@param budget_ms number
---@param check fun(elapsed: number): boolean
---@param done fun(timed_out: boolean)
local function poll(budget_ms, check, done)
  local t0 = now()
  if check(0) then
    return done(false)
  end
  local timer = assert(uv.new_timer())
  timer:start(
    50,
    50,
    vim.schedule_wrap(function()
      if timer:is_closing() then
        return
      end
      local elapsed = now() - t0
      local ok = check(elapsed)
      if ok or elapsed >= budget_ms then
        timer:stop()
        timer:close()
        done(not ok)
      end
    end)
  )
end

---------------------------------------------------------------------------------------------------
-- Buffers

---@type table<integer, { wipe: boolean, last: number }> buffers loaded on omp's behalf
local owned = {}

--- The loaded buffer of `path`, matched exactly (`bufnr()` would treat `[id].tsx` as a pattern).
---@param path string
---@return integer?
local function loaded_buf(path)
  if vim.fn.bufexists(path) ~= 1 then
    return nil
  end
  local bufnr = vim.fn.bufadd(path)
  return api.nvim_buf_is_loaded(bufnr) and bufnr or nil
end

---@param path string absolute
---@return integer bufnr
local function ensure_buf(path)
  local existed = vim.fn.bufexists(path) == 1
  local bufnr = vim.fn.bufadd(path)
  if not api.nvim_buf_is_loaded(bufnr) then
    if not existed then
      vim.bo[bufnr].buflisted = false
    end
    vim.bo[bufnr].swapfile = false
    vim.fn.bufload(bufnr)
    owned[bufnr] = { wipe = not existed, last = now(), loaded = now() }
  elseif owned[bufnr] then
    owned[bufnr].last = now()
  end
  return bufnr
end

--- The user opened a buffer omp had loaded: it is theirs now.
---@param bufnr integer
local function release(bufnr)
  if not owned[bufnr] then
    return
  end
  owned[bufnr] = nil
  if api.nvim_buf_is_loaded(bufnr) then
    vim.bo[bufnr].swapfile = vim.go.swapfile
  end
end

local function sweep()
  local t = now()
  for bufnr, info in pairs(owned) do
    if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
      owned[bufnr] = nil
    elseif t - info.last > M.config.hidden_ttl_ms and vim.fn.bufwinid(bufnr) == -1 and not vim.bo[bufnr].modified then
      owned[bufnr] = nil
      pcall(api.nvim_buf_delete, bufnr, { unload = not info.wipe })
    end
  end
end

--- Reload a buffer whose file omp changed, unless it holds unsaved changes: those are the
--- user's, and nvim's own conflict handling applies when they get back to it.
---@param bufnr integer
---@return 'dirty'|'reloaded'|'same'
local function refresh(bufnr)
  if vim.bo[bufnr].modified then
    return 'dirty'
  end
  local tick = vim.b[bufnr].changedtick
  vim.cmd.checktime(bufnr)
  return vim.b[bufnr].changedtick ~= tick and 'reloaded' or 'same'
end

---@param bufnr integer
---@param timeout_ms number
---@param cb fun(clients: vim.lsp.Client[])
local function with_clients(bufnr, fresh, timeout_ms, cb)
  -- A server that will serve a just-loaded buffer shows up as attached within moments, even
  -- before it is initialized: without one, there is nothing to wait for.
  local function coming()
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      if not c.initialized or #lang_clients(bufnr) > 0 then
        return true
      end
    end
    return false
  end
  poll(fresh and 500 or 0, coming, function(none)
    if none then
      return cb({})
    end
    poll(timeout_ms, function()
      return #lang_clients(bufnr) > 0
    end, function()
      cb(lang_clients(bufnr))
    end)
  end)
end

---@type table<integer, { timer: uv.uv_timer_t, cbs: fun()[] }>
local pending_saves = {}

--- What `:w` tells the language servers, without writing or running the user's write autocmds:
--- nvim's own BufWritePost handler sends didSave to every client of the buffer.
---@param bufnr integer
local function notify_saved(bufnr)
  local ok = pcall(api.nvim_exec_autocmds, 'BufWritePost', {
    group = ('nvim.lsp.b_%d_save'):format(bufnr),
    buffer = bufnr,
  })
  if not ok then
    pcall(vim.lsp._changetracking._send_did_save, bufnr)
  end
end

---@param bufnr integer
---@param cb fun() once the didSave went out
local function save(bufnr, cb)
  local entry = pending_saves[bufnr]
  if not entry then
    entry = { timer = assert(uv.new_timer()), cbs = {} }
    pending_saves[bufnr] = entry
  end
  entry.cbs[#entry.cbs + 1] = cb
  entry.timer:stop()
  entry.timer:start(
    M.config.save_debounce_ms,
    0,
    vim.schedule_wrap(function()
      pending_saves[bufnr] = nil
      entry.timer:close()
      if api.nvim_buf_is_loaded(bufnr) then
        notify_saved(bufnr)
      end
      for _, f in ipairs(entry.cbs) do
        f()
      end
    end)
  )
end

--- Changed buffers among `before` (changedtick snapshot) get written, unless they had unsaved
--- changes before the operation: like `:w` after a rename in nvim, formatters included.
---@param before table<integer, { tick: integer, modified: boolean, loaded: boolean }>
---@return string[] written, string[] left unsaved
local function write_touched(before)
  local written, unsaved = {}, {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == '' then
      local prev = before[bufnr]
      if not prev or not prev.loaded or prev.tick ~= vim.b[bufnr].changedtick then
        local name = api.nvim_buf_get_name(bufnr)
        if prev and prev.modified then
          unsaved[#unsaved + 1] = name
        elseif vim.bo[bufnr].modified then
          local ok = pcall(api.nvim_buf_call, bufnr, function()
            vim.cmd('silent write')
          end)
          if ok then
            written[#written + 1] = name
          else
            unsaved[#unsaved + 1] = name
          end
        end
        -- Buffers the edit had to load stay as listed as they were, and get unloaded later.
        if (not prev or not prev.loaded) and vim.fn.bufwinid(bufnr) == -1 then
          vim.bo[bufnr].buflisted = prev and prev.listed or false
          owned[bufnr] = { wipe = not prev, last = now() }
        end
      end
    end
  end
  return written, unsaved
end

local function snapshot()
  local snap = {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    snap[bufnr] = {
      tick = vim.b[bufnr].changedtick,
      modified = vim.bo[bufnr].modified,
      loaded = api.nvim_buf_is_loaded(bufnr),
      listed = vim.bo[bufnr].buflisted,
    }
  end
  return snap
end

---------------------------------------------------------------------------------------------------
-- Diagnostics

local severity = { 'error', 'warning', 'info', 'hint' }

---@param bufnr integer
local function collect(bufnr, min_severity)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, min_severity and { severity = { min = min_severity } } or nil)) do
    out[#out + 1] = {
      line = d.lnum + 1,
      col = d.col + 1,
      severity = severity[d.severity] or 'error',
      message = d.message,
      source = d.source,
      code = d.code ~= nil and tostring(d.code) or nil,
    }
  end
  table.sort(out, function(a, b)
    return a.line == b.line and a.col < b.col or a.line < b.line
  end)
  return out
end

--- Waits until the buffers' diagnostics are what their servers think of the current text.
---@param bufs integer[]
---@param budget_ms number
---@param cb fun(timed_out: boolean, still_running: string[], t0: number)
local function settle(bufs, budget_ms, cb)
  local t0 = now()
  local clients = {} ---@type table<integer, vim.lsp.Client>
  local pulls = 0
  local push_only = false
  for _, bufnr in ipairs(bufs) do
    for _, c in ipairs(lang_clients(bufnr)) do
      clients[c.id] = c
      if c:supports_method('textDocument/diagnostic', bufnr) then
        pulls = pulls + 1
        local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
        c:request('textDocument/diagnostic', params, function(err, result, ctx, config)
          -- Through nvim's own handler, so the answer lands where nvim shows it.
          local handler = c.handlers['textDocument/diagnostic'] or vim.lsp.handlers['textDocument/diagnostic']
          pcall(handler, err, result, ctx, config)
          pulls = pulls - 1
        end, bufnr)
      else
        push_only = true
      end
    end
  end
  poll(budget_ms, function(elapsed)
    if pulls > 0 or elapsed < M.config.settle_min_ms or (push_only and elapsed < M.config.push_min_ms) then
      return false
    end
    if #busy(clients) > 0 then
      return false
    end
    local last = t0
    for _, bufnr in ipairs(bufs) do
      last = math.max(last, changed_at[bufnr] or 0)
    end
    return now() - last >= M.config.quiet_ms
  end, function(timed_out)
    cb(timed_out, timed_out and busy(clients) or {}, t0)
  end)
end

--- Errors that showed up in other files since `t0`, e.g. call sites of a changed signature.
---@param skip table<integer, boolean>
---@param t0 number
---@param root string
local function errors_elsewhere(skip, t0, root)
  local out = {}
  for bufnr, t in pairs(changed_at) do
    if t >= t0 and not skip[bufnr] and api.nvim_buf_is_valid(bufnr) then
      local file = api.nvim_buf_get_name(bufnr)
      if vim.startswith(file, root) then
        local errors = collect(bufnr, vim.diagnostic.severity.ERROR)
        if #errors > 0 then
          out[#out + 1] = { file = file, diagnostics = errors }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.file < b.file
  end)
  return out
end

---------------------------------------------------------------------------------------------------
-- Positions and locations

--- Byte column (0-based) of `symbol` on `text`: `name#N` picks the Nth occurrence; a bare
--- identifier only matches on identifier boundaries; exact case first, then any case.
---@return integer? col, string? err
local function find_col(text, symbol)
  local name, nth = symbol:match('^(.-)#(%d+)$')
  if not name or name == '' then
    name, nth = symbol, '1'
  end
  local n = tonumber(nth) --[[@as integer]]
  local ident = name:match('^[%w_]+$') ~= nil
  local function scan(hay, needle)
    local hits, init = {}, 1
    while true do
      local s, e = hay:find(needle, init, true)
      if not s then
        return hits
      end
      if not ident or ((s == 1 or not hay:sub(s - 1, s - 1):match('[%w_]')) and (e == #hay or not hay:sub(e + 1, e + 1):match('[%w_]'))) then
        hits[#hits + 1] = s
      end
      init = s + 1
    end
  end
  local hits = scan(text, name)
  if #hits == 0 then
    hits = scan(text:lower(), name:lower())
  end
  if #hits == 0 then
    return nil, ('symbol %q not found on line: %s'):format(name, vim.trim(text))
  end
  if n > #hits then
    return nil, ('symbol %q occurs %d time(s) on that line, #%d requested'):format(name, #hits, n)
  end
  return hits[n] - 1
end

---@param bufnr integer
---@param p table { line?: integer, symbol?: string }
---@return (fun(c: vim.lsp.Client): lsp.Position)? make, string? err
local function position(bufnr, p)
  local line = math.max((p.line or 1) - 1, 0)
  local text = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not text then
    return nil, ('line %d is past the end of the file (%d lines)'):format(line + 1, api.nvim_buf_line_count(bufnr))
  end
  local col
  if p.symbol and p.symbol ~= '' then
    local err
    col, err = find_col(text, p.symbol)
    if not col then
      return nil, err
    end
  else
    col = #text:match('^%s*')
  end
  return function(c)
    return { line = line, character = vim.str_utfindex(text, c.offset_encoding, col, false) }
  end
end

--- Reads lines of files that may or may not be loaded, once per file.
local function line_reader()
  local cache = {}
  return function(file, lnum)
    local lines = cache[file]
    if not lines then
      local bufnr = loaded_buf(file)
      if bufnr then
        lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      else
        local ok, read = pcall(vim.fn.readfile, file)
        lines = ok and read or {}
      end
      cache[file] = lines
    end
    return lines[lnum]
  end
end

---@param result any Location | Location[] | LocationLink[] | nil
---@param encoding string
---@param read fun(file: string, lnum: integer): string?
---@param out table[]
---@param seen table<string, boolean>
local function add_locations(result, encoding, read, out, seen)
  if not result or result == vim.NIL then
    return
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  for _, loc in ipairs(result) do
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange or loc.targetRange
    if uri and range then
      local file = vim.uri_to_fname(uri)
      local lnum = range.start.line + 1
      local text = read(file, lnum)
      local col = range.start.character + 1
      if text then
        col = vim.str_byteindex(text, encoding, range.start.character, false) + 1
      end
      local key = ('%s:%d:%d'):format(file, lnum, col)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { file = file, line = lnum, col = col, text = text and vim.trim(text) or nil }
      end
    end
  end
end

-- Errors a server answers while it is (re)loading the project: the request is worth repeating.
local RETRYABLE = {
  [vim.lsp.protocol.ErrorCodes.ContentModified] = true,
  [vim.lsp.protocol.ErrorCodes.ServerCancelled] = true,
}

--- Sends `method` to every language server of the buffer that supports it.
---@param bufnr integer
---@param method string
---@param params fun(c: vim.lsp.Client): table
---@param cb fun(results: { client: vim.lsp.Client, err: any, result: any }[])
local function request_all(bufnr, method, params, cb)
  local clients = vim.tbl_filter(function(c)
    return c:supports_method(method, bufnr)
  end, lang_clients(bufnr))
  if #clients == 0 then
    return cb({})
  end
  local results, left = {}, #clients
  local function attempt(c, n)
    c:request(method, params(c), function(err, result)
      if err and RETRYABLE[err.code] and n < 10 then
        return vim.defer_fn(function()
          attempt(c, n + 1)
        end, 300)
      end
      results[#results + 1] = { client = c, err = err, result = result }
      left = left - 1
      if left == 0 then
        cb(results)
      end
    end, bufnr)
  end
  for _, c in ipairs(clients) do
    attempt(c, 1)
  end
end

local function errors_of(results)
  local errs = {}
  for _, r in ipairs(results) do
    if r.err then
      errs[#errs + 1] = ('%s: %s'):format(r.client.name, r.err.message or vim.inspect(r.err))
    end
  end
  return errs
end

local function hover_text(contents)
  if type(contents) == 'string' then
    return contents
  end
  if contents.value then
    return contents.value
  end
  local parts = {}
  for _, c in ipairs(contents) do
    parts[#parts + 1] = hover_text(c)
  end
  return table.concat(parts, '\n\n')
end

local function symbol_tree(symbols, encoding, file)
  local out = {}
  for _, s in ipairs(symbols or {}) do
    local range = s.selectionRange or (s.location and s.location.range) or s.range
    out[#out + 1] = {
      name = s.name,
      kind = vim.lsp.protocol.SymbolKind[s.kind] or tostring(s.kind),
      detail = s.detail,
      container = s.containerName,
      file = s.location and vim.uri_to_fname(s.location.uri) or file,
      line = range and range.start.line + 1 or nil,
      children = s.children and symbol_tree(s.children, encoding, file) or nil,
    }
  end
  return out
end

--- Summary of a WorkspaceEdit: files and the lines it changes.
local function summarize_edit(edit, read)
  local files = {}
  local function add(uri, edits)
    local file = vim.uri_to_fname(uri)
    local entry = files[file] or { file = file, edits = {} }
    files[file] = entry
    for _, e in ipairs(edits) do
      local range = e.range or (e.textEdit and e.textEdit.range)
      if range then
        entry.edits[#entry.edits + 1] = {
          line = range.start.line + 1,
          old = read(file, range.start.line + 1),
          new = e.newText,
        }
      end
    end
  end
  for uri, edits in pairs(edit.changes or {}) do
    add(uri, edits)
  end
  local ops = {}
  for _, change in ipairs(edit.documentChanges or {}) do
    if change.textDocument then
      add(change.textDocument.uri, change.edits)
    elseif change.kind then
      ops[#ops + 1] = ('%s %s%s'):format(
        change.kind,
        vim.uri_to_fname(change.uri or change.oldUri),
        change.newUri and (' → ' .. vim.uri_to_fname(change.newUri)) or ''
      )
    end
  end
  local out = vim.tbl_values(files)
  table.sort(out, function(a, b)
    return a.file < b.file
  end)
  return { files = out, operations = ops }
end

---------------------------------------------------------------------------------------------------
-- Methods omp calls. Each gets the decoded params and `reply(result)` / `fail(message)`.

local methods = {}

--- Brings a file's buffer up to date and its clients attached. `cb(bufnr, state, clients)`.
local function prepare(p, cb)
  local path = p.file
  if not path or not uv.fs_stat(path) then
    return cb(nil, ('no such file: %s'):format(tostring(path)))
  end
  local was_loaded = loaded_buf(path) ~= nil
  local bufnr = ensure_buf(path)
  local state = was_loaded and refresh(bufnr) or 'loaded'
  with_clients(bufnr, not was_loaded, M.config.attach_timeout_ms, function(clients)
    if #clients == 0 then
      return cb(nil, ('nvim has no language server for %s (filetype %q)'):format(path, vim.bo[bufnr].filetype))
    end
    cb(bufnr, state, clients)
  end)
end

--- Waits for the servers to finish loading the project before navigating it. A buffer omp just
--- loaded gets a moment first: servers only start that work (and report it) once it opens.
local function when_idle(bufnr, clients, budget_ms, cb)
  local set = {}
  for _, c in ipairs(clients) do
    set[c.id] = c
  end
  local since = owned[bufnr] and owned[bufnr].loaded or 0
  poll(budget_ms, function()
    return now() - since >= M.config.fresh_ms and #busy(set) == 0
  end, cb)
end

local function dirty_note(state)
  return state == 'dirty' and 'nvim has unsaved changes in this buffer: answers reflect nvim, not the file on disk' or nil
end

--- Calls `cb()` once `n` calls of the returned function happened (at once when `n` is 0).
local function join(n, cb)
  if n == 0 then
    cb()
    return function() end
  end
  return function()
    n = n - 1
    if n == 0 then
      cb()
    end
  end
end

--- Brings the files' buffers up to date, optionally tells their servers they were saved, waits
--- for the diagnostics to settle and collects them.
---@param p { files: string[], budget_ms?: number, root?: string }
---@param saving boolean
local function check(p, saving, reply)
  local files, bufs, seen, notes = {}, {}, {}, {}
  local function finish()
    if #bufs == 0 then
      return reply({ files = files, notes = notes })
    end
    settle(bufs, p.budget_ms or 10000, function(timed_out, running, t0)
      for _, f in ipairs(files) do
        if f.bufnr then
          f.diagnostics = collect(f.bufnr)
          f.bufnr = nil
        end
      end
      reply({
        files = files,
        notes = notes,
        timed_out = timed_out,
        still_running = running,
        elsewhere = saving and errors_elsewhere(seen, t0, p.root or '/') or nil,
      })
    end)
  end
  local saves = {} ---@type integer[]
  local prepared = join(#p.files, function()
    local saved = join(#saves, finish)
    for _, bufnr in ipairs(saves) do
      save(bufnr, saved)
    end
  end)
  for _, file in ipairs(p.files) do
    prepare({ file = file }, function(bufnr, state)
      if not bufnr then
        -- After an edit, a file no server handles has nothing to report.
        if not saving then
          files[#files + 1] = { file = file, error = state }
        end
      elseif not seen[bufnr] then
        seen[bufnr] = true
        bufs[#bufs + 1] = bufnr
        files[#files + 1] = { file = file, state = state, bufnr = bufnr }
        if state == 'dirty' then
          notes[#notes + 1] = ('%s: %s'):format(file, dirty_note(state))
        elseif saving then
          saves[#saves + 1] = bufnr
        end
      end
      prepared()
    end)
  end
end

--- After omp changed files: reload, tell the servers they were saved, collect the diagnostics.
function methods.edited(p, reply)
  check(p, true, reply)
end

--- After a command that may have changed files (bash, eval…): reload what changed on disk.
function methods.refresh(p, reply)
  local reloaded = {}
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(bufnr)
    if
      api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ''
      and name ~= ''
      and vim.startswith(name, p.root or '/')
      and uv.fs_stat(name)
      and refresh(bufnr) == 'reloaded'
    then
      reloaded[#reloaded + 1] = name
    end
  end
  reply({ reloaded = reloaded })
end

function methods.diagnostics(p, reply)
  check(p, false, reply)
end

--- Everything nvim has diagnostics for under the root, as nvim shows it.
function methods.workspace_diagnostics(p, reply)
  local bufs = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    bufs[d.bufnr] = true
  end
  local files = {}
  for bufnr in pairs(bufs) do
    local name = api.nvim_buf_get_name(bufnr)
    if vim.startswith(name, (p.root or '') .. '/') then
      files[#files + 1] = { file = name, diagnostics = collect(bufnr) }
    end
  end
  table.sort(files, function(a, b)
    return a.file < b.file
  end)
  reply({ files = files })
end

local location_methods = {
  definition = 'textDocument/definition',
  type_definition = 'textDocument/typeDefinition',
  implementation = 'textDocument/implementation',
  references = 'textDocument/references',
}

function methods.locations(p, reply, fail)
  local method = location_methods[p.kind]
  if not method then
    return fail('unknown location kind: ' .. tostring(p.kind))
  end
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    local make, err = position(bufnr, p)
    if not make then
      return fail(err)
    end
    when_idle(bufnr, clients, p.budget_ms or 15000, function()
      request_all(bufnr, method, function(c)
        local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = make(c) }
        if p.kind == 'references' then
          params.context = { includeDeclaration = true }
        end
        return params
      end, function(results)
        local out, seen, read = {}, {}, line_reader()
        for _, r in ipairs(results) do
          if not r.err then
            add_locations(r.result, r.client.offset_encoding, read, out, seen)
          end
        end
        reply({ locations = out, errors = errors_of(results), note = dirty_note(state) })
      end)
    end)
  end)
end

function methods.hover(p, reply, fail)
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    local make, err = position(bufnr, p)
    if not make then
      return fail(err)
    end
    when_idle(bufnr, clients, p.budget_ms or 15000, function()
      request_all(bufnr, 'textDocument/hover', function(c)
        return { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = make(c) }
      end, function(results)
        local texts = {}
        for _, r in ipairs(results) do
          if not r.err and r.result and r.result.contents then
            local t = vim.trim(hover_text(r.result.contents))
            if t ~= '' then
              texts[#texts + 1] = t
            end
          end
        end
        reply({ hover = texts, errors = errors_of(results), note = dirty_note(state) })
      end)
    end)
  end)
end

function methods.document_symbols(p, reply, fail)
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    when_idle(bufnr, clients, p.budget_ms or 15000, function()
      request_all(bufnr, 'textDocument/documentSymbol', function()
        return { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
      end, function(results)
        for _, r in ipairs(results) do
          if not r.err and r.result and r.result ~= vim.NIL and #r.result > 0 then
            return reply({ symbols = symbol_tree(r.result, r.client.offset_encoding, p.file), note = dirty_note(state) })
          end
        end
        reply({ symbols = {}, errors = errors_of(results) })
      end)
    end)
  end)
end

--- Language servers whose workspace covers `root`, or that `root` covers.
local function clients_for_root(root)
  return vim.tbl_filter(function(c)
    local dir = c.root_dir
    if not dir then
      return false
    end
    return vim.startswith(root .. '/', dir .. '/') or vim.startswith(dir .. '/', root .. '/')
  end, vim.lsp.get_clients())
end

function methods.workspace_symbols(p, reply)
  local clients = vim.tbl_filter(function(c)
    return c:supports_method('workspace/symbol')
  end, clients_for_root(p.root))
  if #clients == 0 then
    return reply({ symbols = {}, errors = { 'no running language server covers ' .. p.root } })
  end
  local out, errs, left = {}, {}, #clients
  for _, c in ipairs(clients) do
    c:request('workspace/symbol', { query = p.query }, function(err, result)
      if err then
        errs[#errs + 1] = ('%s: %s'):format(c.name, err.message)
      else
        vim.list_extend(out, symbol_tree(result, c.offset_encoding))
      end
      left = left - 1
      if left == 0 then
        reply({ symbols = out, errors = errs })
      end
    end)
  end
end

--- Applies a WorkspaceEdit like nvim does, then writes what it changed.
local function apply_edit(edit, encoding)
  local before = snapshot()
  vim.lsp.util.apply_workspace_edit(edit, encoding)
  local written, unsaved = write_touched(before)
  return { written = written, unsaved = unsaved }
end

function methods.rename(p, reply, fail)
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    local make, err = position(bufnr, p)
    if not make then
      return fail(err)
    end
    local client = vim.iter(clients):find(function(c)
      return c:supports_method('textDocument/rename', bufnr)
    end)
    if not client then
      return fail('no language server of this buffer can rename')
    end
    when_idle(bufnr, clients, p.budget_ms or 15000, function()
      local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = make(client), newName = p.new_name }
      client:request('textDocument/rename', params, function(rerr, edit)
        if rerr then
          return fail(('%s: %s'):format(client.name, rerr.message))
        end
        if not edit or edit == vim.NIL then
          return reply({ empty = true })
        end
        local summary = summarize_edit(edit, line_reader())
        if p.apply == false then
          return reply({ preview = summary, note = dirty_note(state) })
        end
        local applied = apply_edit(edit, client.offset_encoding)
        reply({ applied = summary, written = applied.written, unsaved = applied.unsaved })
      end, bufnr)
    end)
  end)
end

function methods.code_actions(p, reply, fail)
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    local make, err = position(bufnr, p)
    if not make then
      return fail(err)
    end
    local lnum = math.max((p.line or 1) - 1, 0)
    local diags = vim.tbl_map(function(d)
      return d.user_data and d.user_data.lsp or nil
    end, vim.diagnostic.get(bufnr, { lnum = lnum }))
    when_idle(bufnr, clients, p.budget_ms or 15000, function()
      request_all(bufnr, 'textDocument/codeAction', function(c)
        local pos = make(c)
        return {
          textDocument = { uri = vim.uri_from_bufnr(bufnr) },
          range = { start = pos, ['end'] = pos },
          context = {
            diagnostics = diags,
            only = (not p.apply and p.query and p.query ~= '') and { p.query } or nil,
          },
        }
      end, function(results)
        local actions = {}
        for _, r in ipairs(results) do
          if not r.err and r.result and r.result ~= vim.NIL then
            for _, a in ipairs(r.result) do
              actions[#actions + 1] = { client = r.client, action = a }
            end
          end
        end
        local listing = vim.tbl_map(function(e)
          return { title = e.action.title, kind = e.action.kind, client = e.client.name }
        end, actions)
        if not p.apply or not p.query or p.query == '' then
          return reply({ actions = listing, errors = errors_of(results), note = dirty_note(state) })
        end
        local pick
        local idx = tonumber(p.query)
        if idx and actions[idx + 1] then
          pick = actions[idx + 1]
        else
          local q = p.query:lower()
          pick = vim.iter(actions):find(function(e)
            return e.action.title:lower():find(q, 1, true) ~= nil
          end)
        end
        if not pick then
          return reply({ actions = listing, no_match = p.query })
        end
        local c, action = pick.client, pick.action
        local function run(resolved)
          local before = snapshot()
          if resolved.edit then
            vim.lsp.util.apply_workspace_edit(resolved.edit, c.offset_encoding)
          end
          local cmd = type(resolved.command) == 'table' and resolved.command or (type(resolved.command) == 'string' and resolved) or nil
          local function finish(cmd_err)
            local written, unsaved = write_touched(before)
            reply({
              applied = resolved.title,
              edit = resolved.edit and summarize_edit(resolved.edit, line_reader()) or nil,
              command = cmd and cmd.command or nil,
              command_error = cmd_err,
              written = written,
              unsaved = unsaved,
            })
          end
          if not cmd then
            return finish()
          end
          c:exec_cmd(cmd, { bufnr = bufnr }, function(cerr)
            finish(cerr and cerr.message or nil)
          end)
        end
        if not action.edit and not action.command and c:supports_method('codeAction/resolve', bufnr) then
          c:request('codeAction/resolve', action, function(rerr, resolved)
            run((not rerr and resolved) or action)
          end, bufnr)
        else
          run(action)
        end
      end)
    end)
  end)
end

function methods.rename_file(p, reply, fail)
  local old, new = p.file, p.new_name
  if not uv.fs_stat(old) then
    return fail('no such file: ' .. old)
  end
  if uv.fs_stat(new) then
    return fail('destination exists: ' .. new)
  end
  local files = { { oldUri = vim.uri_from_fname(old), newUri = vim.uri_from_fname(new) } }
  local clients = vim.tbl_filter(function(c)
    return c:supports_method('workspace/willRenameFiles')
  end, clients_for_root(p.root))
  local edits, errs, left = {}, {}, #clients
  local function go()
    local read = line_reader()
    local summaries = vim.tbl_map(function(e)
      return summarize_edit(e.edit, read)
    end, edits)
    if p.apply == false then
      return reply({ preview = summaries, errors = errs })
    end
    local before = snapshot()
    for _, e in ipairs(edits) do
      vim.lsp.util.apply_workspace_edit(e.edit, e.encoding)
    end
    vim.lsp.util.rename(old, new)
    for _, c in ipairs(clients_for_root(p.root)) do
      if c:supports_method('workspace/didRenameFiles') then
        c:notify('workspace/didRenameFiles', { files = files })
      end
    end
    local written, unsaved = write_touched(before)
    reply({ applied = summaries, renamed = { old, new }, written = written, unsaved = unsaved, errors = errs })
  end
  if left == 0 then
    return go()
  end
  for _, c in ipairs(clients) do
    c:request('workspace/willRenameFiles', { files = files }, function(err, edit)
      if err then
        errs[#errs + 1] = ('%s: %s'):format(c.name, err.message)
      elseif edit and edit ~= vim.NIL then
        edits[#edits + 1] = { edit = edit, encoding = c.offset_encoding }
      end
      left = left - 1
      if left == 0 then
        go()
      end
    end)
  end
end

function methods.status(p, reply)
  local out = {}
  for _, c in ipairs(clients_for_root(p.root)) do
    out[#out + 1] = {
      name = c.name,
      id = c.id,
      root = c.root_dir,
      buffers = #vim.tbl_keys(c.attached_buffers),
      busy = busy({ [c.id] = c }),
    }
  end
  reply({ cwd = vim.fn.getcwd(), clients = out })
end

function methods.capabilities(p, reply, fail)
  local function dump(clients)
    local out = {}
    for _, c in ipairs(clients) do
      out[#out + 1] = { name = c.name, capabilities = c.server_capabilities }
    end
    reply({ clients = out })
  end
  if not p.file then
    return dump(clients_for_root(p.root))
  end
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    dump(clients)
  end)
end

function methods.reload(p, reply, fail)
  local function restart(clients)
    local names = {}
    for _, c in ipairs(clients) do
      names[c.name] = true
    end
    names = vim.tbl_keys(names)
    if #names == 0 then
      return reply({ restarted = {} })
    end
    local ok, err = pcall(vim.cmd.lsp, { args = vim.list_extend({ 'restart' }, names) })
    if not ok then
      return fail(tostring(err))
    end
    reply({ restarted = names })
  end
  if not p.file then
    return restart(clients_for_root(p.root))
  end
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    restart(clients)
  end)
end

--- Any LSP request, for what the other methods do not cover.
function methods.request(p, reply, fail)
  local function issue(c, bufnr, params)
    c:request(p.method, params, function(err, result)
      if err then
        return fail(('%s: %s'):format(c.name, err.message))
      end
      reply({ client = c.name, result = result })
    end, bufnr)
  end
  if not p.file then
    local c = clients_for_root(p.root)[1]
    if not c then
      return fail('no running language server covers ' .. p.root)
    end
    return issue(c, nil, p.params or vim.empty_dict())
  end
  prepare(p, function(bufnr, state, clients)
    if not bufnr then
      return fail(state)
    end
    local c = vim.iter(clients):find(function(cl)
      return cl:supports_method(p.method, bufnr)
    end) or clients[1]
    local params = p.params
    if not params then
      params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
      if p.line then
        local make, err = position(bufnr, p)
        if not make then
          return fail(err)
        end
        params.position = make(c)
      end
    end
    issue(c, bufnr, params)
  end)
end

M.methods = methods

---------------------------------------------------------------------------------------------------
-- Connections to omp sessions

---@type table<integer, { pipe: uv.uv_pipe_t, cwd: string }> omp pid -> connection
local conns = {}

local function overlaps(a, b)
  a, b = a .. '/', b .. '/'
  return vim.startswith(a, b) or vim.startswith(b, a)
end

---@param pid integer
local function disconnect(pid)
  local conn = conns[pid]
  conns[pid] = nil
  if conn and not conn.pipe:is_closing() then
    conn.pipe:close()
  end
end

---@param pipe uv.uv_pipe_t
---@param msg table
local function send(pipe, msg)
  if pipe:is_closing() then
    return
  end
  local ok, encoded = pcall(json_encode, msg)
  if not ok then
    encoded = json_encode({ id = msg.id, error = 'nvim could not encode the answer: ' .. tostring(encoded) })
  end
  pipe:write(encoded .. '\n')
end

local inflight = 0

---@return integer requests omp is waiting on
function M.inflight()
  return inflight
end

---@param pipe uv.uv_pipe_t
---@param line string
local function handle(pipe, line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' or msg.id == nil then
    return
  end
  local id = msg.id
  local answered = false
  inflight = inflight + 1
  local function reply(result)
    if answered then
      return
    end
    answered = true
    inflight = inflight - 1
    send(pipe, { id = id, result = result == nil and vim.NIL or result })
  end
  local function fail(message)
    if answered then
      return
    end
    answered = true
    inflight = inflight - 1
    send(pipe, { id = id, error = tostring(message) })
  end
  local method = methods[msg.method]
  if not method then
    return fail('unknown method: ' .. tostring(msg.method))
  end
  local run_ok, err = xpcall(method, debug.traceback, msg.params or {}, reply, fail)
  if not run_ok then
    fail(err)
  end
end

---@param info { pid: integer, cwd: string, socket: string }
local function connect(info)
  local pipe = assert(uv.new_pipe(false))
  conns[info.pid] = { pipe = pipe, cwd = info.cwd }
  -- The connect callback runs in a fast event, where vim.fn is off limits.
  local hello = { op = 'lsp_provide', pid = vim.fn.getpid(), cwd = vim.fn.getcwd() }
  pipe:connect(info.socket, function(err)
    if err then
      return vim.schedule(function()
        if conns[info.pid] and conns[info.pid].pipe == pipe then
          disconnect(info.pid)
        end
      end)
    end
    send(pipe, hello)
    local buf = ''
    pipe:read_start(function(rerr, chunk)
      if rerr or not chunk then
        return vim.schedule(function()
          if conns[info.pid] and conns[info.pid].pipe == pipe then
            disconnect(info.pid)
          end
        end)
      end
      buf = buf .. chunk
      local lines = {}
      while true do
        local nl = buf:find('\n', 1, true)
        if not nl then
          break
        end
        lines[#lines + 1] = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
      end
      if #lines > 0 then
        vim.schedule(function()
          for _, line in ipairs(lines) do
            handle(pipe, line)
          end
        end)
      end
    end)
  end)
end

--- Connects to every live omp of this project, drops the ones that went away or moved.
function M.scan()
  local cwd = vim.fn.getcwd()
  local live = {}
  for name, kind in vim.fs.dir(RUN_DIR) do
    if kind == 'file' and name:match('%.json$') then
      local ok, info = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(RUN_DIR .. '/' .. name), '\n'))
      end)
      if ok and type(info) == 'table' and info.pid and info.socket and info.cwd then
        if uv.kill(info.pid, 0) == 0 and overlaps(info.cwd, cwd) then
          live[info.pid] = true
          if not conns[info.pid] then
            connect(info)
          end
        end
      end
    end
  end
  for pid in pairs(conns) do
    if not live[pid] then
      disconnect(pid)
    end
  end
end

---@return integer[] pids of the omps this nvim serves
function M.connected()
  return vim.tbl_keys(conns)
end

local watcher, sweeper ---@type uv.uv_fs_event_t?, uv.uv_timer_t?

function M.setup(opts)
  M.config = vim.tbl_extend('force', M.config, opts or {})
  local group = api.nvim_create_augroup('omp-lsp', { clear = true })

  api.nvim_create_autocmd('LspProgress', {
    group = group,
    callback = function(ev)
      local id, params = ev.data.client_id, ev.data.params
      local value = params.value
      if type(value) ~= 'table' then
        return
      end
      progress[id] = progress[id] or {}
      local title = progress[id][params.token] or value.title or value.message or tostring(params.token)
      if value.kind == 'begin' then
        progress[id][params.token] = title
      elseif value.kind == 'end' then
        progress[id][params.token] = nil
      end
      last_progress[id] = { t = now(), title = title }
    end,
  })
  api.nvim_create_autocmd('LspDetach', {
    group = group,
    callback = function(ev)
      -- The client's last buffer going away usually means the client stops: forget its work.
      local c = vim.lsp.get_client_by_id(ev.data.client_id)
      if not c or vim.tbl_isempty(c.attached_buffers) then
        progress[ev.data.client_id] = nil
      end
    end,
  })
  api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(ev)
      changed_at[ev.buf] = now()
    end,
  })
  api.nvim_create_autocmd({ 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      changed_at[ev.buf] = nil
      owned[ev.buf] = nil
    end,
  })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      release(ev.buf)
    end,
  })
  api.nvim_create_autocmd('DirChanged', { group = group, callback = M.scan })

  vim.fn.mkdir(RUN_DIR, 'p')
  if watcher then
    watcher:stop()
  end
  watcher = assert(uv.new_fs_event())
  local pending = false
  watcher:start(RUN_DIR, {}, function()
    if pending then
      return
    end
    pending = true
    -- A descriptor is written once its socket listens; let the burst of events settle.
    vim.defer_fn(function()
      pending = false
      M.scan()
    end, 100)
  end)

  if sweeper then
    sweeper:stop()
  end
  sweeper = assert(uv.new_timer())
  sweeper:start(60000, 60000, vim.schedule_wrap(sweep))

  M.scan()
end

return M
