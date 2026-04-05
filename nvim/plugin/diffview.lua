vim.pack.add({
  'https://github.com/sindrets/diffview.nvim',
})

vim.keymap.set('n', '<leader>dvo', '<cmd>DiffviewOpen<CR>', { desc = 'Open diffview' })
vim.keymap.set('n', '<leader>dvc', '<cmd>DiffviewClose<CR>', { desc = 'Close diffview' })
vim.keymap.set('n', '<leader>dvm', function()
  local main_branch = require('utils').get_git_main_branch()
  vim.print(main_branch)
  if main_branch then
    vim.cmd('DiffviewOpen ' .. main_branch)
  else
    vim.cmd('DiffviewOpen')
  end
end, { desc = 'Open diffview HEAD..main' })
vim.keymap.set('n', '<leader>dvf', '<cmd>DiffviewFileHistory %<CR>', { desc = 'Open diffview file history for current file' })
vim.keymap.set('n', '<leader>dvh', '<cmd>DiffviewFileHistory<CR>', { desc = 'Open diffview git log history' })

require('diffview').setup({
  keymaps = {
    file_history_panel = {
      {
        'n',
        '<leader>do',
        function()
          local view = require('diffview.lib').get_current_view()
          local entry = view.panel:get_item_at_cursor()
          if entry and entry.commit then
            vim.cmd('DiffviewOpen ' .. entry.commit.hash .. '^!')
          end
        end,
        { desc = 'Open commit as DiffviewOpen' },
      },
    },
  },
})
