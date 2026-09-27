-- `make test-gh`: per-case real PRs on the sandbox repo.
-- Every call here is synchronous and runs in the test process, not the child.
local M = {}

M.REPO = 'GuillaumeLagrange/diffy-tests'
M.enabled = vim.env.DIFFY_TESTGH == '1'
-- Ready/poll timeout: the real API is much slower than the fake.
M.timeout = M.enabled and 60000 or 5000

local function run(cmd, opts)
  local res = vim.system(cmd, vim.tbl_extend('force', { text = true }, opts or {})):wait()
  assert(res.code == 0, table.concat(cmd, ' ') .. '\n' .. (res.stderr or '') .. (res.stdout or ''))
  return vim.trim(res.stdout or '')
end

function M.graphql(query, variables)
  local out = run({ 'gh', 'api', 'graphql', '--input', '-' }, { stdin = vim.json.encode({ query = query, variables = variables or vim.empty_dict() }) })
  local data = vim.json.decode(out)
  assert(not data.errors, vim.inspect(data.errors))
  return data.data
end

local counter = 0

--- Push `base_sha`/`head_sha` of repo `dir` to fresh uniquely-named
--- branches, open a PR, and check out the head branch locally (also creating
--- the base branch locally, as `:Diffy pr` resolves `baseRefName` locally).
--- Returns `{ number, id, base, head }`; always pair with `M.close`.
function M.open_pr(dir, base_sha, head_sha)
  counter = counter + 1
  local tag = ('%d-%d-%d'):format(os.time(), vim.fn.getpid(), counter)
  local pr = { base = 'test-gh-base-' .. tag, head = 'test-gh-head-' .. tag }
  M.current = pr
  run({ 'git', 'push', '-q', 'origin', base_sha .. ':refs/heads/' .. pr.base, head_sha .. ':refs/heads/' .. pr.head }, { cwd = dir })
  pr.pushed = true
  run({ 'git', 'branch', '-f', pr.base, base_sha }, { cwd = dir })
  run({ 'git', 'checkout', '-q', '-b', pr.head, head_sha }, { cwd = dir })
  local url = run({
    'gh', 'pr', 'create', '--repo', M.REPO, '--base', pr.base, '--head', pr.head,
    '--title', 'diffy make test-gh ' .. tag, '--body', 'Automated `make test-gh` case; closed automatically.',
  })
  pr.number = tonumber(url:match('(%d+)$'))
  local owner, name = M.REPO:match('(.+)/(.+)')
  pr.id = M.graphql('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){id}}}', { o = owner, r = name, n = pr.number }).repository.pullRequest.id
  return pr
end

--- Close the current case's PR and delete its branches. Safe to call when
--- `open_pr` failed half-way; never raises.
function M.close()
  local pr = M.current
  M.current = nil
  if not pr then
    return
  end
  if pr.number then
    vim.system({ 'gh', 'pr', 'close', tostring(pr.number), '--repo', M.REPO }):wait()
  end
  if pr.pushed then
    for _, b in ipairs({ pr.head, pr.base }) do
      vim.system({ 'gh', 'api', '-X', 'DELETE', ('repos/%s/git/refs/heads/%s'):format(M.REPO, b) }):wait()
    end
  end
end

--- GitHub's legacy `position` of new-side line `line` in `merge-base...commit`
--- (1-based index below the first `@@`; later `@@` lines count).
function M.position(dir, merge_base, commit, path, line)
  local diff = run({ 'git', 'diff', '-U3', merge_base, commit, '--', path }, { cwd = dir })
  local pos, new, started = 0, nil, false
  for l in (diff .. '\n'):gmatch('(.-)\n') do
    local s = l:match('^@@ %-%d+,?%d* %+(%d+)')
    if s then
      if started then
        pos = pos + 1
      end
      started, new = true, tonumber(s)
    elseif started then
      pos = pos + 1
      if l:sub(1, 1) ~= '-' then
        if new == line then
          return pos
        end
        new = new + 1
      end
    end
  end
  error(('line %d not in the diff of %s'):format(line, path))
end

return M
