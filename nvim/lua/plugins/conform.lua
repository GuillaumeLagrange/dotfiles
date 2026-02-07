return {
  {
    'stevearc/conform.nvim',
    opts = {
      notify_on_error = true,
      format_on_save = true,
      default_format_opts = {
        timeout_ms = 1000,
        lsp_format = 'fallback',
      },
      formatters_by_ft = {
        lua = { 'stylua' },
        python = { 'isort', lsp_format = 'last' },
        javascript = { 'oxfmt', timeout_ms = 2000 },
        typescript = { 'oxfmt', timeout_ms = 2000 },
        typescriptreact = { 'oxfmt', timeout_ms = 2000 },
        json = { 'oxfmt', timeout_ms = 2000 },
        jsonc = { 'oxfmt', timeout_ms = 2000 },
        cmake = { 'gersemi' },
        markdown = { 'oxfmt' },
        mdx = { 'prettier', timeout_ms = 2000 },
        toml = { 'taplo' },
      },
    },
  },
}
