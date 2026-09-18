local plugins = require("lazy.core.config").plugins
local missing = {}
for name, plugin in pairs(plugins) do
  if vim.fn.isdirectory(plugin.dir) ~= 1 then
    table.insert(missing, name)
  end
end
table.sort(missing)
if #missing > 0 or vim.v.errmsg ~= "" then
  vim.api.nvim_err_writeln("Incomplete Neovim plugin cache: " .. table.concat(missing, ", "))
  if vim.v.errmsg ~= "" then
    vim.api.nvim_err_writeln(vim.v.errmsg)
  end
  vim.cmd("cquit 1")
end
print("LAZY_PLUGIN_CACHE_OK", vim.tbl_count(plugins))
