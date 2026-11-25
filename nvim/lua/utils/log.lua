local M = {}

local default_timeout = 500

M.info = function(message, opts)
  opts = opts or {}
  vim.notify(message, vim.log.levels.INFO, {
    title = opts.title or 'Info',
    timeout = opts.timeout or default_timeout,
  })
end

return M
