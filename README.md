# csvcols.nvim

Colorize **CSV/TSV** files by giving each **column** a distinct highlight color. Optional clean view mode for tabular view. Tiny, fast, written in Lua. Highlights only the **visible window range** and updates as you scroll or edit. Supports sticky headers with arbitry number of lines.

---

## Features
- Per‑column coloring for `.csv` and `.tsv` (RFC‑4180‑style quoted fields supported)
- Background **or** foreground coloring
- Efficient: re-highlights only visible lines on `WinScrolled`, `CursorMoved`, edits, etc.
- Zero‑config optional auto‑setup (via `plugin/csvcols.lua`), or explicit `setup()`
- Sticky headers configurable via commands or (optional) GUI buttons.
- "Clean View" mode renders CSV/TSV as padded, spreadsheet-like table in a synced overlay.

## Requirements
- Neovim 0.8+ (LuaJIT)

---

## Installation

### lazy.nvim
```lua
{
  "thgrass/csvcols.nvim",
  ft = { "csv", "tsv" },
  opts = {
    -- mode = "bg",        -- or "fg"
    -- max_columns = 64,
    -- colors = { "#2e7d32", "#1565c0", "#ad1457", "#ef6c00" },
  },
}
```

### packer.nvim
```lua
use {
  "thgrass/csvcols.nvim",
  ft = { "csv", "tsv" },
  config = function()
    require("csvcols").setup({
      -- optional overrides
    })
  end,
}
```

### vim-plug
```vim
Plug 'thgrass/csvcols.nvim', { 'for': ['csv','tsv'] }
" after plug#end():
lua << EOF
require('csvcols').setup({
  -- optional overrides
})
EOF
```

### dein.vim
```vim
call dein#add('thgrass/csvcols.nvim', {'on_ft': ['csv','tsv']})
autocmd FileType csv,tsv lua require('csvcols').setup()
```

---

## Usage
- **Automatic**: The plugin calls `setup()` with defaults when Neovim starts, and coloring happens whenever opening `.csv`/`.tsv` files.
- **Edit Settings**: Edit the code in `plugin/csvcols.lua` or provide your own call to `setup()` elsewhere. See "Configuration" right below.

Commands:
- `:CsvColsRefresh` — force re-colorizing the visible range
- `:CsvColsClear` — clear all column highlights in current buffer

---

## Configuration
Default configuration (you can override any key in `setup({ ... })`):

```lua
require('csvcols').setup({
  colors = {
    "#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
    "#00838f", "#827717", "#7b1fa2", "#37474f", "#558b2f",
    "#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
  },
  mode = "bg",          -- "bg" or "fg"
  max_columns = 64,      -- soft cap for work on ultra-wide files
  patterns = { "*.csv", "*.tsv" },
  filetypes = { "csv", "tsv" }, -- if you have ftplugins setting these
  default_header_lines = 1,  -- How many lines to pin by default (0 disables by default)
  use_winbar_controls = true, -- Show clickable [-]/[+] buttons in winbar that change lines in sticky header
  clean_view_full_scan = true, -- Compute column widths from the entire buffer (true) or only the visible window (false). Set to false for very large files to keep updates snappy.
  keymap = true, -- Provide a default keymap `gC` to toggle clean view. 
})

vim.opt.mouse = "a"    -- enable mouse, should be enabled per default
```



---

## Repo layout
```
csvcols.nvim/
├─ lua/
│  └─ csvcols/
│     └─ init.lua        <-- main plugin module
├─ plugin/
│  └─ csvcols.lua        <-- auto-setup with defaults
├─ README.md
└─ LICENSE
```

---

## License
MIT © thgrass
