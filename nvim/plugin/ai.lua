vim.pack.add({
  'https://github.com/github/copilot.vim',
  'https://github.com/folke/sidekick.nvim',
})

local toggle_copilot = function()
  if vim.b.copilot_enabled == nil or vim.b.copilot_enabled then
    vim.b.copilot_enabled = false
    vim.print('Copilot disabled')
  else
    vim.b.copilot_enabled = true
    vim.print('Copilot enabled')
  end
end

vim.keymap.set('i', '<M-w>', '<Plug>(copilot-accept-word)', { desc = 'Accept copilot word' })
vim.keymap.set('i', '<M-l>', '<Plug>(copilot-accept-line)', { desc = 'Accept copilot line' })
vim.keymap.set('n', '<leader>uC', toggle_copilot, { desc = 'Toggle Copilot' })
vim.keymap.set('i', '<M-u>', toggle_copilot, { desc = 'Toggle Copilot' })

require('sidekick').setup({
  copilot = {
    status = {
      enabled = false,
    },
  },
  nes = {
    enabled = false,
    debounce = 100,
  },
})

-- omp is the only CLI worth a picker entry here. Assigning over the defaults
-- (rather than passing `tools` to setup, which deep-merges) drops the other
-- eleven, so `<leader>aa` auto-attaches instead of asking — the selection only
-- appears once there is also an omp running in another pane to choose from.
require('sidekick.config').cli.tools = {
  omp = {
    cmd = { 'omp' },
  },
}

-- Every omp runs in a zellij pane: attach over the unix socket exposed by the
-- `nvim-bridge` omp extension, and start new ones in a fresh pane.
require('sidekick-omp').setup()

vim.keymap.set({ 'n', 'i' }, '<tab>', function()
  if not require('sidekick').nes_jump_or_apply() then
    return '<Tab>'
  end
end, { expr = true, desc = 'Goto/Apply Next Edit Suggestion' })

-- Show the attached omp's pane next to nvim, or hide it by making nvim fullscreen.
vim.keymap.set({ 'n', 't', 'i', 'x' }, '<c-.>', require('sidekick-omp').toggle, { desc = 'Toggle omp pane' })
vim.keymap.set('n', '<leader>aa', require('sidekick-omp').toggle, { desc = 'Toggle omp pane' })

vim.keymap.set('n', '<leader>as', function()
  require('sidekick.cli').select()
end, { desc = 'Select CLI' })

vim.keymap.set('n', '<leader>ad', function()
  require('sidekick.cli').close()
end, { desc = 'Detach a CLI Session' })

vim.keymap.set({ 'x', 'n' }, '<leader>at', function()
  require('sidekick.cli').send({ msg = '{this}' })
end, { desc = 'Send This' })

vim.keymap.set('n', '<leader>af', function()
  require('sidekick.cli').send({ msg = '{file}' })
end, { desc = 'Send File' })

vim.keymap.set('x', '<leader>av', function()
  require('sidekick.cli').send({ msg = '{selection}' })
end, { desc = 'Send Visual Selection' })

vim.keymap.set({ 'n', 'x' }, '<leader>ap', function()
  require('sidekick.cli').prompt()
end, { desc = 'Sidekick Select Prompt' })
