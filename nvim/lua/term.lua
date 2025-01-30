-- Terminal insert mode management
vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
  pattern = 'term://*',
  callback = function()
    vim.cmd('startinsert')
  end,
})
vim.api.nvim_create_autocmd('BufLeave', {
  pattern = 'term://*',
  callback = function()
    vim.cmd('stopinsert')
  end,
})

vim.keymap.set('t', '<C-h>', '<C-\\><C-n><C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('t', '<C-l>', '<C-\\><C-n><C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('t', '<C-j>', '<C-\\><C-n><C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('t', '<C-k>', '<C-\\><C-n><C-w><C-k>', { desc = 'Move focus to the upper window' })

-- Exit terminal mode in the builtin terminal
--vim.keymap.set('t', '<Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })
