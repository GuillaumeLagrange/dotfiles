-- Gruvbox Material (primary colorscheme)
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('custom_highlights_gruvboxmaterial', {}),
  pattern = 'gruvbox-material',
  callback = function()
    local config = vim.fn['gruvbox_material#get_configuration']()
    local palette = vim.fn['gruvbox_material#get_palette'](config.background, config.foreground, config.colors_override)
    local set_hl = vim.fn['gruvbox_material#highlight']

    set_hl('DiffText', palette.none, palette.bg_visual_yellow)
    set_hl('NormalFloat', palette.none, palette.bg1)
    vim.api.nvim_set_hl(0, 'MiniFilesCursorLine', { bg = palette.bg_visual_green[1] })
    vim.api.nvim_set_hl(0, 'TreesitterContext', { bg = palette.bg_dim[1] })
    vim.api.nvim_set_hl(0, 'FloatBorder', { bg = 'NONE' })
    vim.api.nvim_set_hl(0, 'NormalFloat', { bg = 'NONE' })
  end,
})

vim.cmd.colorscheme('gruvbox-material')
