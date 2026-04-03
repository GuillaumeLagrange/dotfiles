vim.g.auto_ra_attach = true
vim.g.rustaceanvim = {
  tools = {},
  ---@type RustaceanLspClientOpts
  server = {
    load_vscode_settings = true,
    auto_attach = function(bufnr)
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if vim.startswith(bufname, 'octo://') or vim.startswith(bufname, 'fugitive://') then
        return false
      end
      return vim.g.auto_ra_attach
    end,
    on_attach = function(client, bufnr)
      vim.api.nvim_create_autocmd({ 'BufEnter' }, {
        desc = 'Automatically reload cargo settings',
        pattern = { '*.rs' },
        callback = function()
          vim.cmd('RustAnalyzer reloadSettings')
        end,
      })

      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Leader>lrd', '<Cmd>RustLsp debuggables<CR>', {
        noremap = true,
        desc = 'List rust debuggables',
      })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Leader>lre', '<Cmd>RustLsp expandMacro<CR>', {
        noremap = true,
        desc = 'Expand macro',
      })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Leader>lrr', '<Cmd>RustLsp rebuildProcMacros<CR>', {
        noremap = true,
        desc = 'Rebuild proc macros',
      })
    end,
    default_settings = {
      ['rust-analyzer'] = {
        cachePriming = false,
        rustfmt = {},
        files = {
          excludeDirs = {
            '_build',
            '.dart_tool',
            '.flatpak-builder',
            '.git',
            '.gitlab',
            '.gitlab-ci',
            '.gradle',
            '.idea',
            '.next',
            '.project',
            '.scannerwork',
            '.settings',
            '.venv',
            'archetype-resources',
            'bin',
            'hooks',
            'node_modules',
            'po',
            'screenshots',
            'target',
          },
        },
      },
    },
  },
}
