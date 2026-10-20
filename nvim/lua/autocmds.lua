-- Autocommandes that are always enabled

-- [[ Basic Autocommands ]]
-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- Auto equalize splits when resizing the window
vim.api.nvim_create_autocmd('VimResized', {
  desc = 'Resize splits when resizing the window',
  group = vim.api.nvim_create_augroup('kickstart-resize-splits', { clear = true }),
  callback = function()
    vim.cmd('wincmd =')
  end,
})

-- Read or create the local session; nested so the restored buffers get their autocmds
vim.api.nvim_create_autocmd('VimEnter', {
  nested = true,
  callback = require('session').ensure_session,
})
