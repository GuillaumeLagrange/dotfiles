-- Pure review data model (contract §9.1): Thread/Comment/Anchor shapes,
-- excerpt relocation, rev<->commit-field mapping, placement in the current
-- pair, unified-diff hunk parsing. No vim.api, no subprocess, no session
-- table access beyond plain fields passed in - testable with plain tables.
--
--   Thread  { id, backend, anchor, comments = {}, resolved, outdated }
--   Comment { id, author, body, created_at, state = draft|pending|published|sent }
--   Anchor  { path, side = old|new, start_line, end_line, commit, excerpt }
--
-- `commit` is 'worktree', 'index', or a sha (§9.1/§9.3): the rev shown on
-- `side` when the comment was written. `excerpt` is the array of lines that
-- were anchored, used by `M.relocate` to re-find the anchor after edits.
local M = {}

--- `session.pair`'s rev sentinels ('WORKTREE'/'INDEX'/'HEAD'/sha) -> the
--- lowercase commit-field vocabulary of an Anchor ('worktree'/'index'/sha).
--- `HEAD` resolves to the concrete sha so an Anchor is always sha-stable.
function M.rev_to_commit(rev, head_sha)
  if rev == 'WORKTREE' then
    return 'worktree'
  elseif rev == 'INDEX' then
    return 'index'
  elseif rev == 'HEAD' then
    return head_sha
  end
  return rev
end

--- Which window ('left'/'right') currently shows `anchor`'s side of `pair`,
--- or nil if neither side of the current pair matches it (local backend
--- does no cross-commit tracking, §9.3: a thread only shows in the exact
--- view it was written in).
function M.pair_side(pair, head_sha, anchor)
  if anchor.side == 'old' and M.rev_to_commit(pair.left, head_sha) == anchor.commit then
    return 'left'
  end
  if anchor.side == 'new' and M.rev_to_commit(pair.right, head_sha) == anchor.commit then
    return 'right'
  end
  return nil
end

--- Re-locate `anchor` against `lines` (the current content of its side):
--- search outward from the stored `start_line`, within +/-20 lines, for an
--- exact match of `anchor.excerpt`. On success, updates `start_line`/
--- `end_line` in place and returns true. On failure, leaves `anchor`
--- untouched and returns false - callers treat the thread as detached.
function M.relocate(anchor, lines)
  local excerpt = anchor.excerpt
  local n = #excerpt
  if n == 0 or #lines < n then
    return false
  end
  local function matches(start)
    if start < 1 or start + n - 1 > #lines then
      return false
    end
    for i = 1, n do
      if lines[start + i - 1] ~= excerpt[i] then
        return false
      end
    end
    return true
  end
  if matches(anchor.start_line) then
    anchor.end_line = anchor.start_line + n - 1
    return true
  end
  for d = 1, 20 do
    if matches(anchor.start_line - d) then
      anchor.start_line = anchor.start_line - d
      anchor.end_line = anchor.start_line + n - 1
      return true
    end
    if matches(anchor.start_line + d) then
      anchor.start_line = anchor.start_line + d
      anchor.end_line = anchor.start_line + n - 1
      return true
    end
  end
  return false
end

--- Next unused `t<N>`/`c<N>` id: scans every thread id (for `M.next_thread_id`)
--- or every comment id across every thread (for `M.next_comment_id`).
local function next_id(prefix, ids)
  local max = 0
  for _, id in ipairs(ids) do
    local n = tonumber(id:match('^' .. prefix .. '(%d+)$'))
    if n and n > max then
      max = n
    end
  end
  return prefix .. tostring(max + 1)
end

function M.next_thread_id(threads)
  local ids = {}
  for _, t in ipairs(threads) do
    table.insert(ids, t.id)
  end
  return next_id('t', ids)
end

function M.next_comment_id(threads)
  local ids = {}
  for _, t in ipairs(threads) do
    for _, c in ipairs(t.comments) do
      table.insert(ids, c.id)
    end
  end
  return next_id('c', ids)
end

--- One-line `virt_lines` summary (§9.2): `💬 <first author>[ +N][ ·
--- resolved]`, N being the number of comments beyond the first.
function M.summary_text(thread)
  local first = thread.comments[1]
  local text = '\240\159\146\172 ' .. (first and first.author or 'unknown')
  local extra = #thread.comments - 1
  if extra > 0 then
    text = text .. (' +%d'):format(extra)
  end
  if thread.resolved then
    text = text .. ' \194\183 resolved'
  end
  return text
end

--- Parse one file's unified diff (`git diff -U*`) into hunks:
--- `{ old_start, old_count, new_start, new_count, lines (incl. @@ header) }[]`.
function M.parse_hunks(diff_text)
  local hunks = {}
  local cur
  for _, line in ipairs(vim.split(diff_text or '', '\n', { plain = true })) do
    local os_, oc, ns_, nc = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if os_ then
      cur = {
        old_start = tonumber(os_),
        old_count = (oc ~= '' and tonumber(oc)) or 1,
        new_start = tonumber(ns_),
        new_count = (nc ~= '' and tonumber(nc)) or 1,
        lines = { line },
      }
      table.insert(hunks, cur)
    elseif cur then
      table.insert(cur.lines, line)
    end
  end
  return hunks
end

--- The hunk (from `M.parse_hunks`) whose `side` ('old'/'new') range
--- overlaps `[start_line, end_line]`, or nil.
function M.find_hunk(hunks, side, start_line, end_line)
  for _, h in ipairs(hunks) do
    local s = (side == 'old') and h.old_start or h.new_start
    local c = (side == 'old') and h.old_count or h.new_count
    if start_line <= s + c - 1 and end_line >= s then
      return h
    end
  end
  return nil
end

return M
