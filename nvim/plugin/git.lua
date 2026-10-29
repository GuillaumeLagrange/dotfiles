vim.pack.add({
  'https://github.com/tpope/vim-fugitive',
  'https://github.com/tpope/vim-rhubarb',

  'https://github.com/lewis6991/gitsigns.nvim',
})

vim.keymap.set('n', '<leader>gb', '<cmd>Git blame<CR>', { desc = 'Git blame' })
vim.keymap.set('n', '<leader>gs', '<cmd>Git<CR>', { desc = 'Git status' })
vim.keymap.set('n', '<leader>gr', '<cmd>Gread<cr>', { desc = 'Read buffer' })
vim.keymap.set('n', '<leader>gw', '<cmd>Gwrite<cr>', { desc = 'Write buffer' })
vim.keymap.set('n', '<leader>gd', '<cmd>Gdiff<cr>', { desc = 'Git diff' })
vim.keymap.set({ 'n', 'v' }, '<leader>gy', ':GBrowse!<CR>', { desc = 'Git yank key' })

require('gitsigns').setup({
  signs = {
    add = { text = '▎' },
    change = { text = '▎' },
    delete = { text = '' },
    topdelete = { text = '' },
    changedelete = { text = '▎' },
    untracked = { text = '▎' },
  },
  on_attach = function(buffer)
    local gs = package.loaded.gitsigns

    local function map(mode, l, r, desc)
      vim.keymap.set(mode, l, r, { buffer = buffer, desc = desc })
    end

    map('n', ']h', gs.next_hunk, 'Next Hunk')
    map('n', '[h', gs.prev_hunk, 'Prev Hunk')
    map({ 'n', 'v' }, '<leader>ghw', ':Gitsigns stage_hunk<CR>', 'Stage Hunk')
    map({ 'n', 'v' }, '<leader>ghr', ':Gitsigns reset_hunk<CR>', 'Reset Hunk')
    map('n', '<leader>ghu', gs.undo_stage_hunk, 'Undo Stage Hunk')
    map('n', '<leader>ghp', gs.preview_hunk_inline, 'Preview Hunk Inline')
  end,
})

-- Gitsigns blame keeps its cursor-sync autocmds after the blame window closes: entering the
-- blamed buffer anywhere (e.g. a diffy tab) then moves the cursor of the window it was blamed
-- in, which errors once that window shows a shorter buffer.
vim.api.nvim_create_autocmd('WinClosed', {
  group = vim.api.nvim_create_augroup('gitsigns_blame_cleanup', {}),
  callback = function(args)
    if vim.bo[args.buf].filetype ~= 'gitsigns-blame' then
      return
    end
    -- After gitsigns' own WinClosed handler, which restores the source window options.
    vim.schedule(function()
      if vim.fn.exists('#GitsignsBlame') == 1 then
        vim.api.nvim_clear_autocmds({ group = 'GitsignsBlame', event = { 'BufEnter', 'BufLeave' } })
      end
    end)
  end,
})
