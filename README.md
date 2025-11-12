# csvcols.nvim

Colorize **CSV/TSV** files by giving each **column** a distinct highlight color. Optional clean view mode for tabular view. Tiny, fast, written in Lua. Highlights only the **visible window range** and updates as you scroll or edit. Supports sticky headers with arbitry number of lines.

---

## Features
- Per‑column coloring for `.csv` and `.tsv` (RFC‑4180‑style quoted fields supported)
- Background **or** foreground coloring
- Efficient: re-highlights only visible lines on `WinScrolled`, `CursorMoved`, edits, etc.
- Zero‑config optional auto‑setup (via `plugin/csvcols.lua`), or explicit `setup()`
- Sticky headers configurable via commands or (optional) GUI buttons.
- Autodetection of separator character (can be turned off)
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
- `:CsvColsRefresh` - force re-colorizing the visible range
- `:CsvColsClear` - clear all column highlights in current buffer
- `gC` / `:CsvCleanToggle` - toggle tabular "clean view" mode
- `:CsvAutoSepToggle` / `:CsvAutoSep {on|off}` - toggle/set separator autodetection
- `:CsvAutoClean` / `:CsvAutoEnable` - toggle/set autodetection on any buffer
- `:CsvHeader` / `:CsvHeaderToggle`  - set/toggle sticky header
- `:CsvHeaderInc` / `:CsvHeaderDec`  - increase/decrease number of lines in sticky header

---

## Configuration
Default configuration (you can override any key in `setup({ ... })`):
For example:

```lua
require('csvcols').setup({
  colors = {
    "#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
    "#00838f", "#827717", "#7b1fa2", "#37474f", "#558b2f",
    "#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
  },
  mode = "bg",                  -- "bg" or "fg" for background or foreground coloring
  max_columns = 64,             -- Soft cap for extremely wide files
  patterns = { "*.csv", "*.tsv" },
  filetypes = { "csv", "tsv" },
  default_header_lines = 1,     -- How many lines to pin as sticky header
  use_winbar_controls = true,   -- Add clickable [+]/[-] controls for header lines
  keymap = true,                -- Enable `gC` shortcut for clean view toggle
  auto_detect_separator = true, -- Enable separator autodetection
  detect_candidates = { "\t", ",", ";", "|" }, -- Supported delimiters in detector separation
  clean_view_by_default = false, -- start in clean view mode?
})
```

**Tip:** The plugin works for any buffer if you manually toggle :CsvCleanToggle or :CsvAutoSepToggle, even for files not ending in .csv or .tsv. Or set `cleam_view_by_default = true`.

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
MIT © T. Grassmann
