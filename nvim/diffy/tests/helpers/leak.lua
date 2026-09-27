-- Leak check (contract §1, §11.1). Use in every UI test file:
--
--   local snapshot
--   T = MiniTest.new_set({
--     hooks = {
--       pre_case = function()
--         child.restart({ '-u', 'tests/minimal_init.lua' })
--         snapshot = leak.snapshot(child)
--       end,
--       post_case = function() leak.check(child, snapshot) end,
--     },
--   })
--
-- Closes any session still open (so a test that forgot `:Diffy close`
-- doesn't mask a real leak), then fails the case (via `error`) if any
-- diffy augroup, `diffy://` buffer, buffer-local keymap tagged `diffy: `,
-- extmark in a `diffy/...` namespace, or extra tab/window/window-option
-- change, or listed [No Name]/fugitive buffer remains.
local M = {}

--- Window count/options and tab count before a test's session(s) open, to
--- diff against after teardown (per-window options on windows outside the
--- session tab must never change).
function M.snapshot(child)
  return child.lua([[
    local wins = vim.api.nvim_list_wins()
    local opts = {}
    for _, w in ipairs(wins) do
      opts[tostring(w)] = {
        diff = vim.wo[w].diff,
        scrollbind = vim.wo[w].scrollbind,
        cursorbind = vim.wo[w].cursorbind,
        wrap = vim.wo[w].wrap,
      }
    end
    local listed = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].buflisted then
        listed[tostring(b)] = true
      end
    end
    return { tabs = #vim.api.nvim_list_tabpages(), wins = wins, opts = opts, listed = listed }
  ]])
end

--- Fails the current case (raises) if diffy state remains. `snapshot` (from
--- `M.snapshot`, taken before the test opened anything) is optional; without
--- it the tab/window/option checks are skipped.
function M.check(child, snapshot)
  if not child.is_running() then
    return
  end

  -- close any session still open, so a forgotten `:Diffy close` doesn't
  -- hide a genuine leak underneath it
  child.lua([[
    local session = require('diffy.session')
    for _, s in pairs(session.sessions) do
      session.teardown(s)
    end
  ]])

  local bad = child.lua([[
    local bad = {}

    for _, name in ipairs(vim.fn.getcompletion('', 'augroup')) do
      if name:match('^diffy_session_') then
        table.insert(bad, 'augroup: ' .. name)
      end
    end

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name:find('diffy://', 1, true) then
          table.insert(bad, 'buffer: ' .. name)
        end
        for _, mode in ipairs({ 'n', 'v', 'x', 'i' }) do
          for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if map.desc and map.desc:find('^diffy: ') then
              table.insert(bad, ('keymap: %s %s (buf %d)'):format(mode, map.lhs, buf))
            end
          end
        end
        for ns_name, ns_id in pairs(vim.api.nvim_get_namespaces()) do
          if ns_name:match('^diffy/') then
            local marks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, {})
            if #marks > 0 then
              table.insert(bad, ('extmark: %d in %s (buf %d)'):format(#marks, ns_name, buf))
            end
          end
        end
      end
    end

    return bad
  ]])

  local after = child.lua([[
    return { tabs = #vim.api.nvim_list_tabpages(), wins = vim.api.nvim_list_wins() }
  ]])

  if snapshot then
    if after.tabs ~= snapshot.tabs then
      table.insert(bad, ('tabs: %d -> %d'):format(snapshot.tabs, after.tabs))
    end
    -- buffers the user never opened must not show up in their buffer list
    local stray = child.lua([[
      local out = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if vim.bo[b].buflisted and ((name == '' and vim.bo[b].buftype == '') or name:find('^fugitive://')) then
          out[#out + 1] = tostring(b) .. ' ' .. (name == '' and '[No Name]' or name)
        end
      end
      return out
    ]])
    for _, entry in ipairs(stray) do
      if not snapshot.listed[entry:match('^%d+')] then
        table.insert(bad, 'listed buffer: ' .. entry)
      end
    end
    if #after.wins ~= #snapshot.wins then
      table.insert(bad, ('windows: %d -> %d'):format(#snapshot.wins, #after.wins))
    end
    for _, win in ipairs(snapshot.wins) do
      local still = child.lua_get(('vim.api.nvim_win_is_valid(%d)'):format(win))
      if not still then
        table.insert(bad, ('window %d no longer valid'):format(win))
      else
        local before_opts = snapshot.opts[tostring(win)]
        local now_opts = child.lua(([[
          local w = %d
          return { diff = vim.wo[w].diff, scrollbind = vim.wo[w].scrollbind,
            cursorbind = vim.wo[w].cursorbind, wrap = vim.wo[w].wrap }
        ]]):format(win))
        for key, val in pairs(before_opts) do
          if now_opts[key] ~= val then
            table.insert(bad, ('window %d option %s: %s -> %s'):format(win, key, tostring(val), tostring(now_opts[key])))
          end
        end
      end
    end
  end

  if #bad > 0 then
    error('diffy state leaked:\n  ' .. table.concat(bad, '\n  '))
  end
end

return M
