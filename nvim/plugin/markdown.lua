vim.pack.add({
  'https://github.com/MeanderingProgrammer/render-markdown.nvim',
})

require('render-markdown').setup()

vim.keymap.set('n', '<leader>ur', function()
  require('render-markdown').toggle()
end, { desc = 'Render Markdown' })
