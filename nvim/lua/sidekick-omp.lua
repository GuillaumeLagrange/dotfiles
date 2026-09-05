-- Sidekick session backend for omp TUIs running outside nvim.
--
-- The `nvim-bridge` omp extension (dotfiles/ai/omp/extensions) makes every
-- interactive omp session listen on a unix socket and drop a `<pid>.json`
-- descriptor in ~/.omp/run/nvim-bridge. This backend lists those sessions so
-- `<leader>aa` can attach to an omp already running in another pane, and
-- `<leader>at` pushes text into its composer.

local RUN_DIR = vim.fs.normalize('~/.omp/run/nvim-bridge')

---@class sidekick.cli.omp: sidekick.cli.Session
---@field omp_pid integer
---@field omp_socket string
local M = {}
M.__index = M
M.priority = 50

function M:init()
  -- Never opened in an nvim terminal: the TUI lives in its own pane.
  self.external = true
end

function M:is_running()
  return self.omp_pid and vim.api.nvim_get_proc(self.omp_pid) ~= nil
end

---@param msg table
function M:request(msg)
  local socket = self.omp_socket
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
    end)
  end)
end

function M:send(text)
  self:request({ op = 'send', text = text })
end

function M:submit()
  self:request({ op = 'submit' })
end

function M.sessions()
  local ret = {} ---@type sidekick.cli.session.State[]
  for name, kind in vim.fs.dir(RUN_DIR) do
    if kind == 'file' and name:match('%.json$') then
      local path = RUN_DIR .. '/' .. name
      local ok, info = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
      end)
      if ok and info.pid and vim.api.nvim_get_proc(info.pid) then
        ret[#ret + 1] = {
          id = 'omp: ' .. info.pid,
          cwd = info.cwd,
          tool = 'pi',
          pids = { info.pid },
          omp_pid = info.pid,
          omp_socket = info.socket,
        }
      else
        -- session died without cleaning up after itself
        vim.fn.delete(path)
      end
    end
  end
  return ret
end

function M.setup()
  local Session = require('sidekick.cli.session')
  Session.setup()
  Session.register('omp', M)
end

return M
