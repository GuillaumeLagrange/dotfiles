return {
  {
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    -- branch = '0.1.x',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',
        build = 'make',
        cond = function()
          return vim.fn.executable('make') == 1
        end,
      },

      { 'nvim-telescope/telescope-ui-select.nvim' },

      { 'nvim-telescope/telescope-frecency.nvim' },

      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },

      { 'jonarrien/telescope-cmdline.nvim' },
    },

    config = function()
      require('telescope').setup({
        -- You can put your default mappings / updates / etc. in here
        --  All the info you're looking for is in `:help telescope.setup()`
        defaults = {
          path_display = { 'truncate' },
          mappings = {
            i = {
              ['<C-h>'] = 'which_key',
              ['<C-l>'] = 'select_default',
            },
            n = {
              ['<C-h>'] = 'which_key',
              ['<C-l>'] = 'select_default',
            },
          },
        },
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      })

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')
      pcall(require('telescope').load_extension, 'file_browser')
      pcall(require('telescope').load_extension, 'cmdline')

      -- See `:help telescope.builtin`
      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      -- vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [f]iles' })
      vim.keymap.set('n', '<leader>sf', function()
        require('telescope').extensions.frecency.frecency({
          workspace = 'CWD',
          path_display = { truncate = 10 },
          auto_validate = true,
          db_validate_threshold = 1,
        })
      end, { desc = '[S]earch [f]iles' })
      vim.keymap.set('n', '<leader>sF', function()
        builtin.git_files({ use_file_path = true })
      end, { desc = '[S]earch all [F]iles' })
      vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
      vim.keymap.set('n', '<leader>cd', function()
        require('telescope').extensions.file_browser.file_browser({ path = require('utils').get_git_root() })
      end, { desc = 'Cd from git root' })
      vim.keymap.set('n', '<leader>sb', function()
        builtin.buffers({ sort_mru = true })
      end, {
        desc = '[S]earch [B]uffers',
      })
      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>sc', function()
        builtin.find_files({ cwd = vim.fn.stdpath('config') })
      end, { desc = '[S]earch Recent Files ("." for repeat)' })

      vim.keymap.set('n', '<leader><leader>', builtin.resume, { desc = '[ ] Search Resume' })

      -- Slightly advanced example of overriding default behavior and theme
      vim.keymap.set('n', '<leader>/', function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown({
          winblend = 10,
          previewer = false,
        }))
      end, { desc = '[/] Fuzzily search in current buffer' })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set('n', '<leader>s/', function()
        builtin.live_grep({
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        })
      end, { desc = '[S]earch [/] in Open Files' })

      vim.keymap.set('n', '<leader>;', '<CMD>Telescope cmdline<CR>', { desc = 'fuzzy cmdline' })
    end,
  },
}
