-- Use local .init.lua to configure rustfmt repo by repo, example:
-- vim.g.rustaceanvim.server.default_settings['rust-analyzer'].rustfmt = {
--   extraArgs = {
--     '--config',
--     'comment_width=120,condense_wildcard_suffixes=false,format_code_in_doc_comments=true,format_macro_bodies=true,hex_literal_case=Upper,imports_granularity=One,normalize_doc_attributes=true,wrap_comments=true',
--   },
-- }

vim.g.auto_ra_attach = true

vim.g.rustaceanvim = {
  -- Plugin configuration
  tools = {},
  -- LSP configuration
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

      -- Create mappings for buffer
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Leader>lrd', '<Cmd>RustLsp debuggables<CR>', {
        noremap = true,
        desc = 'List rust debuggables',
      })
      vim.api.nvim_buf_set_keymap(bufnr, 'n', '<Leader>lre', '<Cmd>RustLsp expandMacro<CR>', {
        noremap = true,
        desc = 'Expand macro',
      })
    end,
    default_settings = {
      ['rust-analyzer'] = {
        cachePriming = false,
        rustfmt = {
          extraArgs = {
            '--config',
            'format_code_in_doc_comments=true',
          },
        },
      },
    },
  },
  -- DAP configuration
  -- dap = {},
}

return {
  {
    'mrcjkb/rustaceanvim',
    version = '^5', -- Recommended
    ft = { 'rust' },
    dev = true,
  },
}
