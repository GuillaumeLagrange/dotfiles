-- Minimal init for running the agent-diff test suite headless, independent of
-- the full user config. Run the suite with `just test` from the plugin root.

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local pkg_dir = vim.fn.fnamemodify(here, ':h') -- lua/agent-diff/

-- `-u` sets this init file but leaves the standard config dirs (~/.config/nvim,
-- …) on the runtimepath. Putting the plugin's lua/ dir on the runtimepath (or
-- on package.path) would make its siblings require-able too — including modules
-- that shadow ones the busted runner needs (e.g. a term.lua that returns a
-- boolean crashes luassert). So keep only $VIMRUNTIME + plenary reachable, and
-- expose *only* the `agent-diff.*` package via a scoped searcher.
local rtp = { vim.env.VIMRUNTIME }

local plenary = vim.fn.expand('~/.local/share/nvim/site/pack/core/opt/plenary.nvim')
if vim.fn.isdirectory(plenary) == 1 then
  rtp[#rtp + 1] = plenary
end

vim.opt.runtimepath = rtp
vim.opt.packpath = ''

-- Resolve `agent-diff` and `agent-diff.<mod>` to files under pkg_dir, and
-- nothing else. Leaves every other module to the default searchers.
table.insert(package.loaders, 1, function(name)
  local sub = name:match('^agent%-diff%.(.+)$')
  if name ~= 'agent-diff' and not sub then
    return nil
  end
  local rel = sub and (sub:gsub('%.', '/')) or 'init'
  for _, file in ipairs({ pkg_dir .. '/' .. rel .. '.lua', pkg_dir .. '/' .. rel .. '/init.lua' }) do
    if vim.fn.filereadable(file) == 1 then
      local chunk, err = loadfile(file)
      return chunk or error(err)
    end
  end
  return ('\n\tno agent-diff file for %q under %s'):format(name, pkg_dir)
end)

vim.opt.swapfile = false
