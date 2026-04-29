vim.pack.add({
  'https://github.com/folke/snacks.nvim',
})

---@type snacks.Config
require('snacks').setup({
  bigfile = {
    notify = true, -- show notification when big file detected
    size = 1.5 * 1024 * 1024, -- 1.5MB
    line_length = 1000, -- average line length (useful for minified files)
    -- Enable or disable features when big file detected
    ---@param ctx {buf: number, ft:string}
    setup = function(ctx)
      local buf = ctx.buf
      if vim.fn.exists(':NoMatchParen') ~= 0 then
        vim.cmd([[NoMatchParen]])
      end

      -- Shadow matchit's global `%` with the builtin `%`
      local opts = { buffer = buf, silent = true, remap = false }
      for _, mode in ipairs({ 'n', 'x', 'o' }) do
        vim.keymap.set(mode, '%', '%', opts)
        vim.keymap.set(mode, 'g%', '%', opts)
      end
      vim.b[buf].large_file = true
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.wo[win].breakindent = false
      end

      Snacks.util.wo(0, { foldmethod = 'manual', statuscolumn = '', conceallevel = 0 })
      vim.b.completion = false
      vim.b.minianimate_disable = true
      vim.b.minihipatterns_disable = true
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ctx.buf) then
          vim.bo[ctx.buf].syntax = ctx.ft
        end
      end)
    end,
  },
  dashboard = { enabled = false },
  explorer = {
    enabled = true,
    replace_netrw = true,
  },
  input = { enabled = true },
  picker = {
    enabled = true,
    formatters = {
      file = {
        filename_first = false,
        truncate = 80,
        filename_only = false,
        icon_width = 2,
        git_status_hl = true,
      },
    },
    win = {
      input = {
        keys = {
          ['<a-h>'] = false,
          ['<a-i>'] = false,
          ['<c-h>'] = { 'toggle_hidden', mode = { 'n', 'i' } },
          ['<c-g>'] = { 'toggle_ignored', mode = { 'n', 'i' } },
        },
      },
    },
  },
  quickfile = { enabled = true },
  styles = {
    notification = {
      wo = { wrap = true },
    },
  },
})

-- Top Pickers & Explorer
vim.keymap.set('n', '<leader><space>', function()
  Snacks.picker.smart({ filter = { cwd = true } })
end, { desc = 'Smart Find Files' })
vim.keymap.set('n', '<leader>,', function()
  Snacks.picker.buffers()
end, { desc = 'Buffers' })
vim.keymap.set('n', '<leader>/', function()
  Snacks.picker.grep()
end, { desc = 'Grep' })
vim.keymap.set('n', '<leader>:', function()
  Snacks.picker.command_history()
end, { desc = 'Command History' })
vim.keymap.set('n', '<leader>n', function()
  Snacks.notifier.show_history()
end, { desc = 'Notification History' })
vim.keymap.set('n', '<leader>e', function()
  Snacks.explorer()
end, { desc = 'File Explorer' })

-- find
vim.keymap.set('n', '<leader>fb', function()
  Snacks.picker.buffers()
end, { desc = 'Buffers' })
vim.keymap.set('n', '<leader>fc', function()
  Snacks.picker.files({ cwd = vim.fn.stdpath('config') })
end, { desc = 'Find Config File' })
vim.keymap.set('n', '<leader>ff', function()
  Snacks.picker.files()
end, { desc = 'Find Files' })
vim.keymap.set('n', '<leader>fg', function()
  Snacks.picker.git_files()
end, { desc = 'Find Git Files' })
vim.keymap.set('n', '<leader>fr', function()
  Snacks.picker.recent()
end, { desc = 'Recent' })
vim.keymap.set('n', '<leader>fw', function()
  Snacks.picker.files({ cwd = '.github' })
end, { desc = 'Find Workflow Files' })
vim.keymap.set('n', '<leader>fp', function()
  Snacks.picker.files({ cwd = '~/.claude/plans' })
end, { desc = 'Find Plans' })

-- Grep
vim.keymap.set('n', '<leader>sb', function()
  Snacks.picker.lines()
end, { desc = 'Buffer Lines' })
vim.keymap.set('n', '<leader>sB', function()
  Snacks.picker.grep_buffers()
end, { desc = 'Grep Open Buffers' })
vim.keymap.set('n', '<leader>sg', function()
  Snacks.picker.grep()
end, { desc = 'Grep' })
vim.keymap.set({ 'n', 'x' }, '<leader>sw', function()
  Snacks.picker.grep_word()
end, { desc = 'Visual selection or word' })

-- search
vim.keymap.set('n', '<leader>s"', function()
  Snacks.picker.registers()
end, { desc = 'Registers' })
vim.keymap.set('n', '<leader>s/', function()
  Snacks.picker.search_history()
end, { desc = 'Search History' })
vim.keymap.set('n', '<leader>sa', function()
  Snacks.picker.autocmds()
end, { desc = 'Autocmds' })
vim.keymap.set('n', '<leader>sc', function()
  Snacks.picker.command_history()
end, { desc = 'Command History' })
vim.keymap.set('n', '<leader>sC', function()
  Snacks.picker.commands()
end, { desc = 'Commands' })
vim.keymap.set('n', '<leader>sd', function()
  Snacks.picker.diagnostics()
end, { desc = 'Diagnostics' })
vim.keymap.set('n', '<leader>sD', function()
  Snacks.picker.diagnostics_buffer()
end, { desc = 'Buffer Diagnostics' })
vim.keymap.set('n', '<leader>sh', function()
  Snacks.picker.help()
end, { desc = 'Help Pages' })
vim.keymap.set('n', '<leader>sH', function()
  Snacks.picker.highlights()
end, { desc = 'Highlights' })
vim.keymap.set('n', '<leader>si', function()
  Snacks.picker.icons()
end, { desc = 'Icons' })
vim.keymap.set('n', '<leader>sj', function()
  Snacks.picker.jumps()
end, { desc = 'Jumps' })
vim.keymap.set('n', '<leader>sk', function()
  Snacks.picker.keymaps()
end, { desc = 'Keymaps' })
vim.keymap.set('n', '<leader>sl', function()
  Snacks.picker.loclist()
end, { desc = 'Location List' })
vim.keymap.set('n', '<leader>sm', function()
  Snacks.picker.marks()
end, { desc = 'Marks' })
vim.keymap.set('n', '<leader>sM', function()
  Snacks.picker.man()
end, { desc = 'Man Pages' })
vim.keymap.set('n', '<leader>sq', function()
  Snacks.picker.qflist()
end, { desc = 'Quickfix List' })

-- LSP
vim.keymap.set('n', 'gd', function()
  Snacks.picker.lsp_definitions()
end, { desc = 'Goto Definition' })
vim.keymap.set('n', 'gD', function()
  Snacks.picker.lsp_declarations()
end, { desc = 'Goto Declaration' })
vim.keymap.set('n', 'gr', function()
  Snacks.picker.lsp_references()
end, { nowait = true, desc = 'References' })
vim.keymap.set('n', 'gI', function()
  Snacks.picker.lsp_implementations()
end, { desc = 'Goto Implementation' })
vim.keymap.set('n', 'gy', function()
  Snacks.picker.lsp_type_definitions()
end, { desc = 'Goto T[y]pe Definition' })
vim.keymap.set('n', '<leader>ss', function()
  Snacks.picker.lsp_symbols()
end, { desc = 'LSP Symbols' })
vim.keymap.set('n', '<leader>sS', function()
  Snacks.picker.lsp_workspace_symbols()
end, { desc = 'LSP Workspace Symbols' })

-- Other
vim.keymap.set({ 'n', 't' }, [[<c-\>]], function()
  Snacks.terminal()
end, { desc = 'Toggle Terminal' })
