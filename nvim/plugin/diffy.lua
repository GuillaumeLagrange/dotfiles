-- Prepends nvim/diffy (sibling of this file's parent) to 'runtimepath' and
-- sources its own plugin/diffy.lua, so diffy works whether nvim/ is the
-- user's real config dir or a fresh checkout elsewhere. Locates itself via
-- its own source path rather than a hardcoded prefix.
local here = debug.getinfo(1, 'S').source:sub(2)
local dir = vim.fn.fnamemodify(here, ':h:h') .. '/diffy'

vim.opt.rtp:prepend(dir)
vim.cmd.runtime('plugin/diffy.lua')
