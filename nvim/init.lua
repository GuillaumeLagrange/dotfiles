vim.loader.enable()

-- Set <space> as the leader key
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

require('options')
-- require('commands')
require('autocmds')
-- require('keymaps')
-- require('term')
-- require('session')
-- require('diagnostics')
require('large_files').setup()

-- [[ Plugin globals — must be set before vim.pack.add() loads the plugins ]]
vim.g.tmux_navigator_no_mappings = 1
vim.g.preview = { typst = true, latex = true, mermaid = true, markdown = true }
vim.g.gruvbox_material_transparent_background = 1
vim.g.copilot_node_command = vim.fn.trim(vim.fn.system('fnm exec --using=22 which node'))

-- [[ PackClean command — remove plugins no longer in vim.pack.add() ]]
vim.api.nvim_create_user_command('PackClean', function()
  local orphans = vim
    .iter(vim.pack.get(nil, { info = false }))
    :filter(function(p)
      return not p.active
    end)
    :map(function(p)
      return p.spec.name
    end)
    :totable()
  if #orphans > 0 then
    vim.pack.del(orphans)
    vim.notify('Removed: ' .. table.concat(orphans, ', '))
  else
    vim.notify('No orphaned plugins found')
  end
end, {})

vim.api.nvim_create_user_command('PackUpdate', function()
  vim.pack.update()
end, {})

-- [[ PackChanged hooks — must be defined before vim.pack.add() ]]
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'nvim-treesitter' and (kind == 'install' or kind == 'update') then
      if not ev.data.active then
        vim.cmd.packadd('nvim-treesitter')
      end
      vim.cmd('TSUpdate')
    end
  end,
})

-- [[ Install and load all plugins ]]
-- vim.pack.add({
--   -- Keep fist
--   'https://github.com/sainnhe/gruvbox-material',
--
--   -- Simple plugins
--   'https://github.com/tpope/vim-sleuth',
--   'https://github.com/tpope/vim-abolish',
--   'https://github.com/tpope/vim-surround',
--
--   -- UI
--   'https://github.com/nvim-tree/nvim-web-devicons',
--   'https://github.com/ofseed/copilot-status.nvim',
--   'https://github.com/folke/todo-comments.nvim',
--   'https://github.com/nvim-lua/plenary.nvim',
--
--   -- Search & replace
--   'https://github.com/nvim-pack/nvim-spectre',
--
--   -- Tmux
--   'https://github.com/christoomey/vim-tmux-navigator',
--
--   -- Rust
--   { src = 'https://github.com/mrcjkb/rustaceanvim', version = vim.version.range('8.x') },
--
--   -- [[ PURGATORY BELOW ]]
--
--   -- Code diff
--   'https://github.com/rickhowe/diffchar.vim',
--   'https://github.com/MunifTanjim/nui.nvim',
--   'https://github.com/esmuellert/codediff.nvim',
--
--   'https://github.com/barrettruth/preview.nvim',
--   'https://github.com/j-hui/fidget.nvim',
--
--   'https://github.com/pteroctopus/faster.nvim', -- handled by snacks?
-- })
