vim.pack.add({
  'https://github.com/windwp/nvim-autopairs',
})

local npairs = require('nvim-autopairs')
local Rule = require('nvim-autopairs.rule')
npairs.setup({
  check_ts = true,
})
npairs.add_rules({
  Rule('|', '|', 'rust')
    :with_pair(function(opts)
      local line = opts.line
      local col = opts.col
      return line:sub(col, col):match('%s') or line:sub(col, col):match('[%w%p]')
    end)
    :with_move(function(opts)
      return opts.prev_char:match('|') ~= nil
    end)
    :use_key('|'),
})
