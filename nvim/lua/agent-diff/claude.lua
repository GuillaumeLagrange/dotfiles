--- Claude Code adapter: the only file that understands Claude's hook payloads.
--- Translates Edit/Write/MultiEdit tool events into the backend-neutral edit
--- model and hands them to the core. A second backend would be another such
--- adapter against the same core API.

local Core = require('agent-diff.core')

local M = {}

--- True pre-edit file content captured at PreToolUse, keyed by absolute path.
--- PreToolUse fires before PostToolUse for the same tool call, so this gives the
--- exact baseline for the post-write diff without having to guess it back out of
--- the new content.
---@type table<string, string[]>
local snapshot = {}

--- Read a file from disk as a line array, or nil if it can't be read.
---@param path string
---@return string[]?
local function readlines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- Apply a single old→new substitution to a text blob. Honors replace_all;
--- otherwise substitutes only the first occurrence (Claude's Edit semantics).
---@param text string
---@param old_string string
---@param new_string string
---@param all boolean?
---@return string
local function substitute(text, old_string, new_string, all)
  if old_string == '' then
    return text
  end
  if not all then
    local s, e = string.find(text, old_string, 1, true)
    if not s then
      return text
    end
    return text:sub(1, s - 1) .. new_string .. text:sub(e + 1)
  end
  local out, pos = {}, 1
  while true do
    local s, e = string.find(text, old_string, pos, true)
    if not s then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, s - 1)
    out[#out + 1] = new_string
    pos = e + 1
  end
  return table.concat(out)
end

--- Forward-apply the tool input to old content to get the post-edit content.
--- Used for the pre-write preview (no disk read of the result yet) and as the
--- fallback new content.
---@param tool_name string
---@param tool_input table
---@param old_lines string[]
---@return string[]
local function apply_edit(tool_name, tool_input, old_lines)
  local text = table.concat(old_lines, '\n')
  if tool_name == 'Write' then
    text = tool_input.content or ''
  elseif tool_name == 'Edit' then
    text = substitute(text, tool_input.old_string or '', tool_input.new_string or '', tool_input.replace_all)
  elseif tool_name == 'MultiEdit' then
    for _, ed in ipairs(tool_input.edits or {}) do
      text = substitute(text, ed.old_string or '', ed.new_string or '', ed.replace_all)
    end
  end
  return M.split(text)
end

--- Recover pre-edit content by reversing the tool input against the post-write
--- content, for when the PreToolUse snapshot is missing (dropped/failed hook).
--- Best-effort: substitution isn't perfectly invertible when a string recurs, but
--- it beats diffing against nothing, which lights the whole file up as added.
--- Write has no recoverable baseline (it replaces everything) → returns nil.
---@param tool_name string
---@param tool_input table
---@param new_lines string[]
---@return string[]?
local function reverse_apply(tool_name, tool_input, new_lines)
  local text = table.concat(new_lines, '\n')
  if tool_name == 'Edit' then
    text = substitute(text, tool_input.new_string or '', tool_input.old_string or '', tool_input.replace_all)
  elseif tool_name == 'MultiEdit' then
    local edits = tool_input.edits or {}
    for i = #edits, 1, -1 do
      local ed = edits[i]
      text = substitute(text, ed.new_string or '', ed.old_string or '', ed.replace_all)
    end
  else
    return nil
  end
  return M.split(text)
end

--- Split a file blob into lines the way vim.fn.readfile does: a single trailing
--- newline does not produce a spurious empty last line.
---@param text string
---@return string[]
function M.split(text)
  text = text:gsub('\n$', '')
  if text == '' then
    return {}
  end
  return vim.split(text, '\n', { plain = true })
end

--- Handle a PostToolUse event: the write has landed on disk.
---@param payload table
local function on_post(payload)
  local ti = payload.tool_input or {}
  local path = ti.file_path
  if not path then
    return
  end
  local abs = vim.fn.fnamemodify(path, ':p')
  if payload.tool_response and payload.tool_response.success == false then
    -- The edit was rejected. Drop everything tied to this path — including a
    -- pending preview whose file never opened (which lives only as an armed
    -- defer, keyed by path, not by any buffer) — so the never-applied change
    -- can't resurface when the file is later opened.
    snapshot[abs] = nil
    Core.clear_path(abs)
    return
  end

  local new_lines = readlines(path)
  if not new_lines then
    return
  end
  -- Baseline for the diff: the true pre-edit content snapshotted at PreToolUse.
  -- If it's missing (dropped/failed PreToolUse) fall back to forward-applying the
  -- tool input to the current on-disk content, recovered by reversing the write —
  -- diffing against nothing would paint the whole file as newly added.
  local old_lines = snapshot[abs]
  snapshot[abs] = nil
  if not old_lines and payload.tool_name ~= 'Write' then
    old_lines = reverse_apply(payload.tool_name, ti, new_lines)
  end
  Core.apply({
    path = path,
    kind = 'applied',
    old_file = old_lines,
    new_file = new_lines,
  })
end

--- Handle a PreToolUse event: the write hasn't happened yet. Snapshot the true
--- pre-edit content and render the proposed change as a preview.
---@param payload table
local function on_pre(payload)
  local ti = payload.tool_input or {}
  local path = ti.file_path
  if not path then
    return
  end
  local abs = vim.fn.fnamemodify(path, ':p')
  local old_lines = readlines(path) or {}
  snapshot[abs] = old_lines
  local new_lines = apply_edit(payload.tool_name, ti, old_lines)
  Core.preview({
    path = path,
    kind = 'pending',
    old_file = old_lines,
    new_file = new_lines,
  })
end

--- Entry point invoked from the hook via `luaeval`. `b64` is a base64-encoded
--- JSON blob `{event, payload}`. Everything runs deferred: the RPC handler is a
--- fast-event context where the buffer/extmark APIs are restricted.
---@param b64 string
function M.on_event(b64)
  vim.schedule(function()
    local ok, raw = pcall(vim.base64.decode, b64)
    if not ok then
      return
    end
    local decoded, data = pcall(vim.json.decode, raw)
    if not decoded or type(data) ~= 'table' then
      return
    end
    local event = data.event
    local payload = data.payload or {}

    if event == 'PreToolUse' then
      pcall(on_pre, payload)
    elseif event == 'PostToolUse' then
      pcall(on_post, payload)
    elseif event == 'Stop' then
      -- End of an agent turn. Drop only the per-path snapshots (the next
      -- PreToolUse re-captures them); the diff itself stays on screen so it can
      -- be reviewed after the agent stops. Stop fires on every turn — including
      -- ones with no edit — so clearing the diff here would wipe it the moment
      -- the agent answers without touching a file. The user dismisses it (Esc /
      -- :AgentDiffClear) or it auto-clears on their next edit.
      snapshot = {}
    end
  end)
  return 0
end

return M
