-- csvcols/init.lua
local M = {}

local ns = vim.api.nvim_create_namespace("csvcols")
local header_ns = vim.api.nvim_create_namespace("csvcols_header")
local augroup = vim.api.nvim_create_augroup("csvcols_autocmds", { clear = true })

M.config = {
  -- Cycle these colors across columns:
  colors = {
    "#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
    "#00838f", "#827717", "#7b1fa2", "#37474f", "#558b2f",
    "#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
  },
  mode = "bg",        -- "bg" or "fg" (set background or foreground)
  max_columns = 64,   -- soft cap for columns to color
  patterns = { "*.csv", "*.tsv" },
  filetypes = { "csv", "tsv" }, -- if ftplugins set these
  default_header_lines = 1,	-- how many lines are pinned by default
  use_winbar_controls = true,   -- show [-][+] buttons control header lines shown
}

-- per-buffer state 
M._state = setmetatable({}, { __mode = "k" })

local function bufstate(buf)
  local st = M._state[buf]
  if not st then
    st = { header_n = nil }
    M._state[buf] = st
  end
  return st
end

local function get_header_n(buf)
  local st = bufstate(buf)
  return st.header_n or M.config.default_header_lines
end

local function set_header_n(buf, n)
  local st = bufstate(buf)
  st.header_n = math.max(0, math.floor(n or 0))
end

local function inc_header_n(buf, delta)
  set_header_n(buf, get_header_n(buf) + (delta or 1))
end

local function is_csv_buf(buf)
  local ft = vim.bo[buf].filetype
  for _, f in ipairs(M.config.filetypes) do
    if ft == f then return true end
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name:match("%.csv$") or name:match("%.tsv$")
end

local function set_default_hl()
  for i, color in ipairs(M.config.colors) do
    local def = (M.config.mode == "bg") and { bg = color } or { fg = color }
    def.bold = false
    vim.api.nvim_set_hl(0, ("CsvCol%d"):format(i), def)
  end
  -- separator & header text defaults (subtle)
  if vim.fn.hlexists("CsvSep") == 0 then
    vim.api.nvim_set_hl(0, "CsvSep", { link = "Comment" })
  end
  if vim.fn.hlexists("CsvHeaderText") == 0 then
    vim.api.nvim_set_hl(0, "CsvHeaderText", { bold = true })
  end
end

local function get_sep(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%.tsv$") then return "\t" end
  return ","  -- default to csv
end

-- Return a list of {col_start, col_end} for the fields in a line
-- Uses a tiny CSV state machine with quoted-field support and "" escaping.
local function field_ranges(line, sep, max_cols)
  local ranges = {}
  local len = #line
  local in_quotes = false
  local k = 0                
  local start_col = 0        
  while k < len do
    local ch = line:sub(k + 1, k + 1)
    if ch == '"' then
      if in_quotes and (k + 1 < len) and (line:sub(k + 2, k + 2) == '"') then
        -- Escaped quote "" -> skip second quote
        k = k + 1
      else
        in_quotes = not in_quotes
      end
    elseif ch == sep and not in_quotes then
      ranges[#ranges + 1] = { start_col, k }  
      start_col = k + 1                       -- next field starts after sep
      if #ranges >= max_cols then
        start_col = k + 1
      end
    end
    k = k + 1
    if #ranges >= max_cols then break end
  end
  if #ranges < max_cols then
    ranges[#ranges + 1] = { start_col, -1 }   -- -1 = EOL for add_highlight
  end
  return ranges
end

-- Build virt_lines chunks for a header line using the same per-column highlight groups.
-- Returns: { { {text, hl}, {sep, CsvSep}, ... } }
local function header_virt_chunks(line, sep)
  local chunks = {}
  local ranges = field_ranges(line, sep, M.config.max_columns)
  for col_idx, r in ipairs(ranges) do
    local start_col, end_col = r[1], r[2]
    local s = start_col + 1
    local e = (end_col == -1) and #line or end_col
    local text = (e >= s) and line:sub(s, e) or ""
    local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
    if text ~= "" then
      table.insert(chunks, { text, group })
    end
    if col_idx < #ranges then
      table.insert(chunks, { sep, "CsvSep" })
    end
  end
  if #chunks == 0 then
    -- empty line fallback so the virtual header still occupies a row
    table.insert(chunks, { " ", "CsvHeaderText" })
  end
  return chunks
end

-- Render sticky header above the top visible line
local function render_header(win, buf, sep, top)
  vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)

  local n = get_header_n(buf)
  if n <= 0 then return end
  if top <= 0 then return end -- when real header is visible, don't duplicate

  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then return end

  local upto = math.min(n, total)
  local header_lines = vim.api.nvim_buf_get_lines(buf, 0, upto, false)
  if #header_lines == 0 then return end

  local virt_lines = {}
  for _, hline in ipairs(header_lines) do
    table.insert(virt_lines, header_virt_chunks(hline, sep))
  end

  -- Place one extmark at the top visible row; draw header above it.
  pcall(function()
    vim.api.nvim_buf_set_extmark(buf, header_ns, top, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
      hl_mode = "combine",
    })
  end)
end

-- Build (and optionally install) a winbar with clickable - / + to change header lines
function M._winbar_for(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) or not M.config.use_winbar_controls then
    return ""
  end
  local n = get_header_n(buf)
  -- Click handlers call Lua funcs below. %X ends the clickable region.
  -- Layout:  CSV hdr: [ - ]  n  [ + ]     (align right)
  local bar = table.concat({
    "%#Title#CSV hdr:%* ",
    "%@v:lua.require'csvcols'._click_dec@[-]%X ",
    ("%#Title#%d%* "):format(n),
    "%@v:lua.require'csvcols'._click_inc@[+ ]%X",
    "%=%#Comment#  csvcols%*", -- right align tag
  })
  return bar
end

function M._click_inc(minwid, clicks, button, mods)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, 1)
  M.refresh(win)
end

function M._click_dec(minwid, clicks, button, mods)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, -1)
  M.refresh(win)
end

local function maybe_set_winbar(win)
  if not M.config.use_winbar_controls then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then
    -- Clear our winbar if present
    local cur = vim.wo[win].winbar or ""
    if cur:match("csvcols") then
      pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
    end
    return
  end
  local bar = M._winbar_for(win)
  pcall(vim.api.nvim_set_option_value, "winbar", bar, { scope = "local", win = win })
end

function M.refresh(win)
  win = (win ~= 0 and win) or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)

  if not is_csv_buf(buf) then
    -- clear any header remnants/winbar if we leave
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
    return
  end

  local sep = get_sep(buf)
  local top = vim.fn.line("w0") - 1      -- 0-based top line in window
  local bottom = vim.fn.line("w$")       -- 1-based bottom line (exclusive in clear)
  if bottom <= top then
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
    return
  end

  -- Recolor visible columns (original behavior)
  vim.api.nvim_buf_clear_namespace(buf, ns, top, bottom)
  local lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)
  for i, line in ipairs(lines) do
    local ranges = field_ranges(line, sep, M.config.max_columns)
    for col_idx, r in ipairs(ranges) do
      local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
      local start_col, end_col = r[1], r[2]
      vim.api.nvim_buf_add_highlight(buf, ns, group, top + i - 1, start_col, end_col)
    end
  end

  -- Sticky header
  render_header(win, buf, sep, top)

  -- Winbar controls (if enabled)
  maybe_set_winbar(win)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  set_default_hl()

  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI", "InsertLeave", "WinScrolled", "CursorMoved" },
    {
      group = augroup,
      pattern = M.config.patterns,
      callback = function() M.refresh(0) end,
      desc = "csvcols: colorize CSV/TSV columns & sticky header",
    }
  )

  -- also handle leaving csv windows (clear winbar/header)
  vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed", "WinLeave" }, {
    group = augroup,
    callback = function() M.refresh(0) end,
    desc = "csvcols: cleanup on leave",
  })

  -- Commands to control header lines (per-buffer)
  vim.api.nvim_create_user_command("CsvHeader", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    if cmd.args == "" then
      vim.notify(("[csvcols] Header lines: %d"):format(get_header_n(buf)))
    else
      local n = tonumber(cmd.args)
      if not n then
        vim.notify("[csvcols] CsvHeader expects a number", vim.log.levels.WARN)
        return
      end
      set_header_n(buf, n)
      M.refresh(0)
    end
  end, { nargs = "?", desc = "Get/set number of sticky header lines for this buffer" })

  vim.api.nvim_create_user_command("CsvHeaderInc", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    local d = tonumber(cmd.args) or 1
    inc_header_n(buf, d)
    M.refresh(0)
  end, { nargs = "?", desc = "Increase sticky header lines for this buffer" })

  vim.api.nvim_create_user_command("CsvHeaderDec", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    local d = tonumber(cmd.args) or 1
    inc_header_n(buf, -d)
    M.refresh(0)
  end, { nargs = "?", desc = "Decrease sticky header lines for this buffer" })

  vim.api.nvim_create_user_command("CsvHeaderToggle", function()
    local buf = vim.api.nvim_get_current_buf()
    local n = get_header_n(buf)
    set_header_n(buf, (n > 0) and 0 or (M.config.default_header_lines or 1))
    M.refresh(0)
  end, { desc = "Toggle sticky header for this buffer" })

  -- existing commands
  vim.api.nvim_create_user_command("CsvColsRefresh", function() M.refresh(0) end, { desc = "Recolorize visible CSV/TSV columns in current buffer" })
  vim.api.nvim_create_user_command("CsvColsClear", function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
  end, { desc = "Clear csvcols highlights/header in current buffer" })
end

return M

