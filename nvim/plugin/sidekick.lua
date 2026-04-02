require('sidekick').setup({
  nes = {
    enabled = false,
    debounce = 100,
  },
})

-- Make Shift+Enter send the correct sequence in neovim terminal buffers (for Claude Code)
vim.keymap.set('t', '<S-Enter>', function()
  local chan = vim.b.terminal_job_id
  if chan then
    vim.api.nvim_chan_send(chan, '\x1b[13;2u')
  end
end, { desc = 'Send Shift+Enter to terminal' })

vim.keymap.set({ 'n', 'i' }, '<tab>', function()
  if not require('sidekick').nes_jump_or_apply() then
    return '<Tab>'
  end
end, { expr = true, desc = 'Goto/Apply Next Edit Suggestion' })

vim.keymap.set({ 'n', 't', 'i', 'x' }, '<c-.>', function()
  require('sidekick.cli').toggle({ name = 'claude', focus = true })
end, { desc = 'Sidekick Toggle' })

vim.keymap.set('n', '<leader>aa', function()
  require('sidekick.cli').toggle({ name = 'claude', focus = true })
end, { desc = 'Sidekick Toggle CLI' })

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
