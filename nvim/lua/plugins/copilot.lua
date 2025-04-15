local toggle_copilot = function()
  if vim.b.copilot_enabled == nil or vim.b.copilot_enabled then
    vim.b.copilot_enabled = false
    vim.print('Copilot disabled')
  else
    vim.b.copilot_enabled = true
    vim.print('Copilot enabled')
  end
end

return {
  {
    'github/copilot.vim',
    lazy = false,
    -- TODO: Update this once I don't need support for node 18
    commit = '87038123804796ca7af20d1b71c3428d858a9124',
    init = function()
      vim.keymap.set('i', '<M-w>', '<Plug>(copilot-accept-word)', { desc = 'Accept copilot word' })
      vim.keymap.set('i', '<M-l>', '<Plug>(copilot-accept-line)', { desc = 'Accept copilot line' })
      vim.keymap.set('n', '<leader>uc', toggle_copilot, { desc = 'Toggle Copilot' })
      vim.keymap.set('i', '<M-u>', toggle_copilot, { desc = 'Toggle Copilot' })
    end,
  },
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    event = { 'CmdlineEnter' },
    keys = { { '<leader>cc', '<cmd>CopilotChat<cr>', desc = 'Open Copilot Chat' } },
    dependencies = {
      { 'github/copilot.vim' },
      { 'nvim-lua/plenary.nvim', branch = 'master' },
    },
    build = 'make tiktoken',
    opts = {},
  },
}
