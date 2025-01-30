local M = {}

local default_timeout = 500

M.info = function(message, opts)
  opts = opts or {}
  vim.notify(message, vim.log.levels.INFO, {
    title = opts.title or 'Info',
    timeout = opts.timeout or default_timeout,
  })
end

M.error = function(message, opts)
  opts = opts or {}
  vim.notify(message, vim.log.levels.ERROR, {
    title = opts.title or 'Error',
    timeout = opts.timeout or default_timeout,
  })
end

M.warn = function(message, opts)
  opts = opts or {}
  vim.notify(message, vim.log.levels.WARN, {
    title = opts.title or 'Warning',
    timeout = opts.timeout or default_timeout,
  })
end

M.inspect = function(arg)
  vim.print(vim.inspect(arg))
end

return M
