-- §4 (phase 2, logic): `branch` base resolution order - explicit arg, then
-- the PR base (`gh pr view`), then origin's default branch (`gh repo view`).
-- `gh` is faked via a PATH shim (no network); this is pure repo.lua logic,
-- no UI involved.
local repo = require('diffy.git.repo')

local T = MiniTest.new_set()

local function tempdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function fake_gh(behavior)
  local dir = tempdir()
  local script = { '#!/bin/sh' }
  vim.list_extend(script, behavior)
  vim.fn.writefile(script, dir .. '/gh')
  vim.fn.system({ 'chmod', '+x', dir .. '/gh' })
  return dir
end

local function with_path(dir, fn)
  local orig = vim.env.PATH
  vim.env.PATH = dir .. ':' .. orig
  local ok, err = pcall(fn)
  vim.env.PATH = orig
  if not ok then
    error(err, 0)
  end
end

local function resolve(root, explicit)
  local result
  repo.resolve_base(root, explicit, function(ref, err)
    result = { ref = ref, err = err }
  end)
  vim.wait(2000, function()
    return result ~= nil
  end)
  return result
end

T['an explicit base wins over the PR base'] = function()
  local root = tempdir()
  local shim = fake_gh({ 'echo "release"', 'exit 0' })
  local result
  with_path(shim, function()
    result = resolve(root, 'develop')
  end)
  MiniTest.expect.equality(result.ref, 'develop')
end

T['no explicit base falls back to the PR base of the current branch'] = function()
  local root = tempdir()
  local shim = fake_gh({
    'if [ "$1" = "pr" ]; then echo "release"; exit 0; fi',
    'echo "unexpected gh subcommand: $1" >&2; exit 1',
  })
  local result
  with_path(shim, function()
    result = resolve(root, nil)
  end)
  MiniTest.expect.equality(result.ref, 'release')
end

T['no PR falls back to origin default branch'] = function()
  local root = tempdir()
  local shim = fake_gh({
    'if [ "$1" = "pr" ]; then exit 1; fi',
    'if [ "$1" = "repo" ]; then echo "main"; exit 0; fi',
    'exit 1',
  })
  local result
  with_path(shim, function()
    result = resolve(root, nil)
  end)
  MiniTest.expect.equality(result.ref, 'main')
end

T['neither PR nor origin default available surfaces an error'] = function()
  local root = tempdir()
  local shim = fake_gh({ 'exit 1' })
  local result
  with_path(shim, function()
    result = resolve(root, nil)
  end)
  MiniTest.expect.equality(result.ref, nil)
  MiniTest.expect.equality(type(result.err), 'string')
end

return T
