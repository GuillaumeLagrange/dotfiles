-- vim.lsp.set_log_level('DEBUG')

return { -- LSP Configuration & Plugins
  'neovim/nvim-lspconfig',
  dependencies = {
    -- Automatically install LSPs and related tools to stdpath for Neovim
    {
      'folke/lazydev.nvim',
      ft = 'lua',
      opts = {
        library = {
          { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
          { path = '~/dotfiles/nvim' },
        },
      },
    },
  },
  config = function()
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
      callback = function(event)
        -- NOTE: Remember that Lua is a real programming language, and as such it is possible
        -- to define small helper and utility functions so you don't have to repeat yourself.
        --
        -- In this case, we create a function that lets us more easily define mappings specific
        -- for LSP related items. It sets the mode, buffer and description for us each time.
        local map = function(keys, func, desc)
          vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end

        -- Rename the variable under your cursor.
        --  Most Language Servers support renaming across files, etc.
        map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')

        -- Execute a code action, usually your cursor needs to be on top of an error
        -- or a suggestion from your LSP for this to activate.
        map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')

        -- Opens a popup that displays documentation about the word under your cursor
        --  See `:help K` for why this keymap.
        map('K', vim.lsp.buf.hover, 'Hover Documentation')

        map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

        map('<C-w>]', function()
          vim.cmd('vsplit')
          local key = vim.api.nvim_replace_termcodes('<C-]>', true, true, true)
          vim.api.nvim_feedkeys(key, 'n', true)
        end, 'Goto Definition in vsplit')

        -- The following two autocommands are used to highlight references of the
        -- word under your cursor when your cursor rests there for a little while.
        --    See `:help CursorHold` for information about when this is executed
        --
        -- When you move your cursor, the highlights will be cleared (the second autocommand).
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.server_capabilities.documentHighlightProvider then
          local highlight_augroup = vim.api.nvim_create_augroup('lsp-highlight', { clear = false })
          vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
            buffer = event.buf,
            group = highlight_augroup,
            callback = vim.lsp.buf.document_highlight,
          })

          vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
            buffer = event.buf,
            group = highlight_augroup,
            callback = vim.lsp.buf.clear_references,
          })

          vim.api.nvim_create_autocmd('LspDetach', {
            group = vim.api.nvim_create_augroup('lsp-detach', { clear = true }),
            callback = function(event2)
              vim.lsp.buf.clear_references()
              vim.api.nvim_clear_autocmds({ group = 'lsp-highlight', buffer = event2.buf })
            end,
          })
        end
      end,
    })

    -- LSP servers and clients are able to communicate to each other what features they support.
    --  By default, Neovim doesn't support everything that is in the LSP specification.
    --  When you add nvim-cmp, luasnip, etc. Neovim now has *more* capabilities.
    --  So, we create new capabilities with nvim cmp, and then broadcast that to the servers.
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    capabilities = vim.tbl_deep_extend('force', capabilities, require('blink.cmp').get_lsp_capabilities())

    -- Enable LSP servers
    vim.lsp.config.lua_ls = {
      settings = {
        Lua = {
          diagnostics = {
            disable = { 'redefined-local' },
          },
        },
      },
    }
    vim.lsp.enable('lua_ls')

    vim.lsp.enable('jsonls')
    vim.lsp.enable('ts_ls')

    vim.lsp.config.clangd = {
      filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
    }
    vim.lsp.enable('clangd')

    vim.lsp.enable('prismals')

    vim.lsp.config.ruff = {
      cmd = { 'uv', 'run', 'ruff', 'server' },
    }
    vim.lsp.enable('ruff')

    vim.lsp.config.pyright = {
      cmd = { 'uv', 'run', 'pyright-langserver', '--stdio' },
    }
    vim.lsp.enable('pyright')

    vim.lsp.enable('zls')

    vim.lsp.enable('yamlls')

    -- vim.lsp.config.copilot = {
    --   cmd = { 'copilot-language-server', '--stdio' },
    --   root_markers = { '.git' },
    -- }
    -- vim.lsp.enable('copilot')
    --  TODO: Use native inline when it's on stable
    -- vim.lsp.inline_completion.enable()

    local flakePath = '(builtins.getFlake "/home/guillaume/dotfiles")'
    vim.lsp.config.nixd = {
      settings = {
        nixd = {
          nixpkgs = {
            expr = 'import' .. flakePath .. '.inputs.nixpkgs { }',
          },
          options = {
            home_manager = {
              expr = flakePath .. '.homeConfigurations.guillaume.options',
            },
            nixos = {
              expr = flakePath .. '.nixosConfigurations.xps.options',
            },
          },
        },
      },
    }
    vim.lsp.enable('nixd')
  end,
}
