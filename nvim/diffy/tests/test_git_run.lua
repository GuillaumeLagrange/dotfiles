-- §1: "Git does the work" / async git calls surface failures via
-- `vim.notify` (logic layer: real git subprocess, no mocks, runs in this
-- process since no UI is involved).
local run = require('diffy.git.run')

local T = MiniTest.new_set()

local function with_notify_capture(fn)
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(calls, { msg = msg, level = level })
  end
  MiniTest.finally(function()
    vim.notify = orig
  end)
  fn()
  return calls
end

T['a failing git command is surfaced through vim.notify'] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local done = false

  local calls = with_notify_capture(function()
    run.git({ 'not-a-real-subcommand' }, {
      cwd = dir,
      on_exit = function()
        done = true
      end,
    })
    vim.wait(2000, function()
      return done
    end)
  end)

  MiniTest.expect.equality(done, true)
  MiniTest.expect.equality(#calls, 1)
  MiniTest.expect.equality(calls[1].level, vim.log.levels.ERROR)
  MiniTest.expect.equality(calls[1].msg:find('not-a-real-subcommand', 1, true) ~= nil, true)
end

T['a successful git command does not notify'] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local done = false

  local calls = with_notify_capture(function()
    run.git({ '--version' }, {
      cwd = dir,
      on_exit = function()
        done = true
      end,
    })
    vim.wait(2000, function()
      return done
    end)
  end)

  MiniTest.expect.equality(done, true)
  MiniTest.expect.equality(#calls, 0)
end

return T
