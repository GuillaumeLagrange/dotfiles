-- Test-only init: diffy itself, plus fugitive and mini.nvim pinned to the
-- revs in nvim/nvim-pack-lock.json, cloned into .deps/ on first run (from
-- the local checkouts under site/pack, falling back to GitHub if the
-- pinned rev isn't reachable there). Never loads the user's real config.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local deps = root .. '/.deps'

-- No dependence on the user's git config (commit signing with a
-- hardware key hangs `git commit`). The live GitHub run keeps the global
-- config for gh's credential helper, but never signs.
if not vim.env.DIFFY_TESTGH then
  vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
  vim.env.GIT_CONFIG_NOSYSTEM = '1'
end
vim.env.GIT_CONFIG_COUNT = '2'
vim.env.GIT_CONFIG_KEY_0 = 'commit.gpgsign'
vim.env.GIT_CONFIG_VALUE_0 = 'false'
vim.env.GIT_CONFIG_KEY_1 = 'tag.gpgsign'
vim.env.GIT_CONFIG_VALUE_1 = 'false'

local function git(dir, args)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = dir, text = true }):wait()
end

local function clone_at(dest, src, rev)
  vim.fn.delete(dest, 'rf')
  local clone = git(nil, { 'clone', '--quiet', src, dest })
  if clone.code ~= 0 then
    return false, clone.stderr
  end
  local checkout = git(dest, { 'checkout', '--quiet', rev })
  if checkout.code ~= 0 then
    return false, checkout.stderr
  end
  return true
end

local function ensure(name, local_src, url, rev)
  local dest = deps .. '/' .. name
  if vim.fn.isdirectory(dest) == 0 then
    vim.fn.mkdir(deps, 'p')
    local ok, err = clone_at(dest, local_src, rev)
    if not ok then
      ok, err = clone_at(dest, url, rev)
      if not ok then
        error(('minimal_init: could not fetch %s at %s: %s'):format(name, rev, err))
      end
    end
  end
  vim.opt.rtp:prepend(dest)
end

ensure(
  'vim-fugitive',
  vim.fn.expand('~/.local/share/nvim/site/pack/core/opt/vim-fugitive'),
  'https://github.com/tpope/vim-fugitive',
  '3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0'
)

ensure(
  'mini.nvim',
  vim.fn.expand('~/.local/share/nvim/site/pack/core/opt/mini.nvim'),
  'https://github.com/echasnovski/mini.nvim',
  '9d01f392b33fb2ba36fbc87fc0bf4453e63ffb0a'
)

vim.opt.rtp:prepend(root)
package.path = root .. '/?.lua;' .. package.path
-- `--noplugin` blocks automatic plugin/ sourcing; do it ourselves.
vim.cmd('runtime plugin/fugitive.vim')
vim.cmd('runtime plugin/diffy.lua')

require('mini.test').setup()
