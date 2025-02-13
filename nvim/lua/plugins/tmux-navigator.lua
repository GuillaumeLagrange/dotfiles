vim.g.tmux_navigator_no_mappings = 1

return {
  'christoomey/vim-tmux-navigator',
  config = function()
    vim.keymap.set('n', '<c-h>', '<CMD>TmuxNavigateLeft<CR>')
    vim.keymap.set('n', '<c-j>', '<CMD>TmuxNavigateDown<CR>')
    vim.keymap.set('n', '<c-k>', '<CMD>TmuxNavigateUp<CR>')
    vim.keymap.set('n', '<c-l>', '<CMD>TmuxNavigateRight<CR>')
  end,
  cmd = {
    'TmuxNavigateLeft',
    'TmuxNavigateDown',
    'TmuxNavigateUp',
    'TmuxNavigateRight',
    'TmuxNavigatePrevious',
    'TmuxNavigatorProcessList',
  },
  keys = {
    { '<c-h>' },
    { '<c-j>' },
    { '<c-k>' },
    { '<c-l>' },
  },
}
