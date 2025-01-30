local session = require('session')

return { -- Collection of various small independent plugins/modules
  'echasnovski/mini.nvim',
  config = function()
    -- Better Around/Inside textobjects
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
    })

    require('mini.bufremove').setup()
    vim.keymap.set('n', '<leader>bd', function()
      local bd = require('mini.bufremove').delete
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
      require('mini.bufremove').delete(0, true)
    end, { desc = 'Delete Buffer (force)' })

    require('mini.sessions').setup({
      autoread = true,
      autowrite = true,
      file = 'Session.vim',
      verbose = { read = true, write = true, delete = true },
      hooks = { pre = { write = session.close_ephemeral_buffers } },
    })

    require('mini.starter').setup({})
  end,
}
