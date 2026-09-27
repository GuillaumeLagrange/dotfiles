-- Loads diffy from nvim/diffy, wherever this config is checked out.
local here = debug.getinfo(1, 'S').source:sub(2)
local dir = vim.fn.fnamemodify(here, ':h:h') .. '/diffy'

vim.opt.rtp:prepend(dir)
vim.cmd.runtime('plugin/diffy.lua')

vim.keymap.set('n', '<leader>dvo', '<cmd>Diffy<CR>', { desc = 'Open diffy' })
vim.keymap.set('n', '<leader>dvc', '<cmd>Diffy close<CR>', { desc = 'Close diffy' })
vim.keymap.set('n', '<leader>dvm', '<cmd>Diffy branch<CR>', { desc = 'Open diffy on the branch' })
vim.keymap.set('n', '<leader>dvf', '<cmd>Diffy file<CR>', { desc = 'Open diffy file history for current file' })
vim.keymap.set('n', '<leader>dvp', '<cmd>Diffy pr<CR>', { desc = 'Open diffy PR review' })
