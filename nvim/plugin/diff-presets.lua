-- Experiment: switch diff display presets on the fly. `:DiffPreset` / `<leader>dx` cycles,
-- `:DiffPreset <name>` picks one. The choice applies to every diff tab; nvim starts on github-simple.
local base = 'internal,filler,closeoff'
local presets = {
  { name = 'current', diffopt = base .. ',linematch:60,iwhite', diffchar = true },
  -- GitHub/Linear: git's hunks, rows paired by index, old side red, new side green
  { name = 'github', diffopt = base .. ',indent-heuristic,inline:word', sides = true },
  { name = 'github-simple', diffopt = base .. ',indent-heuristic,inline:simple', sides = true },
  { name = 'github-none', diffopt = base .. ',indent-heuristic,inline:none', sides = true },
  { name = 'github-char', diffopt = base .. ',indent-heuristic,inline:char', sides = true },
  { name = 'github-linematch', diffopt = base .. ',indent-heuristic,inline:word,linematch:60', sides = true },
  { name = 'github-histogram', diffopt = base .. ',indent-heuristic,inline:word,algorithm:histogram', sides = true },
  { name = 'native', diffopt = base .. ',indent-heuristic,inline:word' },
}
local by_name = {}
for i, p in ipairs(presets) do
  p.index = i
  by_name[p.name] = p
end

local current = by_name['github-simple']

local function set_hl()
  vim.api.nvim_set_hl(0, 'DiffPresetOld', { bg = '#402120' })
  vim.api.nvim_set_hl(0, 'DiffPresetOldText', { bg = '#6a2f2b' })
  vim.api.nvim_set_hl(0, 'DiffPresetNew', { bg = '#34381b' })
  vim.api.nvim_set_hl(0, 'DiffPresetNewText', { bg = '#525c22' })
  vim.api.nvim_set_hl(0, 'DiffPresetFiller', { fg = '#45403d' })
end

local function side_hl(old)
  local line = old and 'DiffPresetOld' or 'DiffPresetNew'
  local text = line .. 'Text'
  return ('DiffAdd:%s,DiffChange:%s,DiffText:%s,DiffTextAdd:%s,DiffDelete:DiffPresetFiller'):format(line, line, text, text)
end

-- diffchar.vim only reads 'diffopt' when a tab enters diff mode, so it's reset or started by hand
local function diffchar_call(fn, win)
  local info = vim.fn.getscriptinfo({ name = 'autoload/diffchar.vim' })[1]
  if info and win then
    vim.fn.win_execute(win, ('call <SNR>%d_%s()'):format(info.sid, fn))
  end
end

local function diff_wins()
  local wins = vim.tbl_filter(function(w)
    return vim.wo[w].diff and vim.api.nvim_win_get_config(w).relative == ''
  end, vim.api.nvim_tabpage_list_wins(0))
  table.sort(wins, function(a, b)
    return vim.fn.win_screenpos(a)[2] < vim.fn.win_screenpos(b)[2]
  end)
  return wins
end

local function set_winhl(win, value)
  if vim.wo[win].winhighlight ~= value then
    vim.wo[win].winhighlight = value
  end
  vim.w[win].diff_preset = value ~= '' or nil
end

local function apply_tab()
  local p = current
  local wins = diff_wins()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[w].diff_preset and not vim.tbl_contains(wins, w) then
      set_winhl(w, '')
    end
  end
  -- only a two-way diff has an old and a new side (not the conflict view)
  for i, w in ipairs(wins) do
    set_winhl(w, (p.sides and #wins == 2) and side_hl(i == 1) or '')
  end
  if p.diffchar then
    if vim.t.DiffChar == 0 then
      vim.t.DiffChar = nil
      if not vim.t.DChar and #wins >= 2 then
        -- diffchar reads DiffText through the old winhighlight until a redraw applies the new one
        vim.cmd.redraw()
        diffchar_call('ShowDiffChar', wins[1])
      end
    end
  else
    if vim.t.DChar then
      diffchar_call('ResetDiffChar', vim.t.DChar.wid['1'])
    end
    vim.t.DiffChar = 0
  end
end

local function apply_global()
  vim.g.DiffChar = not current.diffchar and 0 or nil
  vim.o.diffopt = current.diffopt
  vim.opt.fillchars:remove('diff')
  if current.sides then
    vim.opt.fillchars:append('diff:╱')
  end
end

local function choose(p)
  current = p
  apply_global()
  apply_tab()
  vim.notify(('diff preset: %s (%d/%d)'):format(p.name, p.index, #presets), vim.log.levels.INFO)
end

local function cycle()
  choose(presets[current.index % #presets + 1])
end

vim.api.nvim_create_user_command('DiffPreset', function(o)
  if o.args == '' then
    return cycle()
  end
  if not by_name[o.args] then
    return vim.notify('no diff preset ' .. o.args, vim.log.levels.ERROR)
  end
  choose(by_name[o.args])
end, {
  nargs = '?',
  complete = function()
    return vim.tbl_map(function(p)
      return p.name
    end, presets)
  end,
})
vim.keymap.set('n', '<leader>dx', cycle, { desc = 'Cycle diff preset' })

local group = vim.api.nvim_create_augroup('diff_presets', { clear = true })
set_hl()
vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_hl })
-- after VimEnter: diffchar's plugin script edits 'diffopt' when it loads
vim.api.nvim_create_autocmd('VimEnter', { group = group, once = true, callback = apply_global })
vim.api.nvim_create_autocmd({ 'TabEnter', 'WinEnter', 'OptionSet' }, {
  group = group,
  callback = function(ev)
    if ev.event == 'OptionSet' and ev.match ~= 'diff' then
      return
    end
    vim.schedule(apply_tab)
  end,
})
