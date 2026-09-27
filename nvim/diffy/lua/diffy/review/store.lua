-- JSON persistence in `.git/diffy/` (contract §9.3). Generic enough for any
-- backend's state file (local backend's `local.json` today, a github
-- backend's `pr-<n>.json` later): a single JSON object per file.
local M = {}

--- `.git/diffy/<branch>` (the per-branch state directory under `gitdir`).
function M.dir(gitdir, branch)
  return gitdir .. '/diffy/' .. branch
end

--- Read `path` as a JSON object. Returns `nil` if the file doesn't exist or
--- fails to parse (corrupt/partial write) rather than erroring, so callers
--- can treat "no state yet" and "unreadable state" the same way (start
--- fresh) without special-casing either.
function M.load(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if not ok then
    return nil
  end
  return data
end

--- Write `data` (a plain table) to `path` as one JSON object, creating the
--- parent directory if needed.
function M.save(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

--- Remove `path` if present (`:Diffy review clear`).
function M.delete(path)
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

return M
