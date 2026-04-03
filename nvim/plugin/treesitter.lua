require('nvim-treesitter').setup()

-- Install parsers for these languages if not already installed
local ensure_installed = { 'bash', 'c', 'html', 'lua', 'markdown', 'vim', 'vimdoc', 'rust', 'typescript' }
require('nvim-treesitter').install(ensure_installed)

-- Auto-install parser on FileType if not already installed, and start
-- treesitter highlighting for non-bundled parsers (bundled ones like lua,
-- markdown, etc. are started by their ftplugin).
vim.api.nvim_create_autocmd('FileType', {
  callback = function(ev)
    local lang = vim.treesitter.language.get_lang(ev.match) or ev.match
    if pcall(vim.treesitter.language.inspect, lang) then
      -- Parser exists: start highlighting if not already active
      if not vim.b[ev.buf].ts_highlight then
        vim.treesitter.start(ev.buf)
      end
    elseif vim.list_contains(require('nvim-treesitter').get_available(), lang) then
      vim.print('Installing treesitter parser for ' .. lang)
      require('nvim-treesitter').install(lang)
    end
  end,
})

-- Incremental selection keymaps (uses built-in vim.treesitter._select)
vim.keymap.set('n', '<C-space>', function()
  vim.cmd('normal! v')
  require('vim.treesitter._select').select_parent(1)
end, { desc = 'Start treesitter incremental selection' })

vim.keymap.set('x', '<C-space>', function()
  require('vim.treesitter._select').select_parent(1)
end, { desc = 'Expand treesitter selection to parent node' })

vim.keymap.set('x', '<bs>', function()
  require('vim.treesitter._select').select_child(1)
end, { desc = 'Shrink treesitter selection to child node' })

vim.treesitter.language.register('markdown', { 'mdx' })

require('treesitter-context').setup({ max_lines = 8 })
