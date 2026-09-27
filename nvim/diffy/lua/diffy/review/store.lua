-- JSON persistence in `.git/diffy/<branch>/`: one JSON object per file.
local M = {}

--- Per-branch state directory under `gitdir`.
function M.dir(gitdir, branch)
  return gitdir .. '/diffy/' .. branch
end

--- Read `path` as a JSON object. Returns `nil` if the file is missing or
--- fails to parse (e.g. a partial write), so callers just start fresh.
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

--- Write `data` to `path` as one JSON object, creating the parent directory.
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
