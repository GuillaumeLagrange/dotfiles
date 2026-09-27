-- The log model -> (left rev, right rev) resolution and the real-file rule
-- (contract §3). Pure functions operating on the entry list built by
-- panels/log.lua; no git calls, no buffer/window access.
--
-- An entry is one of:
--   { kind = 'unstaged', rev = 'WORKTREE' }
--   { kind = 'staged',   rev = 'INDEX' }
--   { kind = 'commit', sha, parents, subject, merge, rev = sha }
local M = {}

--- Contiguous range [top_idx, bottom_idx] (both inclusive, top_idx <=
--- bottom_idx, indices into `entries` where index 1 is the newest/topmost
--- row) -> `{ left, right, top, bottom }`. `left`/`right` are revs
--- ('WORKTREE'/'INDEX'/'HEAD'/a sha) suitable for `repo.diff_args`.
--- Per §3's table: right = top entry's rev; left = parent of the bottom
--- entry (its own rev if Unstaged -> index, if Staged -> HEAD, if a commit
--- -> `sha^`). This also covers a range spanning a merge (§3's "A^..B"):
--- `git diff left right` computes the tree diff regardless of what
--- topology lies between the two endpoints.
function M.resolve(entries, top_idx, bottom_idx)
  assert(top_idx <= bottom_idx, 'selection.resolve: top_idx must be <= bottom_idx')
  local top = entries[top_idx]
  local bottom = entries[bottom_idx]

  local right = top.rev
  local left
  if bottom.kind == 'unstaged' then
    left = 'INDEX'
  elseif bottom.kind == 'staged' then
    left = 'HEAD'
  else
    left = bottom.sha .. '^'
  end

  return { left = left, right = right, top = top, bottom = bottom, top_idx = top_idx, bottom_idx = bottom_idx }
end

--- Index of the first/last entry in `entries` that is selectable as a range
--- endpoint (commits that are merges are never selectable, §3). Used for
--- `a` (select all) and to clamp a default selection.
function M.first_selectable(entries)
  for i = 1, #entries do
    if not (entries[i].kind == 'commit' and entries[i].merge) then
      return i
    end
  end
  return nil
end

function M.last_selectable(entries)
  for i = #entries, 1, -1 do
    if not (entries[i].kind == 'commit' and entries[i].merge) then
      return i
    end
  end
  return nil
end

--- Whether the right side of the pair for `path` should be the real
--- worktree file (editable) rather than a read-only blob (§3): the top of
--- the selection is Unstaged, or it is HEAD (or, per §7, the phase-4 full
--- checkout commit passed as `ctx.checkout_sha`) and `path` has no
--- uncommitted changes.
--- @param sel table  result of `M.resolve`
--- @param path string
--- @param ctx { head_sha: string, checkout_sha: string|nil, is_clean: fun(path: string): boolean }
function M.right_is_real(sel, path, ctx)
  if sel.top.kind == 'unstaged' then
    return true
  end
  if sel.top.kind ~= 'commit' then
    return false
  end
  if sel.top.sha == ctx.head_sha or (ctx.checkout_sha and sel.top.sha == ctx.checkout_sha) then
    return ctx.is_clean(path)
  end
  return false
end

return M
