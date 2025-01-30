local utils = require('utils')

-- Set highlight on search, but clear on pressing <Esc> in normal mode
vim.opt.hlsearch = true
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
-- vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Split navigation
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

vim.keymap.set('n', '-', '<CMD>lua MiniFiles.open(vim.api.nvim_buf_get_name(0)); MiniFiles.reveal_cwd()<CR>', { desc = 'Open MiniFiles' })

vim.keymap.set('n', '<leader>bb', '<cmd>e #<cr>', { desc = 'Switch to Other Buffer' })

vim.keymap.set('n', '<leader>uh', utils.toggle_inlay_hints, { desc = 'Toggle inlay hints' })
vim.keymap.set('n', '<leader>un', utils.toggle_relative_number, { desc = 'Toggle relative line number' })
vim.keymap.set('n', '<leader>ud', utils.toggle_diagnostics, { desc = 'Toggle diagnostics' })
vim.keymap.set('n', '<leader>uu', utils.toggle_diagnostic_underline, { desc = 'Toggle underlines' })
vim.keymap.set('n', '<leader>um', function()
  utils.toggle_option('modifiable')
end, { desc = 'Toggle modifiable' })

vim.keymap.set('n', '[q', vim.cmd.cprev, { desc = 'Previous quickfix' })
vim.keymap.set('n', ']q', vim.cmd.cnext, { desc = 'Next quickfix' })

vim.keymap.set('n', '<leader>bo', utils.close_windowless_buffers, { desc = 'Delete all buffers not in a window' })
vim.keymap.set('n', '<leader>bO', '<cmd>%bd!|e#|bd!#<cr>', { desc = 'Delete all buffers except current' })

-- Tabs
vim.keymap.set('n', '<leader><tab>l', '<cmd>tablast<cr>', { desc = 'Last tab' })
vim.keymap.set('n', '<leader><tab>f', '<cmd>tabfirst<cr>', { desc = 'First tab' })
vim.keymap.set('n', '<leader><tab><tab>', '<cmd>tab split<cr>', { desc = 'New tab' })
vim.keymap.set('n', '<leader><tab>]', '<cmd>tabnext<cr>', { desc = 'Next tab' })
vim.keymap.set('n', '<leader><tab>d', '<cmd>tabclose<cr>', { desc = 'Close tab' })
vim.keymap.set('n', '<leader><tab>o', '<cmd>tabonly<cr>', { desc = 'Close other tabs' })
vim.keymap.set('n', '<leader><tab>[', '<cmd>tabprevious<cr>', { desc = 'Previous tab' })

-- Session
vim.keymap.set('n', '<leader>msd', require('session').delete_all, { desc = 'Delete all sessions' })

-- Invert ; and : mappings
vim.keymap.set({ 'n', 'v' }, ';', ':', { noremap = false })
vim.keymap.set({ 'n', 'v' }, ':', ';', { noremap = false })

vim.keymap.set({ 'n', 'v' }, 'j', 'gj', { silent = true })
vim.keymap.set({ 'n', 'v' }, 'k', 'gk', { silent = true })

-- better indenting
vim.keymap.set('v', '<', '<gv')
vim.keymap.set('v', '>', '>gv')
