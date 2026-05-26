vim.pack.add({
  'https://github.com/stevearc/conform.nvim',
})

local prettier_markers = {
  '.prettierrc',
  '.prettierrc.json',
  '.prettierrc.jsonc',
  '.prettierrc.yaml',
  '.prettierrc.yml',
  '.prettierrc.js',
  '.prettierrc.cjs',
  '.prettierrc.mjs',
  '.prettierrc.toml',
  'prettier.config.js',
  'prettier.config.cjs',
  'prettier.config.mjs',
}

local oxfmt_markers = {
  '.oxfmtrc.json',
  '.oxfmtrc.jsonc',
}

local function has_dep(pkg, name)
  for _, key in ipairs({ 'dependencies', 'devDependencies', 'optionalDependencies' }) do
    if type(pkg[key]) == 'table' and pkg[key][name] ~= nil then
      return true
    end
  end
  return false
end

local function package_json_has(name, bufname)
  local found = vim.fs.find('package.json', {
    upward = true,
    path = vim.fs.dirname(bufname),
    stop = vim.loop.os_homedir(),
  })[1]
  if not found then
    return false
  end
  local ok, content = pcall(vim.fn.readfile, found)
  if not ok then
    return false
  end
  local ok2, pkg = pcall(vim.json.decode, table.concat(content, '\n'))
  if not ok2 or type(pkg) ~= 'table' then
    return false
  end
  return has_dep(pkg, name)
end

local function find_marker(markers, bufname)
  return vim.fs.find(markers, {
    upward = true,
    path = vim.fs.dirname(bufname),
    stop = vim.loop.os_homedir(),
  })[1] ~= nil
end

local function js_formatter(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == '' then
    return { 'oxfmt' }
  end

  if find_marker(oxfmt_markers, bufname) or package_json_has('oxfmt', bufname) then
    return { 'oxfmt' }
  end

  if find_marker(prettier_markers, bufname) or package_json_has('prettier', bufname) then
    return { 'prettier' }
  end

  return { 'oxfmt' }
end

require('conform').setup({
  notify_on_error = true,
  format_on_save = true,
  default_format_opts = {
    timeout_ms = 2000,
    lsp_format = 'fallback',
  },
  formatters_by_ft = {
    lua = { 'stylua' },
    python = { 'isort', lsp_format = 'last' },
    javascript = js_formatter,
    typescript = js_formatter,
    typescriptreact = js_formatter,
    json = js_formatter,
    jsonc = js_formatter,
    cmake = { 'gersemi' },
    markdown = js_formatter,
    mdx = js_formatter,
    toml = { 'taplo' },
  },
})
