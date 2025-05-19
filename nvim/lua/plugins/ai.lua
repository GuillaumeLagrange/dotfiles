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
    'olimorris/codecompanion.nvim',
    opts = {
      adapters = {
        openai = function()
          return require('codecompanion.adapters').extend('copilot', {
            schema = {
              model = {
                default = 'claude-3-7-sonnet',
              },
            },
          })
        end,
      },
    },
    keys = {
      {
        '<leader>cc',
        function()
          require('codecompanion').toggle()
        end,
        desc = 'Toggle Code Companion',
      },
      -- { '<leader>cC', function() require('codecompanion').toggle(true) end, desc = 'Toggle Code Companion (force)' },
      -- { '<leader>c?', function() require('codecompanion').info() end, desc = 'Code Companion Info' },
    },
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-treesitter/nvim-treesitter',
    },
  },
}
