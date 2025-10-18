-- csvcols/init.lua
local M = {}

local ns = vim.api.nvim_create_namespace("csvcols")
local header_ns = vim.api.nvim_create_namespace("csvcols_header")

local AUGROUP_NAME = "csvcols_autocmds"

-- Default configuration.  Users can override these in setup()
M.config = {
  colors = {
    "#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
    "#00838f", "#827717", "#7b1fa2", "#37474f", "#558b2f",
    "#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
  },
  -- Set to "bg" to apply colors as background, or "fg" for foreground.
  mode = "bg",
  max_columns = 64,
  patterns = { "*.csv", "*.tsv" },
  filetypes = { "csv", "tsv" },
  default_header_lines = 1,
  use_winbar_controls = true,
}

M._state = setmetatable({}, { __mode = "k" })

-- Utility to get or create state for a buffer
local function bufstate(buf)
  local st = M._state[buf]
  if not st then
    st = {}
    M._state[buf] = st
  end
  return st
end

-- Determine how many header lines are configured for a buffer.
local function get_header_n(buf)
  local st = bufstate(buf)
  return st.header_n or M.config.default_header_lines or 0
end

-- Set header lines for a buffer.  Negative values are clamped to 0.
local function set_header_n(buf, n)
  local st = bufstate(buf)
  st.header_n = math.max(0, math.floor(n or 0))
end

-- Increment header lines for a buffer by delta.  Negative values
-- decrease the count.  This calls set_header_n() to clamp.
local function inc_header_n(buf, delta)
  set_header_n(buf, get_header_n(buf) + (delta or 1))
end

-- Return true if the given buffer should be considered a CSV/TSV
local function is_csv_buf(buf)
  local ft = vim.bo[buf].filetype
  for _, f in ipairs(M.config.filetypes) do
    if ft == f then return true end
  end
  local name = vim.api.nvim_buf_get_name(buf):lower()
  return name:match("%.csv$") or name:match("%.tsv$")
end

-- Utility to detect whether the mouse is enabled in normal/visual
-- mode (or all modes).  The click handlers in the winbar only
-- operate when the mouse option includes 'n' or 'v' or 'a'.
local function mouse_supports_clicks()
  local m = vim.o.mouse or ""
  return m:find("a", 1, true) or m:find("n", 1, true) or m:find("v", 1, true)
end

-- Create highlight groups for each configured color.  Highlight
-- definitions are buffer-local for simplicity (0 means current buf)
local function set_default_hl()
  for i, color in ipairs(M.config.colors) do
    local hl_def = (M.config.mode == "bg") and { bg = color } or { fg = color }
    hl_def.bold = false
    vim.api.nvim_set_hl(0, ("CsvCol%d"):format(i), hl_def)
  end
  -- Separator highlight: used between columns in the sticky header
  if vim.fn.hlexists("CsvSep") == 0 then
    vim.api.nvim_set_hl(0, "CsvSep", { link = "Comment" })
  end
  -- Header text highlight: used when the header line has no content
  if vim.fn.hlexists("CsvHeaderText") == 0 then
    vim.api.nvim_set_hl(0, "CsvHeaderText", { bold = true })
  end
end

-- Determine the field separator for a buffer.  We use the file
-- extension to detect TSV (tab) and default to comma for CSV.
local function get_sep(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("%.tsv$") then
    return "\t"
  end
  return ","
end

-- Parse a line into ranges representing fields.  This tiny CSV
-- parser supports quoted fields with escaped quotes ("\" within
-- quotes).  It returns an array of {start_col, end_col} pairs in
-- byte offsets.  end_col = -1 means EOL (for nvim_buf_add_highlight).
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
      start_col = k + 1
      if #ranges >= max_cols then
        -- Do not parse beyond max_cols
        start_col = k + 1
      end
    end
    k = k + 1
    if #ranges >= max_cols then break end
  end
  -- Append last field if we have not reached max_cols
  if #ranges < max_cols then
    ranges[#ranges + 1] = { start_col, -1 }
  end
  return ranges
end

-- Given a header line, build virt_lines chunks for the sticky header.
-- Each chunk is a table { { text, highlight } ... } and returned
-- inside a list to represent multiple lines.  We reuse the same
-- per-column highlight groups created in set_default_hl().  The
-- separator is drawn with the CsvSep group.
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
  -- If no chunks produced (empty line), add a single space so the
  -- virtual header still occupies a row
  if #chunks == 0 then
    table.insert(chunks, { " ", "CsvHeaderText" })
  end
  return chunks
end

-- Render the sticky header above the top visible line in the given
-- window.  If there are no header lines configured or the top of
-- window is at or above the header (no need to duplicate), we clear
-- the header namespace.  Otherwise, we grab up to n header lines
-- from the buffer and set an extmark with virt_lines_above=true.
local function render_header(win, buf, sep, top)
  -- Always clear previous header extmarks
  vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
  local n = get_header_n(buf)
  if n <= 0 then return end
  if top <= 0 then return end -- Real header visible; no sticky needed
  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then return end
  local upto = math.min(n, total)
  local header_lines = vim.api.nvim_buf_get_lines(buf, 0, upto, false)
  if #header_lines == 0 then return end
  local virt_lines = {}
  for _, hline in ipairs(header_lines) do
    table.insert(virt_lines, header_virt_chunks(hline, sep))
  end
  -- Place an extmark on the top visible row; draw header above it
  pcall(function()
    vim.api.nvim_buf_set_extmark(buf, header_ns, top, 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
      hl_mode = "combine",
    })
  end)
end

-- Build the winbar string for a window.  When use_winbar_controls is
-- true and mouse support is available, we include clickable buttons
-- [-] and [+] that call our Lua functions _click_dec and _click_inc.
-- Otherwise, we show a static readout of the header count.  The bar
-- is right-aligned with a "csvcols" tag.
function M._winbar_for(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) or not M.config.use_winbar_controls then
    return ""
  end
  local n = get_header_n(buf)
  if not mouse_supports_clicks() then
    return table.concat({
      "%#Title#CSV hdr:%* ",
      ("%#Title#%d%* "):format(n),
      "%=%#Comment#  csvcols%*",
    })
  end
  -- Clickable version: @CALLABLE@text%X defines a clickable region
  return table.concat({
    "%#Title#CSV hdr:%* ",
    "%@v:lua.require'csvcols'._click_dec@[-]%X ",
    ("%#Title#%d%* "):format(n),
    "%@v:lua.require'csvcols'._click_inc@[+ ]%X",
    "%=%#Comment#  csvcols%*",
  })
end

-- Click handler to increment the header count.  Called via winbar
-- when [+] is clicked.  We ignore unused parameters and refresh the
-- window after adjusting.
function M._click_inc(minwid, clicks, button, mods)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, 1)
  M.refresh(win)
end

-- Click handler to decrement the header count.  Called via winbar
-- when [-] is clicked.
function M._click_dec(minwid, clicks, button, mods)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, -1)
  M.refresh(win)
end

-- Set or clear the winbar for a window.  When leaving CSV buffers or
-- when use_winbar_controls is disabled, we clear the bar.  Otherwise
-- we set it to the value returned by _winbar_for().
local function maybe_set_winbar(win)
  if not M.config.use_winbar_controls then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then
    -- Clear our winbar if present.  Use pcall in case user has
    -- modified winbar for the window (e.g. with another plugin).
    local cur = vim.wo[win].winbar or ""
    if cur:match("csvcols") then
      pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
    end
    return
  end
  local bar = M._winbar_for(win)
  pcall(vim.api.nvim_set_option_value, "winbar", bar, { scope = "local", win = win })
end

-- Refresh highlights and sticky header for a window.  This function
-- does nothing for buffers that are not CSV/TSV.  For CSV/TSV
-- buffers, it colors the visible columns, renders the sticky header,
-- and updates the winbar.
function M.refresh(win)
  win = (win ~= 0 and win) or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then
    -- Not a CSV buffer: clear any previous header marks and winbar
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
    return
  end
  local sep = get_sep(buf)
  -- Determine top and bottom lines of window (0-based top, 1-based bottom)
  local top = vim.fn.line("w0") - 1
  local bottom = vim.fn.line("w$")
  if bottom <= top then
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
    return
  end
  -- Clear existing column highlights in visible region
  vim.api.nvim_buf_clear_namespace(buf, ns, top, bottom)
  -- Highlight each column in the visible lines
  local lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)
  for i, line in ipairs(lines) do
    local ranges = field_ranges(line, sep, M.config.max_columns)
    for col_idx, r in ipairs(ranges) do
      local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
      local start_col, end_col = r[1], r[2]
      vim.api.nvim_buf_add_highlight(buf, ns, group, top + i - 1, start_col, end_col)
    end
  end
  -- Render sticky header (if enabled)
  render_header(win, buf, sep, top)
  -- Update winbar controls
  maybe_set_winbar(win)
end

function M.setup(opts)
  -- Merge user options into config
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  set_default_hl()
  -- Remove any existing autocommand group to avoid duplicate
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
  local augroup = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI", "InsertLeave", "WinScrolled", "CursorMoved" },
    {
      group = augroup,
      pattern = "*",
      callback = function() M.refresh(0) end,
      desc = "csvcols: colorize CSV/TSV columns & sticky header",
    }
  )
  -- Also handle leaving CSV windows: clear sticky header and winbar
  vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed", "WinLeave" }, {
    group = augroup,
    callback = function() M.refresh(0) end,
    desc = "csvcols: cleanup on leave",
  })
  -- User commands for controlling header lines
  vim.api.nvim_create_user_command("CsvHeader", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    if cmd.args == "" then
      vim.notify(('[csvcols] Header lines: %d'):format(get_header_n(buf)))
    else
      local n = tonumber(cmd.args)
      if not n then
        vim.notify('[csvcols] CsvHeader expects a number', vim.log.levels.WARN)
        return
      end
      set_header_n(buf, n)
      M.refresh(0)
    end
  end, { nargs = '?', desc = 'Get/set number of sticky header lines for this buffer' })
  vim.api.nvim_create_user_command("CsvHeaderInc", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    local d = tonumber(cmd.args) or 1
    inc_header_n(buf, d)
    M.refresh(0)
  end, { nargs = '?', desc = 'Increase sticky header lines for this buffer' })
  vim.api.nvim_create_user_command("CsvHeaderDec", function(cmd)
    local buf = vim.api.nvim_get_current_buf()
    local d = tonumber(cmd.args) or 1
    inc_header_n(buf, -d)
    M.refresh(0)
  end, { nargs = '?', desc = 'Decrease sticky header lines for this buffer' })
  vim.api.nvim_create_user_command("CsvHeaderToggle", function()
    local buf = vim.api.nvim_get_current_buf()
    local n = get_header_n(buf)
    if n > 0 then
      set_header_n(buf, 0)
    else
      set_header_n(buf, M.config.default_header_lines or 1)
    end
    M.refresh(0)
  end, { desc = 'Toggle sticky header for this buffer' })
  -- Existing commands for backward compatibility
  vim.api.nvim_create_user_command("CsvColsRefresh", function() M.refresh(0) end, { desc = 'Recolorize visible CSV/TSV columns in current buffer' })
  vim.api.nvim_create_user_command("CsvColsClear", function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
  end, { desc = 'Clear csvcols highlights/header in current buffer' })
end

return M

