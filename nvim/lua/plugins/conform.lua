return {
  {
    'stevearc/conform.nvim',
    opts = {
      notify_on_error = true,
      format_on_save = true,
      default_format_opts = {
        timeout_ms = 500,
        lsp_format = 'fallback',
      },
      formatters_by_ft = {
        lua = { 'stylua' },
        python = { 'isort', lsp_format = 'last' },
        javastript = { 'prettier' },
        typescript = { 'prettier' },
        typescriptreact = { 'prettier' },
        cmake = { 'gersemi' },
        markdown = { 'prettier' },
        mdx = { 'prettier' },
        toml = { 'taplo' },
      },
    },
  },
}
