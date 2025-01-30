return {
  {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    config = function()
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
            -- Ensure `|` is inserted only when it makes sense, like inside a closure
            return line:sub(col, col):match('%s') or line:sub(col, col):match('[%w%p]')
          end)
          :with_move(function(opts)
            return opts.prev_char:match('|') ~= nil
          end)
          :use_key('|'),
        Rule('<', '>'):with_pair(function(opts)
          local before_char = opts.line:sub(opts.col - 1, opts.col - 1)
          -- Insert `>` only if the character before `<` is not whitespace
          return before_char ~= ' ' and before_char ~= ''
        end),
      })
    end,
  },
}
