vim.keymap.set('n', '<leader>sr', function()
  require('spectre').toggle()
end, { desc = 'Toggle Spectre' })
