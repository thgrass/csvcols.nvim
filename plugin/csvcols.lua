-- plugin/csvcols.lua
if vim.g.loaded_csvcols then return end
vim.g.loaded_csvcols = true
pcall(function()
  require("csvcols").setup({
	  default_header_lines = 1,     -- lines in sticky header
	  use_winbar_controls = true,   -- show clickable buttons (only when mouse supported)
  })  -- users can still override by calling setup() later
end)

