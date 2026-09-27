-- Fluent fixture-repo builder (contract §11.1). Runs git synchronously (this
-- is test setup, not the plugin's own async path) with pinned author/
-- committer identity and dates so shas are stable across runs.
--
--   local r = Repo.new()
--     :commit('base', { ['f.txt'] = lines(100), ['h.txt'] = lines(40, 'h') })
--     :branch('feat'):commit('C1', { ['f.txt'] = edit(10, 'C1') })
--     :checkout('main'):commit('M1', { ['f.txt'] = edit(90, 'M') })
--     :checkout('feat'):merge('main'):mv('h.txt', 'i.txt'):commit('C3')
--   r.sha.C1, r.dir
--
-- A file's value in `:commit`'s table is either full content (a string, or
-- an array of lines - see `lines()`) or an editing function taking the
-- file's current lines and returning the new ones (see `edit()`/`insert()`).
local M = {}

local BASE_ENV = {
  GIT_AUTHOR_NAME = 'diffy',
  GIT_AUTHOR_EMAIL = 'diffy@example.com',
  GIT_COMMITTER_NAME = 'diffy',
  GIT_COMMITTER_EMAIL = 'diffy@example.com',
  GIT_CONFIG_GLOBAL = '/dev/null',
  GIT_CONFIG_NOSYSTEM = '1',
}

local function git(dir, args, env)
  local cmd = { 'git' }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = dir, text = true, env = vim.tbl_extend('force', BASE_ENV, env or {}) }):wait()
  if res.code ~= 0 then
    error(('repo.lua: `git %s` failed (%d)\n%s'):format(table.concat(args, ' '), res.code, res.stderr or ''), 3)
  end
  return vim.trim(res.stdout or '')
end

--- `n` lines, each `prefix .. i` (default prefix `''`, so `'1'`, `'2'`, …).
function M.lines(n, prefix)
  prefix = prefix or ''
  local out = {}
  for i = 1, n do
    out[i] = prefix .. i
  end
  return out
end

--- Replace one or more lines of a file's current content, 1-based:
--- `edit(10, 'new text')` or `edit(10, 'a', 20, 'b')` for several at once.
function M.edit(...)
  local changes = { ... }
  return function(current)
    local out = vim.deepcopy(current)
    for i = 1, #changes, 2 do
      out[changes[i]] = changes[i + 1]
    end
    return out
  end
end

--- Insert a line before position `at` (1-based), shifting the rest down by
--- one - for exercising line-number tracking across a shifting commit.
function M.insert(at, text)
  return function(current)
    local out = vim.deepcopy(current)
    table.insert(out, at, text)
    return out
  end
end

local Repo = {}
Repo.__index = Repo

local function commit_date(repo)
  repo._n = repo._n + 1
  return ('@%d +0000'):format(1700000000 + repo._n * 60)
end

function Repo:_write(path, content)
  local full = self.dir .. '/' .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ':h'), 'p')
  local new_content
  if type(content) == 'function' then
    local existing = vim.fn.filereadable(full) == 1 and vim.fn.readfile(full) or {}
    new_content = content(existing)
  elseif type(content) == 'table' then
    new_content = content
  elseif type(content) == 'string' then
    new_content = vim.split(content, '\n', { plain = true })
  else
    error('repo.lua: unsupported file content type ' .. type(content), 2)
  end
  vim.fn.writefile(new_content, full)
end

--- Write/edit `files` (path -> content, see module docs), stage everything
--- and commit. Records the resulting sha as `self.sha[label]`.
function Repo:commit(label, files)
  for path, content in pairs(files or {}) do
    self:_write(path, content)
  end
  local date = commit_date(self)
  git(self.dir, { 'add', '-A' })
  git(self.dir, { 'commit', '--quiet', '--allow-empty', '-m', label }, {
    GIT_AUTHOR_DATE = date,
    GIT_COMMITTER_DATE = date,
  })
  self.sha[label] = git(self.dir, { 'rev-parse', 'HEAD' })
  return self
end

--- Create and switch to a new branch at HEAD.
function Repo:branch(name)
  git(self.dir, { 'checkout', '--quiet', '-b', name })
  return self
end

--- Switch to an existing branch.
function Repo:checkout(name)
  git(self.dir, { 'checkout', '--quiet', name })
  return self
end

--- Merge `name` into the current branch, always as a real merge commit
--- (`--no-ff`). Records the merge's sha as `self.sha[label]` if given.
function Repo:merge(name, label)
  local date = commit_date(self)
  git(self.dir, { 'merge', '--quiet', '--no-ff', '--no-edit', name }, {
    GIT_AUTHOR_DATE = date,
    GIT_COMMITTER_DATE = date,
  })
  if label then
    self.sha[label] = git(self.dir, { 'rev-parse', 'HEAD' })
  end
  return self
end

--- Attempt to merge `name` into the current branch, tolerating a conflict
--- (§8's conflict-view scenarios need a real unresolved merge in progress -
--- unlike `:merge`, a nonzero exit here is the expected outcome, not a
--- fixture-builder error).
function Repo:merge_conflict(name)
  vim.system({ 'git', 'merge', '--no-ff', '--no-edit', name }, { cwd = self.dir, text = true, env = BASE_ENV }):wait()
  return self
end

--- Attempt to rebase the current branch onto `name`, tolerating a conflict
--- (§8's rebase-conflict scenario).
function Repo:rebase_conflict(name)
  vim.system({ 'git', 'rebase', name }, { cwd = self.dir, text = true, env = BASE_ENV }):wait()
  return self
end

--- Rename a tracked path (staged; not committed until `:commit`).
function Repo:mv(old, new)
  git(self.dir, { 'mv', old, new })
  return self
end

--- Delete a tracked path (staged; not committed until `:commit`).
function Repo:rm(path)
  git(self.dir, { 'rm', '--quiet', path })
  return self
end

--- Remove the fixture's temp directory from disk.
function Repo:destroy()
  vim.fn.delete(self.dir, 'rf')
end

--- New empty repo (branch `main`), in a fresh temp directory.
function M.new()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  git(dir, { 'init', '--quiet', '-b', 'main' })
  return setmetatable({ dir = dir, sha = {}, _n = 0 }, Repo)
end

--- The shared "standard" history (§11.1): edits, a re-edit of the same
--- line, a merge from main, a rename, a delete, an add, and a line-shifting
--- commit. Ends on branch `feat`.
function M.standard()
  local r = M.new()
  r:commit('Base', {
    ['f.txt'] = M.lines(100),
    ['h.txt'] = M.lines(40, 'h'),
    ['d.txt'] = M.lines(10, 'd'),
  })
  r:branch('feat'):commit('C1', { ['f.txt'] = M.edit(10, 'feat: line 10') })
  r:checkout('main')
    :commit('M1', { ['f.txt'] = M.edit(90, 'main: line 90 v1') })
    :commit('M2', { ['f.txt'] = M.edit(90, 'main: line 90 v2') })
  r:checkout('feat')
    :merge('main', 'Merge')
    :mv('h.txt', 'i.txt')
    :commit('Rename')
    :rm('d.txt')
    :commit('Delete')
    :commit('Add', { ['new.txt'] = M.lines(20, 'n') })
    :commit('Shift', { ['f.txt'] = M.insert(1, 'shifted: new first line') })
  return r
end

return M
