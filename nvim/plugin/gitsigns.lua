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
    map('n', '<leader>gb', gs.blame, 'Git blame')
    map('n', '<leader>ghu', gs.undo_stage_hunk, 'Undo Stage Hunk')
    map('n', '<leader>ghp', gs.preview_hunk_inline, 'Preview Hunk Inline')
  end,
})
