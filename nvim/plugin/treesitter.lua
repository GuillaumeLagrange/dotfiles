require('nvim-treesitter').setup({
  ensure_installed = { 'bash', 'c', 'html', 'lua', 'markdown', 'vim', 'vimdoc', 'rust', 'typescript' },
  auto_install = true,
  highlight = {
    enable = true,
    disable = { 'dockerfile' },
    additional_vim_regex_highlighting = { 'ruby' },
  },
  indent = { enable = true, disable = { 'ruby' } },
  incremental_selection = {
    enable = true,
    keymaps = {
      init_selection = '<C-space>',
      node_incremental = '<C-space>',
      scope_incremental = false,
      node_decremental = '<bs>',
    },
  },
})

vim.treesitter.language.register('markdown', { 'mdx' })

require('treesitter-context').setup({ max_lines = 8 })
