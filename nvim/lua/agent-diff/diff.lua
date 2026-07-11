--- Backend-neutral diff: turn a before/after file pair into line hunks.
--- Knows nothing about the agent or about extmarks.

local M = {}

---@class AgentDiff.Hunk
---@field kind "add"|"delete"|"change"
---@field b_start integer   0-indexed buffer row the hunk anchors at
---@field b_count integer   number of new-side lines (0 for a pure deletion)
---@field a_lines string[]  removed old-side lines (empty for a pure addition)

---@type vim.diff.Opts
local DIFF_OPTS = {
  result_type = 'indices',
  algorithm = 'histogram',
  linematch = true,
  ctxlen = 0,
}

--- vim.diff wants a single string with a trailing newline per non-empty side.
---@param lines string[]
---@return string
local function join(lines)
  if #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n') .. '\n'
end

--- Diff two files given as line arrays. `old_file` nil means "everything is new"
--- (used for Write, where we have no pre-write content) → a single add hunk.
---@param old_file string[]|nil
---@param new_file string[]
---@return AgentDiff.Hunk[]
function M.hunks(old_file, new_file)
  if old_file == nil then
    if #new_file == 0 then
      return {}
    end
    return { { kind = 'add', b_start = 0, b_count = #new_file, a_lines = {} } }
  end

  local raw = vim.diff(join(old_file), join(new_file), DIFF_OPTS) --[[@as integer[][] ]]
  local hunks = {} ---@type AgentDiff.Hunk[]
  for _, hk in ipairs(raw or {}) do
    local sa, ca, sb, cb = hk[1], hk[2], hk[3], hk[4]
    -- vim.diff indices are 1-based. For a change/add (cb > 0), sb is the first
    -- new-side line, so the 0-indexed row is sb - 1. For a pure deletion (cb ==
    -- 0), sb is the count of surviving new-side lines that precede the gap, i.e.
    -- the deletion sits between rows sb-1 and sb — sb *is* the 0-indexed row to
    -- anchor above.
    local b_start = cb > 0 and (sb - 1) or sb
    hunks[#hunks + 1] = {
      kind = (ca > 0 and cb > 0) and 'change' or (ca > 0 and 'delete' or 'add'),
      b_start = math.max(0, b_start),
      b_count = cb,
      a_lines = ca > 0 and vim.list_slice(old_file, sa, sa + ca - 1) or {},
    }
  end
  return hunks
end

return M
