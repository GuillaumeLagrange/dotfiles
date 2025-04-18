local M = {}

local is_underline_enabled = false
local is_virtual_lines_enabled = false

local get_diagnostic_config = function()
  if is_virtual_lines_enabled then
    return {
      underline = is_underline_enabled,
      virtual_text = {
        severity = {
          max = vim.diagnostic.severity.WARN,
        },
      },
      virtual_lines = {
        severity = {
          min = vim.diagnostic.severity.ERROR,
        },
      },
    }
  else
    return {
      underline = is_underline_enabled,
      virtual_text = {
        severity = {
          max = vim.diagnostic.severity.ERROR,
        },
      },
      virtual_lines = false,
    }
  end
end

M.toggle_diagnostic_underline = function()
  is_underline_enabled = not is_underline_enabled
  vim.diagnostic.config(get_diagnostic_config())
end

M.toggle_diagnostic_virtual_lines = function()
  is_virtual_lines_enabled = not is_virtual_lines_enabled
  vim.diagnostic.config(get_diagnostic_config())
end

vim.diagnostic.config(get_diagnostic_config())

return M
