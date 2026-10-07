-- Sidekick session backend for omp TUIs running in zellij panes.
--
-- The `nvim-bridge` omp extension (dotfiles/ai/omp/extensions) makes every
-- interactive omp session listen on a unix socket and drop a `<pid>.json`
-- descriptor in ~/.omp/run/nvim-bridge. This backend lists those sessions so
-- `<leader>aa` can attach to an omp already running in another pane, and
-- `<leader>at` pushes text into its composer.
--
-- It is also sidekick's backend for new sessions: starting one opens a zellij
-- pane running omp and attaches to it once its descriptor shows up.

-- Overridable so tests stay out of the real session registry.
local RUN_DIR = vim.env.OMP_NVIM_BRIDGE_DIR or vim.fs.normalize('~/.omp/run/nvim-bridge')

---@class sidekick.omp.Descriptor
---@field pid integer
---@field cwd string
---@field socket string
---@field zellij? string zellij session the omp runs in

---@class sidekick.cli.omp: sidekick.cli.Session
---@field omp_pid? integer
---@field omp_socket? string
---@field spawning? boolean pane requested, omp not registered yet
---@field queue? table[] ops issued while spawning
local M = {}
M.__index = M
M.priority = 50

---@return sidekick.omp.Descriptor[]
local function descriptors()
  local ret = {} ---@type sidekick.omp.Descriptor[]
  for name, kind in vim.fs.dir(RUN_DIR) do
    if kind == 'file' and name:match('%.json$') then
      local path = RUN_DIR .. '/' .. name
      local ok, info = pcall(function()
        -- `zellij` is null outside zellij; vim.NIL would crash sidekick's picker
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'), { luanil = { object = true } })
      end)
      if ok and info.pid and vim.api.nvim_get_proc(info.pid) then
        ret[#ret + 1] = info
      else
        -- session died without cleaning up after itself
        vim.fn.delete(path)
      end
    end
  end
  return ret
end

---@param socket string
---@param msg table
---@param cb? fun()
local function request(socket, msg, cb)
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    return
  end
  pipe:connect(socket, function(err)
    if err then
      pipe:close()
      return
    end
    pipe:write(vim.json.encode(msg) .. '\n', function()
      pipe:close()
      if cb then
        vim.schedule(cb)
      end
    end)
  end)
end

--- Send `msgs` one after the other, each once the previous one is written.
---@param socket string
---@param msgs table[]
local function request_all(socket, msgs)
  if #msgs == 0 then
    return
  end
  request(socket, msgs[1], function()
    request_all(socket, vim.list_slice(msgs, 2))
  end)
end

function M:init()
  -- Never opened in an nvim terminal: the TUI lives in its own pane.
  self.external = true
end

function M:is_running()
  return self.spawning or (self.omp_pid ~= nil and vim.api.nvim_get_proc(self.omp_pid) ~= nil)
end

---@param msg table
function M:request(msg)
  if self.spawning then
    table.insert(self.queue, msg)
  elseif self.omp_socket then
    request(self.omp_socket, msg)
  end
end

function M:send(text)
  self:request({ op = 'send', text = text })
end

function M:submit()
  self:request({ op = 'submit' })
end

---@param info sidekick.omp.Descriptor
---@return sidekick.cli.session.State
local function state_of(info)
  return {
    id = 'omp: ' .. info.pid,
    cwd = info.cwd,
    tool = 'omp',
    pids = { info.pid },
    omp_pid = info.pid,
    omp_socket = info.socket,
    mux_session = info.zellij,
  }
end

function M.sessions()
  return vim.tbl_map(state_of, descriptors())
end

--- The new omp needs a few seconds of startup before it registers. Poll for it,
--- then swap it in for the placeholder session and replay what was sent meanwhile.
---@param placeholder sidekick.cli.omp
---@param known table<integer, boolean> pids registered before the pane opened
local function attach_when_up(placeholder, known)
  local Session = require('sidekick.cli.session')
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    500,
    500,
    vim.schedule_wrap(function()
      waited = waited + 500
      for _, info in ipairs(descriptors()) do
        if not known[info.pid] and Session.cwd({ cwd = info.cwd }) == placeholder.cwd then
          timer:stop()
          timer:close()
          placeholder.spawning = false
          Session.detach(placeholder)
          Session.attach(Session.new(vim.tbl_extend('force', state_of(info), { backend = 'omp', started = true })))
          request_all(info.socket, placeholder.queue)
          return
        end
      end
      if waited >= 30000 then
        timer:stop()
        timer:close()
        placeholder.spawning = false
        Session.detach(placeholder)
        vim.notify('omp did not come up in ' .. placeholder.cwd, vim.log.levels.WARN)
      end
    end)
  )
end

--- Start omp in a new zellij pane. Returns no terminal command: sidekick keeps
--- this session attached as a placeholder until the real omp registers.
function M:start()
  local known = {} ---@type table<integer, boolean>
  for _, info in ipairs(descriptors()) do
    known[info.pid] = true
  end
  self.spawning = true
  self.queue = {}
  local cmd = { 'zellij', 'action', 'new-pane', '--close-on-exit', '--cwd', self.cwd, '--' }
  vim.list_extend(cmd, self.tool.cmd)
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 then
        self.spawning = false
        require('sidekick.cli.session').detach(self)
        vim.notify('could not open an omp pane: ' .. (out.stderr or ''), vim.log.levels.ERROR)
        return
      end
      attach_when_up(self, known)
    end)
  end)
end

function M.setup()
  local Config = require('sidekick.config')
  -- New sessions go through this backend instead of an nvim terminal. Assigned
  -- on the next tick: sidekick's setup schedules a validation that only knows
  -- tmux and zellij, and scheduled callbacks run in order.
  vim.schedule(function()
    Config.cli.mux.enabled = true
    Config.cli.mux.backend = 'omp'
  end)
  local Session = require('sidekick.cli.session')
  Session.setup()
  Session.register('omp', M)
end

return M
