local Omp = require('sidekick-omp')

local RUN_DIR = vim.env.OMP_NVIM_BRIDGE_DIR

--- Write a descriptor for `pid`, defaulting the rest of the fields.
---@param info table
local function descriptor(info)
  info = vim.tbl_extend('keep', info, {
    cwd = '/tmp/project',
    socket = RUN_DIR .. '/' .. info.pid .. '.sock',
  })
  vim.fn.writefile({ vim.json.encode(info) }, RUN_DIR .. '/' .. info.pid .. '.json')
  return info
end

--- Listen on a unix socket and collect the newline-delimited JSON sent to it.
---@param path string
---@return table received, function close
local function listener(path)
  local received = {}
  local server = assert(vim.uv.new_pipe(false))
  server:bind(path)
  server:listen(16, function()
    local client = assert(vim.uv.new_pipe(false))
    server:accept(client)
    client:read_start(function(err, chunk)
      if err or not chunk then
        return client:close()
      end
      for line in vim.gsplit(chunk, '\n', { trimempty = true }) do
        table.insert(received, vim.json.decode(line))
      end
    end)
  end)
  return received, function()
    server:close()
  end
end

--- Session state this backend reports for `pid`, if any.
---@param pid integer
local function session_for(pid)
  for _, session in ipairs(Omp.sessions()) do
    if session.omp_pid == pid then
      return session
    end
  end
end

describe('session discovery', function()
  before_each(function()
    vim.fn.delete(RUN_DIR, 'rf')
    vim.fn.mkdir(RUN_DIR, 'p')
  end)

  it('reports a live omp as an attachable session', function()
    descriptor({ pid = vim.uv.os_getpid(), cwd = '/tmp/project' })
    local session = session_for(vim.uv.os_getpid())
    assert.same({
      id = 'omp: ' .. vim.uv.os_getpid(),
      cwd = '/tmp/project',
      tool = 'pi',
      pids = { vim.uv.os_getpid() },
      omp_pid = vim.uv.os_getpid(),
      omp_socket = RUN_DIR .. '/' .. vim.uv.os_getpid() .. '.sock',
    }, session)
  end)

  it('forgets an omp that died without cleaning up', function()
    -- Recycled pids are astronomically unlikely to land on this one.
    descriptor({ pid = 4194303 })
    assert.is_nil(session_for(4194303))
    assert.equals(0, vim.fn.filereadable(RUN_DIR .. '/4194303.json'))
  end)

  it('never runs a session in an nvim terminal: the TUI owns its own pane', function()
    descriptor({ pid = vim.uv.os_getpid() })
    local session = setmetatable(session_for(vim.uv.os_getpid()), Omp)
    session:init()
    assert.is_true(session.external)
  end)
end)

describe('composer ops', function()
  local socket, received, close

  before_each(function()
    vim.fn.delete(RUN_DIR, 'rf')
    vim.fn.mkdir(RUN_DIR, 'p')
    socket = RUN_DIR .. '/probe.sock'
    received, close = listener(socket)
  end)

  after_each(function()
    close()
  end)

  --- Run `fn` on a session bound to the probe socket and wait for `count` messages.
  local function talk(fn, count)
    fn(setmetatable({ omp_socket = socket }, Omp))
    vim.wait(2000, function()
      return #received >= count
    end, 20)
  end

  it('sends text for the composer', function()
    talk(function(session)
      session:send('@src/foo.ts:12\n')
    end, 1)
    assert.same({ { op = 'send', text = '@src/foo.ts:12\n' } }, received)
  end)

  it('submits without a payload', function()
    talk(function(session)
      session:submit()
    end, 1)
    assert.same({ { op = 'submit' } }, received)
  end)

  it('keeps ops in the order they were issued', function()
    talk(function(session)
      session:send('first')
      session:send('second')
      session:submit()
    end, 3)
    assert.same({ 'first', 'second' }, { received[1].text, received[2].text })
    assert.equals('submit', received[3].op)
  end)
end)

describe('handoff command', function()
  it('resumes the conversation when its session file exists', function()
    local file = vim.fn.tempname()
    vim.fn.writefile({ '{}' }, file)
    assert.same({ 'omp', '--resume', 'sess-1' }, Omp.omp_cmd({ session = 'sess-1', file = file }))
    vim.fn.delete(file)
  end)

  it('starts fresh while the session has nothing on disk yet', function()
    -- omp writes the session file on the first turn; `--resume` errors before that.
    assert.same({ 'omp' }, Omp.omp_cmd({ session = 'sess-1', file = vim.fn.tempname() }))
    assert.same({ 'omp' }, Omp.omp_cmd({}))
  end)
end)
