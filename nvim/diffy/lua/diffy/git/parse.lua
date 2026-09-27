-- Parsers for git's `-z` output formats. Pure functions: no subprocess, no
-- state. Callers (git/repo.lua, panels/*) own choosing the right git
-- invocation; this module only turns its stdout into Lua tables.
local M = {}

local function split_z(stdout)
  return vim.split(stdout or '', '\0', { plain = true })
end

--- `git log -z --date-order --pretty=format:'%H%x1f%P%x1f%s'` (any range).
--- `-z` separates commit records with NUL (no separator before the first or
--- after the last record); `--date-order` guarantees a merge is listed
--- before both its parents.
--- @return { sha: string, parents: string[], subject: string, merge: boolean }[]
function M.log(stdout)
  if stdout == nil or stdout == '' then
    return {}
  end
  local records = vim.split(stdout, '\0', { plain = true })
  local out = {}
  for _, rec in ipairs(records) do
    if rec ~= '' then
      local fields = vim.split(rec, '\31', { plain = true })
      local sha, parents_str, subject = fields[1], fields[2] or '', fields[3] or ''
      local parents = parents_str == '' and {} or vim.split(parents_str, ' ', { plain = true })
      table.insert(out, { sha = sha, parents = parents, subject = subject, merge = #parents > 1 })
    end
  end
  return out
end

--- `git diff -z -M --name-status <revs>`. Renamed/copied entries carry an
--- extra `old_path` field and a numeric `score` (e.g. `R100` -> 100).
--- @return { status: string, path: string, old_path?: string, score?: number }[]
function M.name_status(stdout)
  local tokens = split_z(stdout)
  local out = {}
  local i = 1
  while i <= #tokens and tokens[i] ~= '' do
    local status = tokens[i]
    local letter = status:sub(1, 1)
    if letter == 'R' or letter == 'C' then
      table.insert(out, {
        status = letter,
        old_path = tokens[i + 1],
        path = tokens[i + 2],
        score = tonumber(status:sub(2)),
      })
      i = i + 3
    else
      table.insert(out, { status = letter, path = tokens[i + 1] })
      i = i + 2
    end
  end
  return out
end

--- `git diff -z -M --numstat <revs>`. `added`/`removed` are `nil` for
--- binary files (git prints `-`). Renamed/copied entries carry `old_path`.
--- @return { added: number|nil, removed: number|nil, path: string, old_path?: string }[]
function M.numstat(stdout)
  local tokens = split_z(stdout)
  local out = {}
  local i = 1
  while i <= #tokens and tokens[i] ~= '' do
    local added, removed, rest = tokens[i]:match('^(%S+)\t(%S+)\t(.*)$')
    if rest == '' then
      table.insert(out, {
        added = tonumber(added),
        removed = tonumber(removed),
        old_path = tokens[i + 1],
        path = tokens[i + 2],
      })
      i = i + 3
    else
      table.insert(out, { added = tonumber(added), removed = tonumber(removed), path = rest })
      i = i + 1
    end
  end
  return out
end

--- `git status --porcelain=v2 -z [--ignored]`. One entry per record:
--- ordinary (`kind='ordinary'`, `x`/`y` are the index/worktree status
--- letters), rename/copy (`kind='rename'`, `old_path` set, `score` numeric),
--- unmerged (`kind='unmerged'`), untracked/ignored (`kind='untracked'`
--- /`'ignored'`, path only).
--- @return table[]
function M.status_v2(stdout)
  local tokens = split_z(stdout)
  local out = {}
  local i = 1
  while i <= #tokens and tokens[i] ~= '' do
    local line = tokens[i]
    local kind = line:sub(1, 1)
    if kind == '1' then
      local x, y, path = line:match('^1 (.)(.) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$')
      table.insert(out, { kind = 'ordinary', x = x, y = y, path = path })
      i = i + 1
    elseif kind == '2' then
      local x, y, score, path = line:match('^2 (.)(.) %S+ %S+ %S+ %S+ %S+ %S+ (%a%d+) (.*)$')
      table.insert(out, {
        kind = 'rename',
        x = x,
        y = y,
        path = path,
        old_path = tokens[i + 1],
        score = tonumber(score:sub(2)),
        copy = score:sub(1, 1) == 'C',
      })
      i = i + 2
    elseif kind == 'u' then
      local x, y, path = line:match('^u (.)(.) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.*)$')
      table.insert(out, { kind = 'unmerged', x = x, y = y, path = path })
      i = i + 1
    elseif kind == '?' then
      table.insert(out, { kind = 'untracked', path = line:sub(3) })
      i = i + 1
    elseif kind == '!' then
      table.insert(out, { kind = 'ignored', path = line:sub(3) })
      i = i + 1
    else
      i = i + 1
    end
  end
  return out
end

--- `git ls-files -u -z` (conflict stages during merge/rebase/cherry-pick).
--- @return table<string, table<number, {mode: string, sha: string}>>
function M.ls_files_unmerged(stdout)
  local lines = split_z(stdout)
  local out = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      local mode, sha, stage, path = line:match('^(%S+) (%S+) (%d)\t(.*)$')
      if path then
        out[path] = out[path] or {}
        out[path][tonumber(stage)] = { mode = mode, sha = sha }
      end
    end
  end
  return out
end

--- `git log --follow -z --name-status --pretty=format:%H -- <path>` (§4
--- `:Diffy file`). Each commit's own `\n`-joined "sha\nfirst-status-token"
--- opens a new record (log's `-z` only separates *commits*, so a NUL
--- token straddles the pretty-format sha and the first name-status line);
--- everything else follows `M.name_status`'s per-line shape.
--- @return { sha: string, status: string, path: string, old_path?: string }[]
function M.log_name_status(stdout)
  local tokens = split_z(stdout)
  local out = {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    if tok == '' then
      i = i + 1
    else
      local sha, status = tok:match('^(.-)\n(.*)$')
      if not sha then
        i = i + 1
      elseif status == '' then
        i = i + 1
      else
        local letter = status:sub(1, 1)
        if letter == 'R' or letter == 'C' then
          table.insert(out, { sha = sha, status = letter, old_path = tokens[i + 1], path = tokens[i + 2] })
          i = i + 3
        else
          table.insert(out, { sha = sha, status = letter, path = tokens[i + 1] })
          i = i + 2
        end
      end
    end
  end
  return out
end

return M
