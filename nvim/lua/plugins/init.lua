return {
  'tpope/vim-sleuth', -- Detect tabstop and shiftwidth automatically
  'tpope/vim-abolish',
  'tpope/vim-surround',

  -- Handle big files better
  'pteroctopus/faster.nvim',

  { 'numToStr/Comment.nvim', opts = {} },

  {
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '▎' },
        change = { text = '▎' },
        delete = { text = '' },
        topdelete = { text = '' },
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
    },
  },

  {
    'folke/which-key.nvim',
    event = 'VimEnter',
    config = function()
      require('which-key').setup({
        notify = false,
      })

      -- Document existing key chains
      require('which-key').add({
        { '<leader>c', group = '[C]ode' },
        { '<leader>d', group = '[D]ocument' },
        { '<leader>r', group = '[R]ename' },
        { '<leader>s', group = '[S]earch' },
        { '<leader>w', group = '[W]orkspace' },
      })
    end,
  },

  -- {
  --   'sainnhe/gruvbox-material',
  --   priority = 1000, -- Make sure to load this before all the other start plugins.
  --   lazy = false,
  --   init = function()
  --     vim.cmd.colorscheme('gruvbox-material')
  --   end,
  -- },

  {
    'ellisonleao/gruvbox.nvim',
    priority = 1000,
    opts = { transparent_mode = true, contrast = '' },
    init = function()
      vim.cmd.colorscheme('gruvbox')
    end,
  },

  -- Highlight todo, notes, etc in comments
  { 'folke/todo-comments.nvim', event = 'VimEnter', dependencies = { 'nvim-lua/plenary.nvim' }, opts = { signs = false } },

  {
    'tpope/vim-fugitive',
    lazy = false,
    keys = {
      { '<leader>gs', '<cmd>Git<CR>', mode = 'n', desc = 'Git status' },
      { '<leader>gb', '<cmd>Git blame<cr>', mode = 'n', desc = 'Git blame' },
      { '<leader>gr', '<cmd>Gread<cr>', mode = 'n', desc = 'Read buffer' },
      { '<leader>gw', '<cmd>Gwrite<cr>', mode = 'n', desc = 'Write buffer' },
      { '<leader>gd', '<cmd>Gdiff<cr>', mode = 'n', desc = 'Git diff' },

      { '<leader>gy', ':GBrowse!<CR>', mode = { 'n', 'v' }, desc = 'Git yank key' },
    },
    dependencies = { 'tpope/vim-rhubarb' },
  },

  {
    'ojroques/vim-oscyank',
    config = function()
      -- Should be accompanied by a setting clipboard in tmux.conf, also see
      -- https://github.com/ojroques/vim-oscyank#the-plugin-does-not-work-with-tmux
      vim.g.oscyank_term = 'default'
      vim.g.oscyank_max_length = 0 -- unlimited
      -- Below autocmd is for copying to OSC52 for any yank operation,
      -- see https://github.com/ojroques/vim-oscyank#copying-from-a-register
      vim.api.nvim_create_autocmd('TextYankPost', {
        pattern = '*',
        callback = function()
          if vim.v.event.operator == 'y' and vim.v.event.regname == '' then
            vim.cmd('OSCYankRegister "')
          end
        end,
      })
    end,
  },

  { 'rickhowe/diffchar.vim' },

  {
    'nvim-pack/nvim-spectre',
    keys = {
      { '<leader>sr', '<cmd>lua require("spectre").toggle()<CR>', mode = 'n', desc = 'Toggle Spectre' },
    },
  },

  {
    'j-hui/fidget.nvim',
    opts = {
      notification = {
        window = {
          winblend = 0,
        },
      },
      progress = {
        lsp = {
          progress_ringbuf_size = 4096,
        },
      },
    },
  },

  {
    'OXY2DEV/markview.nvim',
    lazy = false, -- Docs says not to lazy load this plugin
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'nvim-tree/nvim-web-devicons',
    },
    config = function()
      require('markview').setup()

      vim.keymap.set('n', '<leader>mv', '<cmd>Markview<CR>', { desc = 'Toggle markview' })
    end,
  },

  {
    'sindrets/diffview.nvim',
    cmd = {
      'DiffviewOpen',
      'DiffviewFileHistory',
    },
    keys = {
      { '<leader>dvo', '<cmd>DiffviewOpen<CR>', mode = 'n', desc = 'Open diffview' },
      { '<leader>dvc', '<cmd>DiffviewClose<CR>', mode = 'n', desc = 'Close diffview' },
      {
        '<leader>dvm',
        function()
          local main_branch = require('utils').get_git_main_branch()
          vim.print(main_branch)
          if main_branch then
            vim.cmd('DiffviewOpen ' .. main_branch)
          else
            vim.cmd('DiffviewOpen')
          end
        end,
        mode = 'n',
        desc = 'Open diffview HEAD..main',
      },
      { '<leader>dvf', '<cmd>DiffviewFileHistory %<CR>', mode = 'n', desc = 'Open diffview file history for current file' },
    },
  },
}
