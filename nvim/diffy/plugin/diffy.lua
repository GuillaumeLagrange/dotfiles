-- :Diffy command + completion. Nothing else runs at startup.
local diffy = require('diffy')

-- Range args (`A..B`, `A...B`) and the bare command aren't completed; they
-- fall through to `diffy.command`.
local SUBCOMMANDS = { 'branch', 'pr', 'file', 'conflicts', 'restore', 'review', 'threads', 'panel', 'close' }

local function complete(arg_lead)
  return vim.tbl_filter(function(name)
    return name:sub(1, #arg_lead) == arg_lead
  end, SUBCOMMANDS)
end

vim.api.nvim_create_user_command('Diffy', function(cmd_opts)
  diffy.command(cmd_opts.fargs)
end, {
  nargs = '*',
  complete = complete,
  desc = 'Open or control a diffy session',
})
