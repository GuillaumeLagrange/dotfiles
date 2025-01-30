vim.api.nvim_create_user_command('W', function()
  vim.cmd('noautocmd w')
end, { desc = 'Write the buffer without triggering autocommands' })
