vim.pack.add({
  'https://github.com/echasnovski/mini.nvim',
})

local session = require('session')

require('mini.ai').setup({ n_lines = 500 })

require('mini.files').setup({
  mappings = {
    close = 'q',
    go_in = '<C-L>',
    go_in_plus = 'L',
    go_out = '<C-H>',
    go_out_plus = 'H',
    mark_goto = "'",
    mark_set = 'm',
    reset = '<BS>',
    reveal_cwd = '@',
    show_help = 'g?',
    synchronize = '=',
    trim_left = '<',
    trim_right = '>',
  },
  options = {
    use_as_default_explorer = false,
  },
})

require('mini.bufremove').setup()
vim.keymap.set('n', '<leader>bd', function()
  local bd = MiniBufremove.delete
  if vim.bo.modified then
    local choice = vim.fn.confirm(('Save changes to %q?'):format(vim.fn.bufname()), '&Yes\n&No\n&Cancel')
    if choice == 1 then -- Yes
      vim.cmd.write()
      bd(0)
    elseif choice == 2 then -- No
      bd(0, true)
    end
  else
    bd(0)
  end
end, { desc = 'Delete Buffer' })

vim.keymap.set('n', '<leader>bD', function()
  MiniBufremove.delete(0, true)
end, { desc = 'Delete Buffer (force)' })

require('mini.sessions').setup({
  autoread = true,
  autowrite = true,
  file = 'Session.vim',
  verbose = { read = false, write = false, delete = true },
  hooks = { pre = { write = session.close_ephemeral_buffers } },
})

require('mini.indentscope').setup({
  symbol = '╎',
  options = { try_as_border = true },
})

vim.api.nvim_create_autocmd('TermOpen', {
  callback = function(args)
    vim.b[args.buf].miniindentscope_disable = true
  end,
})

local miniclue = require('mini.clue')
require('mini.clue').setup({
  triggers = {
    -- Leader triggers
    { mode = { 'n', 'x' }, keys = '<Leader>' },

    -- `[` and `]` keys
    { mode = 'n', keys = '[' },
    { mode = 'n', keys = ']' },

    -- Built-in completion
    { mode = 'i', keys = '<C-x>' },

    -- `g` key
    { mode = { 'n', 'x' }, keys = 'g' },

    -- Marks
    { mode = { 'n', 'x' }, keys = "'" },
    { mode = { 'n', 'x' }, keys = '`' },

    -- Registers
    { mode = { 'n', 'x' }, keys = '"' },
    { mode = { 'i', 'c' }, keys = '<C-r>' },

    -- Window commands
    { mode = 'n', keys = '<C-w>' },

    -- `z` key
    { mode = { 'n', 'x' }, keys = 'z' },
  },

  window = {
    delay = 500,
  },

  clues = {
    -- Enhance this by adding descriptions for <Leader> mapping groups
    miniclue.gen_clues.square_brackets(),
    miniclue.gen_clues.builtin_completion(),
    miniclue.gen_clues.g(),
    miniclue.gen_clues.marks(),
    miniclue.gen_clues.registers(),
    miniclue.gen_clues.windows(),
    miniclue.gen_clues.z(),
  },
})

require('mini.notify').setup({
  lsp_progress = {
    enable = false,
  },
})
vim.keymap.set('n', '<leader>un', function()
  MiniNotify.clear()
end, { desc = 'Delete All Notifications' })
vim.keymap.set('n', '<leader>uN', function()
  MiniNotify.show_history()
end, { desc = 'Show notification history' })
