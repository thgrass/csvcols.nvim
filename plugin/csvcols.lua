-- plugin/csvcols.lua
if vim.g.loaded_csvcols then return end
vim.g.loaded_csvcols = true
pcall(function()
  require("csvcols").setup()  -- users can still override by calling setup() later
end)

