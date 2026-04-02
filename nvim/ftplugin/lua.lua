-- Lazydev provides enhanced Lua LSP support for Neovim config/plugin development
-- Guard against running setup multiple times
if vim.g._lazydev_setup_done then
  return
end
vim.g._lazydev_setup_done = true

require('lazydev').setup({
  library = {
    { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
    { path = '~/dotfiles/nvim' },
  },
})
