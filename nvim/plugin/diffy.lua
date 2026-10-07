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

vim.keymap.set('n', '<leader>do', '<cmd>Diffy<CR>', { desc = 'Open diffy' })
vim.keymap.set('n', '<leader>db', '<cmd>Diffy branch<CR>', { desc = 'Open diffy on the branch' })
vim.keymap.set('n', '<leader>df', '<cmd>Diffy file<CR>', { desc = 'Open diffy file history for current file' })
vim.keymap.set('n', '<leader>dra', '<cmd>Diffy review agent<CR>', { desc = 'Send diffy review to the agent' })
vim.keymap.set('n', '<leader>drg', '<cmd>Diffy review github<CR>', { desc = 'Submit diffy review to GitHub' })
