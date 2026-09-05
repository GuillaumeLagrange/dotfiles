-- Sidekick session backend for omp TUIs running outside nvim.
--
-- The `nvim-bridge` omp extension (dotfiles/ai/omp/extensions) makes every
-- interactive omp session listen on a unix socket and drop a `<pid>.json`
-- descriptor in ~/.omp/run/nvim-bridge. This backend lists those sessions so
-- `<leader>aa` can attach to an omp already running in another pane, and
-- `<leader>at` pushes text into its composer.
--
-- `M.move()` walks a conversation between an nvim terminal and a zellij pane by
-- quitting it on one side and resuming it on the other.

-- Overridable so tests stay out of the real session registry.
local RUN_DIR = vim.env.OMP_NVIM_BRIDGE_DIR or vim.fs.normalize('~/.omp/run/nvim-bridge')

---@class sidekick.omp.Descriptor
---@field pid integer
---@field cwd string
---@field socket string
---@field session? string omp session id, for `omp --resume`
---@field file? string session file; absent until the session's first turn

---@class sidekick.cli.omp: sidekick.cli.Session
---@field omp_pid integer
---@field omp_socket string
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
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
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

function M:init()
  -- Never opened in an nvim terminal: the TUI lives in its own pane.
  self.external = true
end

function M:is_running()
  return self.omp_pid and vim.api.nvim_get_proc(self.omp_pid) ~= nil
end

function M:send(text)
  request(self.omp_socket, { op = 'send', text = text })
end

function M:submit()
  request(self.omp_socket, { op = 'submit' })
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
  }
end

function M.sessions()
  return vim.tbl_map(state_of, descriptors())
end

--- Stop the omp holding a session, then run `cb` once it is gone. SIGTERM makes
--- omp exit cleanly (session file flushed, descriptor removed), which the
--- resumed process needs.
---@param info sidekick.omp.Descriptor
---@param cb fun()
local function quit(info, cb)
  vim.uv.kill(info.pid, 'sigterm')
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    50,
    50,
    vim.schedule_wrap(function()
      waited = waited + 50
      if vim.api.nvim_get_proc(info.pid) and waited < 5000 then
        return
      end
      timer:stop()
      timer:close()
      if vim.api.nvim_get_proc(info.pid) then
        vim.notify('omp ' .. info.pid .. ' did not exit; handoff aborted', vim.log.levels.ERROR)
        return
      end
      cb()
    end)
  )
end

--- `omp --resume` rejects an id with no file on disk, and omp only writes one
--- once the conversation has a first turn. Nothing to carry over before that.
---@param info sidekick.omp.Descriptor
---@return string[]
function M.omp_cmd(info)
  if info.session and info.file and vim.uv.fs_stat(info.file) then
    return { 'omp', '--resume', info.session }
  end
  return { 'omp' }
end

--- The new omp needs a few seconds of startup before it registers, so keep
--- looking for it and attach it: the move should leave the session attached
--- wherever it went.
---@param gone sidekick.omp.Descriptor the omp we just stopped
---@param resumed boolean whether the replacement carries the same session id
local function attach_when_up(gone, resumed)
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    500,
    500,
    vim.schedule_wrap(function()
      waited = waited + 500
      for _, info in ipairs(descriptors()) do
        -- A resumed session is identified by its id; a fresh one only by
        -- being the new omp in that directory.
        local match = resumed and info.session == gone.session or (not resumed and info.cwd == gone.cwd)
        if match and info.pid ~= gone.pid then
          timer:stop()
          timer:close()
          local Session = require('sidekick.cli.session')
          Session.attach(Session.new(vim.tbl_extend('force', state_of(info), { backend = 'omp', started = true })))
          return
        end
      end
      if waited >= 30000 then
        timer:stop()
        timer:close()
        vim.notify('omp did not come back up in ' .. gone.cwd, vim.log.levels.WARN)
      end
    end)
  )
end

---@param info sidekick.omp.Descriptor
local function to_pane(info)
  -- SIGTERM leaves the terminal sitting on "[Process exited 143]", which
  -- sidekick keeps open because a non-zero exit usually means a failed start.
  local terminal
  for _, candidate in pairs(require('sidekick.cli.terminal').terminals) do
    if vim.tbl_contains(candidate.pids or {}, info.pid) then
      terminal = candidate
    end
  end
  quit(info, function()
    if terminal then
      terminal:close()
    end
    local args = M.omp_cmd(info)
    local cmd = { 'zellij', 'action', 'new-pane', '--close-on-exit', '--cwd', info.cwd, '--' }
    vim.list_extend(cmd, args)
    vim.system(cmd, { text = true }, function(out)
      if out.code ~= 0 then
        vim.schedule(function()
          vim.notify('omp handoff failed: ' .. (out.stderr or ''), vim.log.levels.ERROR)
        end)
        return
      end
      vim.schedule(function()
        attach_when_up(info, args[2] == '--resume')
      end)
    end)
  end)
end

---@param info sidekick.omp.Descriptor
local function to_nvim(info)
  local Session = require('sidekick.cli.session')
  local tool = require('sidekick.config').get_tool('omp')
  quit(info, function()
    require('sidekick.cli.state').attach({
      tool = tool,
      session = Session.new({
        tool = tool:clone({ cmd = M.omp_cmd(info) }),
        cwd = info.cwd,
        backend = 'terminal',
      }),
    }, { show = true, focus = true })
  end)
end

--- Move the attached omp session between an nvim terminal and a zellij pane.
function M.move()
  local Session = require('sidekick.cli.session')
  local cwd = Session.cwd()
  for _, session in pairs(Session.attached()) do
    if session.cwd == cwd then
      local info ---@type sidekick.omp.Descriptor?
      for _, candidate in ipairs(descriptors()) do
        if vim.tbl_contains(session.pids or {}, candidate.pid) then
          info = candidate
        end
      end
      if not info or not info.session then
        vim.notify('no omp bridge for the attached session', vim.log.levels.WARN)
        return
      end
      Session.detach(session)
      if session.backend == 'omp' then
        to_nvim(info)
      else
        to_pane(info)
      end
      return
    end
  end
  vim.notify('no attached omp session in ' .. cwd, vim.log.levels.WARN)
end

function M.setup()
  local Session = require('sidekick.cli.session')
  Session.setup()
  Session.register('omp', M)
end

return M
