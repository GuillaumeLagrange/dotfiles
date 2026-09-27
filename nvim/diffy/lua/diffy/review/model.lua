-- Pure review data model: Thread/Comment/Anchor shapes, excerpt relocation,
-- rev<->commit-field mapping, placement in the current pair, unified-diff
-- hunk parsing and line tracking. No vim.api or subprocesses, so it's
-- testable with plain tables.
--
--   Thread  { id, backend, anchor, comments = {}, resolved, outdated }
--   Comment { id, author, body, created_at, state = draft|pending|published|sent }
--   Anchor  { path, side = old|new, start_line, end_line, commit, excerpt }
--
-- `commit` is 'worktree', 'index', or a sha: the rev shown on
-- `side` when the comment was written. `excerpt` is the array of lines that
-- were anchored, used by `M.relocate` to re-find the anchor after edits.
local M = {}

--- `session.pair`'s rev sentinels ('WORKTREE'/'INDEX'/'HEAD'/sha) -> an
--- Anchor's `commit` value ('worktree'/'index'/sha). `HEAD` resolves to the
--- concrete sha so an Anchor stays valid after new commits.
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
--- or nil. The local backend does no cross-commit tracking: a thread only
--- shows in the exact view it was written in.
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

--- Next unused `<prefix><N>` id among `ids`.
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

--- One-line `virt_lines` summary: `💬 <first author>[ +N][ · resolved]`,
--- N being the number of comments beyond the first.
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

--- Seconds since the epoch of a comment's `created_at`: `os.time()` for
--- local drafts, an ISO 8601 UTC string from GitHub. nil if unparseable.
function M.epoch(t)
  if type(t) == 'number' then
    return t
  end
  local y, mo, d, h, mi, s = tostring(t or ''):match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then
    return nil
  end
  local now = os.time()
  -- os.time reads a table as local time: add the local UTC offset back
  local offset = os.difftime(now, os.time(os.date('!*t', now)))
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) + offset
end

--- When a thread was started (its first comment), for ordering; 0 if unknown.
function M.started(thread)
  local first = thread.comments[1]
  return first and M.epoch(first.created_at) or 0
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

-- ---------------------------------------------------------------------
-- GitHub backend line-tracking/placement helpers. `review/github.lua`
-- supplies the diff text; these only interpret it.

--- Split a multi-file unified diff (`git diff [-M] X Y`, any context width,
--- incl. `-U0`) into one record per file: `{ old_path, new_path, hunks }[]`
--- (`hunks` via `M.parse_hunks`). A rename's `diff --git a/old b/new`
--- header carries both names; every other file has `old_path == new_path`.
function M.parse_diff_files(diff_text)
  local files = {}
  local cur_lines
  for _, line in ipairs(vim.split(diff_text or '', '\n', { plain = true })) do
    local a, b = line:match('^diff %-%-git a/(.-) b/(.*)$')
    if a then
      cur_lines = {}
      table.insert(files, { old_path = a, new_path = b, lines = cur_lines })
    elseif cur_lines then
      table.insert(cur_lines, line)
    end
  end
  for _, f in ipairs(files) do
    f.hunks = M.parse_hunks(table.concat(f.lines, '\n'))
    f.lines = nil
  end
  return files
end

--- The hunks for `old_path` in `files` (from `M.parse_diff_files`), and the
--- path it maps to on the other side (renamed, or unchanged). A file absent
--- from the diff is unchanged: returns `{}` and `old_path` itself.
function M.diff_file_hunks(files, old_path)
  for _, f in ipairs(files) do
    if f.old_path == old_path then
      return f.new_path, f.hunks
    end
  end
  return old_path, {}
end

--- Map one line from the diff's old side to its new side, `nil` if `line`
--- falls inside a changed hunk (unmappable). `hunks` sorted ascending by
--- `old_start` (git's own diff order). A zero-count hunk (`@@ -N,0 …@@`,
--- pure insertion after old line N) doesn't cover line `N` itself - only
--- lines strictly after it get this hunk's offset.
function M.map_line(hunks, line)
  local offset = 0
  for _, h in ipairs(hunks) do
    local old_end = h.old_start + h.old_count - 1
    local before_cutoff = h.old_count == 0 and h.old_start or (h.old_start - 1)
    if line <= before_cutoff then
      return line + offset
    elseif h.old_count > 0 and line <= old_end then
      return nil
    else
      offset = offset + (h.new_count - h.old_count)
    end
  end
  return line + offset
end

--- Map a range `[start_line, end_line]` the same way: both endpoints must
--- map (lines inside the range may still have changed).
function M.map_range(hunks, start_line, end_line)
  local s = M.map_line(hunks, start_line)
  local e = M.map_line(hunks, end_line)
  if not s or not e then
    return nil
  end
  return s, e
end

--- Whether `[start_line, end_line]` on `side` ('old'/'new') is a changed
--- line or within 3 context lines of one, i.e. commentable on GitHub.
--- `hunks` must come from a `-U0` diff of `merge-base...C`: this function
--- adds the ±3 window itself, so a wider diff would double-count context.
--- `nil` `side` (file-level comment) is always valid.
function M.anchor_valid(hunks, side, start_line, end_line)
  if not side then
    return true
  end
  for _, h in ipairs(hunks) do
    local s = (side == 'old') and h.old_start or h.new_start
    local c = (side == 'old') and h.old_count or h.new_count
    local lo, hi = s - 3, s + math.max(c, 1) - 1 + 3
    if start_line <= hi and end_line >= lo then
      return true
    end
  end
  return false
end

--- GitHub's `position` for `addPullRequestReviewComment`: the 1-based index
--- of the diff line for `new_line` below the file's first `@@` header
--- (`diff_lines` is one file's section of a unified diff; later `@@`
--- headers count as lines too). `nil` if `new_line` isn't on the diff's
--- new side.
function M.diff_position(diff_lines, new_line)
  local pos, nl = nil, nil
  for _, line in ipairs(diff_lines) do
    local new_start = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if new_start then
      pos = pos and (pos + 1) or 0
      nl = tonumber(new_start) - 1
    elseif pos then
      pos = pos + 1
      if line:sub(1, 1) ~= '-' then
        nl = nl + 1
        if nl == new_line then
          return pos
        end
      end
    end
  end
  return nil
end

return M
