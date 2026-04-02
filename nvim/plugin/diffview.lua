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
