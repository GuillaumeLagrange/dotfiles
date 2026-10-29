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
    -- Only stop insert mode when leaving for a non-terminal buffer
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      if vim.bo[buf].buftype ~= 'terminal' then
        vim.cmd('stopinsert')
      end
    end)
  end,
})

vim.keymap.set('t', '<C-h>', '<C-\\><C-n><C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('t', '<C-l>', '<C-\\><C-n><C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('t', '<C-j>', '<C-\\><C-n><C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('t', '<C-k>', '<C-\\><C-n><C-w><C-k>', { desc = 'Move focus to the upper window' })

-- Exit terminal mode in the builtin terminal
--vim.keymap.set('t', '<Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Make Shift+Enter send the correct sequence in neovim terminal buffers (for Claude Code)
vim.keymap.set('t', '<S-Enter>', function()
  local chan = vim.b.terminal_job_id
  if chan then
    vim.api.nvim_chan_send(chan, '\x1b[13;2u')
  end
end, { desc = 'Send Shift+Enter to terminal' })
