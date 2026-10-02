-- diffy is developed in its own repo (GuillaumeLagrange/diffy), loaded from a local checkout.
local dir = vim.fn.expand('~/projects/diffy')
if not vim.uv.fs_stat(dir) then
  return
end

vim.opt.rtp:prepend(dir)
vim.cmd.runtime('plugin/diffy.lua')

local fixit = require('fixit')
-- diffy's sessions, in any tab, join every `:Fixit` snapshot
fixit.add_context('diffy', function()
  if not package.loaded['diffy'] then
    return nil
  end
  local state = require('diffy').debug_state()
  return #state.sessions > 0 and state or nil
end)
-- `:Diffy feedback` is `:Fixit` with diffy's modal
vim.api.nvim_create_autocmd('User', {
  pattern = 'DiffyFeedback',
  group = vim.api.nvim_create_augroup('diffy_feedback', { clear = true }),
  callback = function(ev)
    fixit.send(ev.data.text)
  end,
})

vim.keymap.set('n', '<leader>dvo', '<cmd>Diffy<CR>', { desc = 'Open diffy' })
vim.keymap.set('n', '<leader>dvc', '<cmd>Diffy close<CR>', { desc = 'Close diffy' })
vim.keymap.set('n', '<leader>dvm', '<cmd>Diffy branch<CR>', { desc = 'Open diffy on the branch' })
vim.keymap.set('n', '<leader>dvf', '<cmd>Diffy file<CR>', { desc = 'Open diffy file history for current file' })
vim.keymap.set('n', '<leader>dvp', '<cmd>Diffy pr<CR>', { desc = 'Open diffy PR review' })
