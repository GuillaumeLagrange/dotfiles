vim.pack.add({
  'https://github.com/neovim/nvim-lspconfig',
  'https://github.com/folke/lazydev.nvim',
})

vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
  callback = function(event)
    local map = function(keys, func, desc)
      vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
    end

    map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
    map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
    map('K', vim.lsp.buf.hover, 'Hover Documentation')
    map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

    map('<C-w>]', function()
      vim.cmd('vsplit')
      local key = vim.api.nvim_replace_termcodes('<C-]>', true, true, true)
      vim.api.nvim_feedkeys(key, 'n', true)
    end, 'Goto Definition in vsplit')

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

-- Extend default capabilities with blink.cmp
vim.lsp.config('*', {
  capabilities = require('blink.cmp').get_lsp_capabilities(),
})

-- LSP server configs
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

vim.lsp.config.harper_ls = {
  settings = {
    ['harper-ls'] = {
      userDictPath = vim.fn.expand('~/.config/harper-ls/dictionary.txt'),
      linters = {
        ExpandMemoryShorthands = false,
        OrthographicConsistency = false, -- All caps warnings
        ToDoHyphen = false, -- All caps warnings
        -- TODO: Dynamically add linters from code action, and add a strict mode to that has a separate source of linters
      },
    },
  },
}
vim.lsp.enable('harper_ls')

vim.keymap.set('n', '<leader>lh', function()
  local enabled = vim.lsp.is_enabled('harper_ls')
  vim.lsp.enable('harper_ls', not enabled)
  vim.notify('harper_ls ' .. (enabled and 'disabled' or 'enabled'))
end, { desc = 'Toggle Harper' })
