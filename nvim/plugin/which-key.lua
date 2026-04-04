vim.pack.add({
  'https://github.com/folke/which-key.nvim',
})

require('which-key').setup({
  notify = false,
})

require('which-key').add({
  { '<leader>c', group = '[C]ode' },
  { '<leader>d', group = '[D]ocument' },
  { '<leader>r', group = '[R]ename' },
  { '<leader>s', group = '[S]earch' },
  { '<leader>w', group = '[W]orkspace' },
})
