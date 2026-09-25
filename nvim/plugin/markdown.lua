vim.pack.add({
  'https://github.com/brianhuster/live-preview.nvim',
})

-- The plugin silently ignores EADDRINUSE, so a second nvim on the default port
-- would open the browser on the first instance's server. Use a free port per nvim.
local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:close()
  return port
end

require('livepreview.config').set({
  -- Serve from the file's directory so relative images/links resolve.
  dynamic_root = true,
  port = free_port(),
})

vim.keymap.set('n', '<leader>up', function()
  vim.cmd('LivePreview start')
end, { desc = 'Markdown Preview (browser)' })

vim.keymap.set('n', '<leader>uP', function()
  vim.cmd('LivePreview close')
end, { desc = 'Close Markdown Preview' })
