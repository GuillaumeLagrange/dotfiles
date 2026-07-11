--- Backend-neutral renderer: place extmarks for a set of hunks in a buffer.
--- Added lines are real buffer text → highlighted in place. Removed lines are
--- gone from the buffer → drawn as virtual lines. Knows nothing about the agent.

local M = {}

M.ns = vim.api.nvim_create_namespace('agent_diff')

---@class AgentDiff.Style
---@field add string       highlight group for added/new-side lines
---@field delete string    highlight group for removed old-side virtual lines
---@field sign? string     optional gutter sign highlight group (pending only)

---@type table<"applied"|"pending", AgentDiff.Style>
local STYLES = {
  applied = { add = 'AgentDiffAdd', delete = 'AgentDiffDelete' },
  pending = { add = 'AgentDiffPendingAdd', delete = 'AgentDiffPendingDelete', sign = 'AgentDiffSign' },
}

--- pcall-wrapped extmark set (mirrors sidekick util.set_extmark): a bad row or
--- an unknown opt on some build degrades gracefully instead of aborting a render.
---@return integer? id
local function set(buf, row, col, opts)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, col, opts)
  return ok and id or nil
end

--- Render hunks into `buf`. Returns the placed extmark ids so the caller can
--- track them per edit (for navigation / selective clearing).
---@param buf integer
---@param hunks AgentDiff.Hunk[]
---@param kind "applied"|"pending"
---@return integer[] extmark_ids
function M.hunks(buf, hunks, kind)
  local style = STYLES[kind] or STYLES.applied
  local line_count = vim.api.nvim_buf_line_count(buf)
  local ids = {} ---@type integer[]

  -- Deleted lines from several hunks can land on the same anchor (histogram +
  -- linematch fragments a whole-file replace into interleaved add/delete
  -- hunks). Accumulate them per anchor and emit one ordered virt_lines block,
  -- so the phantom lines never stack out of order across separate extmarks.
  local del_order = {} ---@type string[]
  local dels = {} ---@type table<string, {row: integer, above: boolean, virt: table[]}>

  for _, h in ipairs(hunks) do
    -- New-side: highlight the real buffer rows [b_start, b_start + b_count).
    if h.b_count > 0 then
      -- End on the last added row at its end-of-line, not at column 0 of the row
      -- after it — an end at (next_row, 0) with hl_eol paints a stray cell on the
      -- following, unchanged line.
      local last_row = math.min(h.b_start + h.b_count, line_count) - 1
      local last_col = #(vim.api.nvim_buf_get_lines(buf, last_row, last_row + 1, false)[1] or '')
      local id = set(buf, h.b_start, 0, {
        hl_group = style.add,
        hl_eol = true,
        end_row = last_row,
        end_col = last_col,
        priority = 1000,
        invalidate = true,
        undo_restore = false,
        sign_text = style.sign and '▎' or nil,
        sign_hl_group = style.sign,
      })
      if id then
        ids[#ids + 1] = id
      end
    end

    if #h.a_lines > 0 then
      local row, above
      if h.b_count > 0 or h.b_start < line_count then
        -- A change, or a deletion with surviving text after it: show above.
        row, above = h.b_start, true
      else
        -- A deletion at end of file: anchor on the last line and render below.
        row, above = math.max(line_count - 1, 0), false
      end

      local key = row .. ':' .. tostring(above)
      local group = dels[key]
      if not group then
        group = { row = row, above = above, virt = {} }
        dels[key] = group
        del_order[#del_order + 1] = key
      end
      for _, l in ipairs(h.a_lines) do
        group.virt[#group.virt + 1] = { { l ~= '' and l or ' ', style.delete } }
      end
    end
  end

  for _, key in ipairs(del_order) do
    local group = dels[key]
    local id = set(buf, group.row, 0, {
      virt_lines = group.virt,
      virt_lines_above = group.above,
      hl_mode = 'combine',
      priority = 1000,
      invalidate = true,
      undo_restore = false,
    })
    if id then
      ids[#ids + 1] = id
    end
  end

  return ids
end

--- Clear every agent-diff extmark in a buffer.
---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

--- Delete only the given extmark ids, leaving other agent-diff marks in the same
--- buffer intact. Used to drop one edit without disturbing others sharing the buffer.
---@param buf integer
---@param ids integer[]
function M.clear_ids(buf, ids)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, id in ipairs(ids) do
    pcall(vim.api.nvim_buf_del_extmark, buf, M.ns, id)
  end
end

--- Current [start_row, end_row] (0-indexed) of a still-live extmark, or nil if
--- it was invalidated / deleted. Used to re-derive a jump target at navigate
--- time rather than trusting a cached row that user edits may have shifted.
---@param buf integer
---@param id integer
---@return integer? start_row
---@return integer? end_row
function M.mark_range(buf, id)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, M.ns, id, { details = true })
  if not ok or not pos or not pos[1] then
    return nil
  end
  local details = pos[3]
  if details and details.invalid then
    return nil
  end
  return pos[1], details and details.end_row or pos[1]
end

return M
