vim.loader.enable()

-- Set <space> as the leader key
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

require('options')
require('commands')
require('autocmds')
require('keymaps')
require('term')
require('session')
require('diagnostics')

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
vim.pack.add({
  -- Simple plugins (no config needed or configured via globals)
  'https://github.com/tpope/vim-sleuth',
  'https://github.com/tpope/vim-abolish',
  'https://github.com/tpope/vim-surround',
  'https://github.com/pteroctopus/faster.nvim',
  'https://github.com/numToStr/Comment.nvim',
  'https://github.com/rickhowe/diffchar.vim',

  -- Colorschemes
  'https://github.com/sainnhe/gruvbox-material',
  'https://github.com/ellisonleao/gruvbox.nvim',
  'https://github.com/folke/tokyonight.nvim',
  'https://github.com/olimorris/onedarkpro.nvim',

  -- Git
  'https://github.com/lewis6991/gitsigns.nvim',
  'https://github.com/tpope/vim-fugitive',
  'https://github.com/tpope/vim-rhubarb',
  'https://github.com/sindrets/diffview.nvim',

  -- UI
  'https://github.com/folke/snacks.nvim',
  'https://github.com/nvim-lualine/lualine.nvim',
  'https://github.com/nvim-tree/nvim-web-devicons',
  'https://github.com/ofseed/copilot-status.nvim',
  'https://github.com/folke/which-key.nvim',
  'https://github.com/j-hui/fidget.nvim',
  'https://github.com/folke/todo-comments.nvim',
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/barrettruth/preview.nvim',

  -- Treesitter
  { src = 'https://github.com/nvim-treesitter/nvim-treesitter', version = 'main' },
  'https://github.com/HiPhish/rainbow-delimiters.nvim',
  'https://github.com/nvim-treesitter/nvim-treesitter-context',

  -- LSP
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/folke/lazydev.nvim',

  -- Completion (dependencies first)
  'https://github.com/L3MON4D3/LuaSnip',
  'https://github.com/rafamadriz/friendly-snippets',
  { src = 'https://github.com/saghen/blink.cmp', version = vim.version.range('1.x') },

  -- Mini
  'https://github.com/echasnovski/mini.nvim',

  -- Search & replace
  'https://github.com/nvim-pack/nvim-spectre',

  -- Code diff
  'https://github.com/MunifTanjim/nui.nvim',
  'https://github.com/esmuellert/codediff.nvim',

  -- Formatting
  'https://github.com/stevearc/conform.nvim',

  -- AI
  'https://github.com/github/copilot.vim',
  'https://github.com/folke/sidekick.nvim',

  -- Tmux
  'https://github.com/christoomey/vim-tmux-navigator',

  -- DAP (dependencies first)
  -- 'https://github.com/nvim-neotest/nvim-nio',
  -- 'https://github.com/rcarriga/nvim-dap-ui',
  -- 'https://github.com/theHamsta/nvim-dap-virtual-text',
  -- 'https://github.com/mxsdev/nvim-dap-vscode-js',
  -- 'https://github.com/jbyuki/one-small-step-for-vimkind',
  -- 'https://github.com/mfussenegger/nvim-dap',

  -- Autopairs
  'https://github.com/windwp/nvim-autopairs',

  -- Rust
  { src = 'https://github.com/mrcjkb/rustaceanvim', version = vim.version.range('8.x') },
})
