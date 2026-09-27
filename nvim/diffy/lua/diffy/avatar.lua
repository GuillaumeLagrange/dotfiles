-- GitHub avatars drawn with the kitty graphics protocol, as direct
-- placements at screen cells (kitty, ghostty, wezterm, zellij >= 0.45).
-- Unicode placeholders would scroll with the text, but zellij drops them.
--
-- Avatars are downloaded once per URL, cut round by ImageMagick and cached
-- in stdpath('cache')/diffy/avatars. Without a graphics-capable TUI, curl
-- or ImageMagick, `ready` stays false and callers keep their text layout.
local M = {}

-- above what other plugins pick for their own images
local ID_BASE = 0x00D1F000
local QUERY_ID = ID_BASE

local support -- nil: unknown, else boolean
local waiting = {} -- callbacks waiting for `support`
local images = {} -- url -> { status = 'fetching'|'ready'|'failed', path, id, sent, waiters }
local next_id = ID_BASE + 1
local next_pid = 1
local placed = {} -- owner -> { {id, pid} }

local function send(data)
  vim.api.nvim_ui_send(data)
end

local function magick()
  if vim.fn.executable('magick') == 1 then
    return 'magick'
  elseif vim.fn.executable('convert') == 1 then
    return 'convert'
  end
end

local function has_tty_ui()
  for _, ui in ipairs(vim.api.nvim_list_uis()) do
    if ui.stdout_tty then
      return true
    end
  end
  return false
end

local function settle(value)
  support = value
  local cbs = waiting
  waiting = {}
  for _, cb in ipairs(cbs) do
    cb(value)
  end
end

--- `cb(supported)`, once the terminal answered the graphics query (or
--- didn't within a second). Asked once per process.
function M.detect(cb)
  if support ~= nil then
    return cb(support)
  end
  table.insert(waiting, cb)
  if #waiting > 1 then
    return
  end
  -- tmux would need passthrough, and its panes shift the coordinates
  if require('diffy').config.avatars == false or vim.env.TMUX or not has_tty_ui()
    or vim.fn.executable('curl') == 0 or not magick() then
    return settle(false)
  end
  local group = vim.api.nvim_create_augroup('diffy_avatar', { clear = true })
  local timer = assert(vim.uv.new_timer())
  local function done(value)
    if support ~= nil then
      return
    end
    timer:stop()
    timer:close()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    settle(value)
  end
  vim.api.nvim_create_autocmd('TermResponse', {
    group = group,
    callback = function(ev)
      local seq = ev.data and ev.data.sequence or ''
      if seq:find('\27_Gi=' .. QUERY_ID .. ';', 1, true) then
        done(seq:find(';OK', 1, true) ~= nil)
      elseif seq:match('^\27%[%?[%d;]*c$') then
        -- the DA1 sent after the query came back first: no graphics support
        done(false)
      end
    end,
  })
  timer:start(1000, 0, vim.schedule_wrap(function()
    done(false)
  end))
  send(('\27_Gi=%d,s=1,v=1,a=q,t=d,f=24;AAAA\27\\\27[c'):format(QUERY_ID))
end

local function cache_path(url)
  local dir = vim.fn.stdpath('cache') .. '/diffy/avatars'
  vim.fn.mkdir(dir, 'p')
  return ('%s/%s.png'):format(dir, vim.fn.sha256(url))
end

local function finish(img, ok)
  img.status = ok and 'ready' or 'failed'
  local cbs = img.waiters
  img.waiters = {}
  for _, cb in ipairs(cbs) do
    cb()
  end
end

local function fetch(url, img)
  local src = img.path .. '.src'
  vim.system({ 'curl', '-sfL', '--max-time', '10', '-o', src, url }, {}, function(dl)
    if dl.code ~= 0 then
      os.remove(src)
      return vim.schedule(function()
        finish(img, false)
      end)
    end
    local size, r = 64, 31.5
    vim.system({
      magick(), src, '-resize', ('%dx%d^'):format(size, size), '-gravity', 'center', '-extent', ('%dx%d'):format(size, size),
      '(', '-size', ('%dx%d'):format(size, size), 'xc:black', '-fill', 'white', '-draw', ('circle %s,%s %s,0'):format(r, r, r), ')',
      '-alpha', 'off', '-compose', 'CopyOpacity', '-composite', 'PNG32:' .. img.path,
    }, {}, function(cv)
      os.remove(src)
      vim.schedule(function()
        finish(img, cv.code == 0)
      end)
    end)
  end)
end

--- True when `url`'s avatar can be drawn right now.
function M.ready(url)
  local img = url and images[url]
  return support == true and img ~= nil and img.status == 'ready'
end

--- Make `urls` drawable; `cb()` runs once some are (cached ones right after
--- detection), then again as each download lands. Never runs when images
--- can't be drawn.
function M.request(urls, cb)
  if #urls == 0 then
    return
  end
  M.detect(function(ok)
    if not ok then
      return
    end
    local any = false
    for _, url in ipairs(urls) do
      local img = images[url]
      if not img then
        img = { path = cache_path(url), waiters = {} }
        images[url] = img
        if vim.uv.fs_stat(img.path) then
          img.status = 'ready'
        else
          img.status = 'fetching'
          fetch(url, img)
        end
      end
      if img.status == 'ready' then
        any = true
      elseif img.status == 'fetching' then
        table.insert(img.waiters, function()
          if img.status == 'ready' then
            cb()
          end
        end)
      end
    end
    if any then
      cb()
    end
  end)
end

local function transmit(img)
  local f = io.open(img.path, 'rb')
  if not f then
    img.status = 'failed'
    return false
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  img.id = next_id
  next_id = next_id + 1
  local out = {}
  local chunk = 4096
  for i = 1, #data, chunk do
    local more = i + chunk <= #data and 1 or 0
    local head = i == 1 and ('a=t,f=100,t=d,i=%d,q=2,m=%d'):format(img.id, more) or ('m=%d'):format(more)
    table.insert(out, ('\27_G%s;%s\27\\'):format(head, data:sub(i, i + chunk - 1)))
  end
  send(table.concat(out))
  img.sent = true
  return true
end

--- Draw `items` (`{url, row, col}`, 1-based screen cells, one row tall)
--- for `owner`, replacing whatever `owner` drew before.
function M.place(owner, items)
  local sig = {}
  for _, it in ipairs(items) do
    if M.ready(it.url) then
      table.insert(sig, ('%s@%d,%d'):format(it.url, it.row, it.col))
    end
  end
  sig = table.concat(sig, ' ')
  if placed[owner] and placed[owner].sig == sig then
    return
  end
  M.clear(owner)
  local out, list = {}, { sig = sig }
  for _, it in ipairs(items) do
    local img = images[it.url]
    if M.ready(it.url) and (img.sent or transmit(img)) then
      local pid = next_pid
      next_pid = next_pid + 1
      table.insert(list, { img.id, pid })
      table.insert(out, ('\0277\27[%d;%dH\27_Ga=p,i=%d,p=%d,r=1,C=1,q=2\27\\\0278'):format(it.row, it.col, img.id, pid))
    end
  end
  if #list > 0 then
    placed[owner] = list
    send(table.concat(out))
  end
end

function M.clear(owner)
  local list = placed[owner]
  if not list then
    return
  end
  placed[owner] = nil
  local out = {}
  for _, p in ipairs(list) do
    table.insert(out, ('\27_Ga=d,d=i,i=%d,p=%d,q=2\27\\'):format(p[1], p[2]))
  end
  send(table.concat(out))
end

return M
