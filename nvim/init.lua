-- Set <space> as the leader key
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

require('options')
require('commands')
require('keymaps')
require('term')
require('session')

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

-- [[ lazyvim ]]
local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
---@diagnostic disable-next-line: undefined-field
if not vim.loop.fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  vim.fn.system({ 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath })
end
---@diagnostic disable-next-line: undefined-field
vim.opt.rtp:prepend(lazypath)

vim.cmd('cnoreabbrev lazy Lazy')
require('lazy').setup({ import = 'plugins' }, {
  dev = {
    fallback = true,
    path = '~/neovim-plugins',
  },
  ui = {
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})
