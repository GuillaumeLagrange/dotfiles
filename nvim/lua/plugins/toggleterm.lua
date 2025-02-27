vim.api.nvim_create_augroup('disable_folding_toggleterm', { clear = true })

vim.api.nvim_create_autocmd('FileType', {
  group = 'disable_folding_toggleterm',
  pattern = 'toggleterm',
  callback = function(ev)
    local bufnr = ev.buf
    vim.api.nvim_buf_set_option(bufnr, 'foldmethod', 'manual')
    vim.api.nvim_buf_set_option(bufnr, 'foldtext', 'foldtext()')
  end,
})

return {
  {
    'akinsho/toggleterm.nvim',
    version = '*',
    opts = {
      open_mapping = [[<C-\>]],
      persist_mode = false, -- does not play nice with auto insert mode autocmds
      -- direction = 'float',
      float_opts = {
        border = 'curved',
      },
    },
  },
}
