-- csvcols/init.lua
-- CSV/TSV column coloring + sticky header + clean-view (tabular) overlay.
-- Sticky header is a per-window floating overlay at row 0.
-- Clean-view is another overlay that renders a padded, spreadsheet-like view
-- that scrolls in sync with the main window and mirrors the cursor position.

local M = {}

-- Namespaces
local ns         = vim.api.nvim_create_namespace("csvcols")         -- column hl (main buf and overlays)
local header_ns  = vim.api.nvim_create_namespace("csvcols_header")  -- (kept for safety)

-- Augroup name (setup recreates it each time to avoid dupes)
local AUGROUP_NAME = "csvcols_autocmds"

-- Config (defaults)
M.config = {
  colors = {
    "#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
    "#00838f", "#827717", "#7b1fa2", "#37474f", "#558b2f",
    "#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
  },
  mode = "bg",                 -- "bg" or "fg"
  max_columns = 64,
  patterns = { "*.csv", "*.tsv" },
  filetypes = { "csv", "tsv" },

  default_header_lines = 1,    -- sticky header ON by default
  use_winbar_controls = true,  -- show [-] n [+] buttons in winbar

  -- Clean-view settings
  -- true: compute column widths from whole file; false: from visible region (faster for huge files)
  clean_view_full_scan = true,

  -- Default keymap for clean-view toggle (gC). Set to false to disable.
  keymap = true,
}

-- per-buffer state (weak keys)
M._state = setmetatable({}, { __mode = "k" })
local function bufstate(buf)
  local st = M._state[buf]
  if not st then st = {}; M._state[buf] = st end
  return st
end
local function get_header_n(buf)
  local st = bufstate(buf)
  return st.header_n or M.config.default_header_lines or 0
end
local function set_header_n(buf, n)
  bufstate(buf).header_n = math.max(0, math.floor(n or 0))
end
local function inc_header_n(buf, d)
  set_header_n(buf, get_header_n(buf) + (d or 1))
end

-- floating overlay manager (per-window) for sticky header
-- overlays[winid] = { win = float_winid, buf = float_bufid, height = int }
local overlays = {}
local function close_overlay(win)
  local ov = overlays[win]
  if not ov then return end
  if ov.win and vim.api.nvim_win_is_valid(ov.win) then
    pcall(vim.api.nvim_win_close, ov.win, true)
  end
  overlays[win] = nil
end

-- Clean-view overlay manager (separate from header overlays)
-- clean_ov[winid] = { win = float_winid, buf = float_bufid }
local clean_ov = {}
local function close_clean_overlay(win)
  local ov = clean_ov[win]
  if not ov then return end
  if ov.win and vim.api.nvim_win_is_valid(ov.win) then
    pcall(vim.api.nvim_win_close, ov.win, true)
  end
  clean_ov[win] = nil
end

-- Ensure header float exists at row 0 with given width/height and left offset
local function ensure_overlay(win, height, col_off, width)
  local ov = overlays[win]
  col_off = col_off or 0
  width   = math.max(1, width or 1)

  if ov and ov.win and vim.api.nvim_win_is_valid(ov.win) then
    pcall(vim.api.nvim_win_set_config, ov.win, {
      relative = "win",
      win = win,
      row = 0,
      col = col_off,
      width = width,
      height = height,
      zindex = 50, -- header above clean-view
    })
    ov.height = height

    -- keep window-local options in sync
    local ok_list, list_val = pcall(vim.api.nvim_get_option_value, "list", { win = win })
    if ok_list then pcall(vim.api.nvim_set_option_value, "list", list_val, { win = ov.win }) end

    -- keep buffer-local tabstop in sync (read from source buf, set on overlay buf)
    local src_buf = vim.api.nvim_win_get_buf(win)
    local ok_ts, ts_val = pcall(vim.api.nvim_get_option_value, "tabstop", { buf = src_buf })
    if ok_ts then pcall(vim.api.nvim_set_option_value, "tabstop", ts_val, { buf = ov.buf }) end

    return ov
  end

  local buf = vim.api.nvim_create_buf(false, true) -- scratch, nofile
  local float = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = col_off,
    width = width,
    height = height,
    focusable = false,
    style = "minimal",
    noautocmd = true,
    zindex = 50,
  })

  -- minimal UI on header overlay
  pcall(vim.api.nvim_set_option_value, "wrap", false,            { win = float })
  pcall(vim.api.nvim_set_option_value, "cursorline", false,      { win = float })
  pcall(vim.api.nvim_set_option_value, "number", false,          { win = float })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false,  { win = float })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no",       { win = float })
  pcall(vim.api.nvim_set_option_value, "foldcolumn", "0",        { win = float })

  -- copy list option
  local ok_list, list_val = pcall(vim.api.nvim_get_option_value, "list", { win = win })
  if ok_list then pcall(vim.api.nvim_set_option_value, "list", list_val, { win = float }) end

  -- copy tabstop
  local src_buf = vim.api.nvim_win_get_buf(win)
  local ok_ts, ts_val = pcall(vim.api.nvim_get_option_value, "tabstop", { buf = src_buf })
  if ok_ts then pcall(vim.api.nvim_set_option_value, "tabstop", ts_val, { buf = buf }) end

  overlays[win] = { win = float, buf = buf, height = height }
  return overlays[win]
end

-- Ensure clean-view float exists over the text area
local function ensure_clean_overlay(win, height, col_off, width)
  local ov = clean_ov[win]
  col_off = col_off or 0
  width   = math.max(1, width or 1)

  if ov and ov.win and vim.api.nvim_win_is_valid(ov.win) then
    pcall(vim.api.nvim_win_set_config, ov.win, {
      relative = "win",
      win = win,
      row = 0,                 -- full text area (header sits above with higher zindex)
      col = col_off,
      width = width,
      height = height,
      zindex = 40,             -- below header overlay
    })
    return ov
  end

  local buf = vim.api.nvim_create_buf(false, true) -- scratch, nofile
  local float = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = win,
    row = 0,
    col = col_off,
    width = width,
    height = height,
    focusable = false,         -- behaves like viewer; we mirror cursor
    style = "minimal",
    noautocmd = true,
    zindex = 40,
  })

  -- minimal UI on clean overlay
  pcall(vim.api.nvim_set_option_value, "wrap", false,            { win = float })
  pcall(vim.api.nvim_set_option_value, "cursorline", false,      { win = float })
  pcall(vim.api.nvim_set_option_value, "number", false,          { win = float })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false,  { win = float })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no",       { win = float })
  pcall(vim.api.nvim_set_option_value, "foldcolumn", "0",        { win = float })

  -- Inherit tabstop from source buf (for any rendering that depends on it)
  local src_buf = vim.api.nvim_win_get_buf(win)
  local ok_ts, ts_val = pcall(vim.api.nvim_get_option_value, "tabstop", { buf = src_buf })
  if ok_ts then pcall(vim.api.nvim_set_option_value, "tabstop", ts_val, { buf = buf }) end

  clean_ov[win] = { win = float, buf = buf }
  return clean_ov[win]
end

-- helpers
local function is_csv_buf(buf)
  local ft = vim.bo[buf].filetype
  for _, f in ipairs(M.config.filetypes) do
    if ft == f then return true end
  end
  local name = vim.api.nvim_buf_get_name(buf):lower()
  return name:match("%.csv$") or name:match("%.tsv$")
end

local function mouse_supports_clicks()
  local m = vim.o.mouse or ""
  return m:find("a", 1, true) or m:find("n", 1, true) or m:find("v", 1, true)
end

local function set_default_hl()
  for i, color in ipairs(M.config.colors) do
    local def = (M.config.mode == "bg") and { bg = color } or { fg = color }
    def.bold = false
    vim.api.nvim_set_hl(0, ("CsvCol%d"):format(i), def)
  end
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
  return ","
end

-- Return { {start_col, end_col} ... } for fields on a line.
-- CSV state machine with quoted-field support and "" escaping.
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
        k = k + 1 -- skip escaped quote
      else
        in_quotes = not in_quotes
      end
    elseif ch == sep and not in_quotes then
      ranges[#ranges + 1] = { start_col, k }
      start_col = k + 1
      if #ranges >= max_cols then
        start_col = k + 1
      end
    end
    k = k + 1
    if #ranges >= max_cols then break end
  end
  if #ranges < max_cols then
    ranges[#ranges + 1] = { start_col, -1 } -- -1 = EOL
  end
  return ranges
end

-- Render sticky header (existing behavior), aligned via textoff
local function render_header(win, buf, sep, top)
  local n = get_header_n(buf)

  if n <= 0 or top <= 0 then
    close_overlay(win)
    return
  end

  local total = vim.api.nvim_buf_line_count(buf)
  if total == 0 then
    close_overlay(win)
    return
  end

  local upto = math.min(n, total)
  local header_lines = vim.api.nvim_buf_get_lines(buf, 0, upto, false)

  local info = vim.fn.getwininfo(win)[1]
  local col_off = (info and info.textoff) or 0
  local text_w  = math.max(1, ((info and info.width) or vim.api.nvim_win_get_width(win)) - col_off)

  local ov = ensure_overlay(win, upto, col_off, text_w)

  vim.api.nvim_buf_set_option(ov.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, header_lines)
  vim.api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

  for i, line in ipairs(header_lines) do
    local ranges = field_ranges(line, sep, M.config.max_columns)
    for col_idx, r in ipairs(ranges) do
      local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
      local start_col, end_col = r[1], r[2]
      vim.api.nvim_buf_add_highlight(ov.buf, ns, group, i - 1, start_col, end_col)
      if col_idx < #ranges and end_col ~= -1 then
        vim.api.nvim_buf_add_highlight(ov.buf, ns, "CsvSep", i - 1, end_col, end_col + 1)
      end
    end
  end

  vim.api.nvim_buf_set_option(ov.buf, "modifiable", false)
end

-- Build the winbar string (buttons and right-aligned tag).
function M._winbar_for(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) or not M.config.use_winbar_controls then
    return ""
  end
  local n = get_header_n(buf)
  local left
  if mouse_supports_clicks() then
    left = table.concat({
      "%#Title#CSV hdr:%* ",
      "%@v:lua.require'csvcols'._click_dec@[-]%X ",
      "%#Title#", tostring(n), "%* ",
      "%@v:lua.require'csvcols'._click_inc@[+ ]%X",
      "%@v:lua.require'csvcols'._click_toggle_clean@[⯈]%X",
    })
  else
    left = table.concat({
      "%#Title#CSV hdr:%* ",
      "%#Title#", tostring(n), "%* ",
      "[⯈]",
    })
  end
  local right = "%=%#Comment#  csvcols%*"
  return left .. right
end

function M._click_inc(_, _, _, _)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, 1)
  M.refresh(win)
end

function M._click_dec(_, _, _, _)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then return end
  inc_header_n(buf, -1)
  M.refresh(win)
end

-- ==========================
-- Clean-view implementation
-- ==========================

-- Compute column widths (whole file or visible lines).
local function compute_column_widths_for(buf, sep, top, bottom, full_scan)
  local widths = {}
  local max_cols = M.config.max_columns or 64

  local start_idx = 0
  local end_idx   = vim.api.nvim_buf_line_count(buf)

  if not full_scan then
    start_idx = math.max(0, top)
    end_idx   = math.max(start_idx, bottom)
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_idx, end_idx, false)
  for _, line in ipairs(lines) do
    local ranges = field_ranges(line, sep, max_cols)
    for col_idx, r in ipairs(ranges) do
      local s, e = r[1], r[2]
      local cell = (e == -1) and line:sub(s + 1) or line:sub(s + 1, e)
      cell = cell:gsub('^%s*', ''):gsub('%s*$', '')
      if cell:sub(1,1) == '"' and cell:sub(-1) == '"' then
        cell = cell:sub(2, -2)
      end
      local w = vim.fn.strdisplaywidth(cell) or #cell
      widths[col_idx] = math.max(widths[col_idx] or 0, w)
    end
  end
  return widths
end

-- Build padded lines from raw lines and widths; also return per-column visual starts.
local function build_padded_lines(lines, sep, widths)
  local result = {}
  local starts_per_line = {} -- { {start_col0,start_col1,...}, ... } for cursor mapping
  local max_cols = #widths
  for _, line in ipairs(lines) do
    local ranges = field_ranges(line, sep, max_cols)
    local parts = {}
    local starts = {}
    local x = 0
    for col_idx, r in ipairs(ranges) do
      starts[col_idx] = x
      local s, e = r[1], r[2]
      local cell = (e == -1) and line:sub(s + 1) or line:sub(s + 1, e)
      cell = cell:gsub('^%s*', ''):gsub('%s*$', '')
      if cell:sub(1,1) == '"' and cell:sub(-1) == '"' then
        cell = cell:sub(2, -2)
      end
      local w = vim.fn.strdisplaywidth(cell) or #cell
      local pad = (widths[col_idx] or 0) - w
      parts[#parts+1] = cell .. string.rep(' ', pad + 2) -- 2 spaces between columns
      x = x + w + pad + 2
    end
    result[#result+1] = table.concat(parts)
    starts_per_line[#starts_per_line+1] = starts
  end
  return result, starts_per_line
end

-- Determine which CSV column the cursor is on (0-based index) for a given line.
local function cursor_col_index(line, sep, max_cols, cur_byte_col0)
  local ranges = field_ranges(line, sep, max_cols)
  for idx, r in ipairs(ranges) do
    local s, e = r[1], r[2]
    local stop = (e == -1) and math.huge or e
    if cur_byte_col0 >= s and cur_byte_col0 <= stop then
      return idx
    end
  end
  return 1
end

-- Render / update the clean-view overlay for the current window.
local function render_clean_view(win, buf, sep, top, bottom)
  local info = vim.fn.getwininfo(win)[1]
  local col_off = (info and info.textoff) or 0
  local text_w  = math.max(1, ((info and info.width) or vim.api.nvim_win_get_width(win)) - col_off)
  local text_h  = math.max(1, vim.api.nvim_win_get_height(win))

  local st = bufstate(buf)
  st.clean_active = true

  -- Widths: either whole file (cached per changedtick) or visible region each time
  local full = M.config.clean_view_full_scan
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  if full then
    if not st.clean_widths or st.clean_widths_tick ~= changedtick then
      st.clean_widths = compute_column_widths_for(buf, sep, top, bottom, true)
      st.clean_widths_tick = changedtick
    end
  else
    st.clean_widths = compute_column_widths_for(buf, sep, top, bottom, false)
    st.clean_widths_tick = changedtick
  end
  local widths = st.clean_widths or {}

  -- Visible lines -> padded copy
  local lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)
  local padded, starts_per_line = build_padded_lines(lines, sep, widths)

  -- Open/resize overlay
  local ov = ensure_clean_overlay(win, text_h, col_off, text_w)

  -- Fill and colorize
  vim.api.nvim_buf_set_option(ov.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, padded)
  vim.api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

  for i, line in ipairs(lines) do
    local ranges = field_ranges(line, sep, M.config.max_columns)
    for col_idx, r in ipairs(ranges) do
      local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
      local start_x = (starts_per_line[i] and starts_per_line[i][col_idx]) or 0
      local next_start = (starts_per_line[i] and starts_per_line[i][col_idx + 1])
      local end_x = (next_start and next_start) or -1
      vim.api.nvim_buf_add_highlight(ov.buf, ns, group, i - 1, start_x, end_x)
    end
  end

  vim.api.nvim_buf_set_option(ov.buf, "modifiable", false)

  -- Mirror cursor into clean view (start of the current cell)
  local cur = vim.api.nvim_win_get_cursor(win)   -- {line1, col0}
  local cur_row0 = cur[1] - 1
  local cur_col0 = cur[2]
  if cur_row0 >= top and cur_row0 < bottom then
    local line = vim.api.nvim_buf_get_lines(buf, cur_row0, cur_row0 + 1, false)[1] or ""
    local col_idx = cursor_col_index(line, sep, M.config.max_columns, cur_col0)
    local rel = cur_row0 - top
    local sx = (starts_per_line[rel + 1] and starts_per_line[rel + 1][col_idx]) or 0
    pcall(vim.api.nvim_win_set_cursor, ov.win, { rel + 1, sx })
  end
end

-- main refresh
function M.refresh(win)
  win = (win ~= 0 and win) or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)

  if not is_csv_buf(buf) then
    close_overlay(win)
    close_clean_overlay(win)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    -- Clear our winbar if present
    if M.config.use_winbar_controls then
      local cur = vim.wo[win].winbar or ""
      if cur:match("csvcols") then
        pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
      end
    end
    return
  end

  local sep = get_sep(buf)
  local top = vim.fn.line("w0") - 1
  local bottom = vim.fn.line("w$")

  if bottom <= top then
    close_overlay(win)
    close_clean_overlay(win)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    if M.config.use_winbar_controls then
      pcall(vim.api.nvim_set_option_value, "winbar", M._winbar_for(win), { scope = "local", win = win })
    end
    return
  end

  -- recolor visible columns (original behavior)
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

  -- sticky header (float, aligned via textoff)
  render_header(win, buf, sep, top)

  -- clean-view (if active) – scrolls and mirrors cursor
  local st = bufstate(buf)
  if st.clean_active then
    render_clean_view(win, buf, sep, top, bottom)
  else
    close_clean_overlay(win)
  end

  -- winbar controls
  if M.config.use_winbar_controls then
    pcall(vim.api.nvim_set_option_value, "winbar", M._winbar_for(win), { scope = "local", win = win })
  end
end

-- Toggle clean view
function M.toggle_clean_view()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_csv_buf(buf) then
    vim.notify("[csvcols] Clean view is only available for CSV/TSV buffers", vim.log.levels.WARN)
    return
  end
  local st = bufstate(buf)
  st.clean_active = not st.clean_active
  if not st.clean_active then
    close_clean_overlay(win)
  end
  M.refresh(win)
end

function M._click_toggle_clean(_, _, _, _)
  M.toggle_clean_view()
end

-- setup
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  set_default_hl()

  -- recreate augroup on every setup
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
  local augroup = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })

  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI", "InsertLeave", "WinScrolled", "CursorMoved", "WinResized" },
    {
      group = augroup,
      pattern = "*",  -- run everywhere; refresh() bails for non-CSV
      callback = function() M.refresh(0) end,
      desc = "csvcols: colorize CSV/TSV columns, sticky header & clean-view",
    }
  )

  -- On WinClosed, <amatch> is the closing window id as a string
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      local w = tonumber(args.match)
      if w then close_overlay(w); close_clean_overlay(w) end
    end,
    desc = "csvcols: cleanup overlays on window close",
  })

  -- Commands
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

  vim.api.nvim_create_user_command("CsvColsRefresh", function() M.refresh(0) end,
    { desc = "Recolorize visible CSV/TSV columns in current buffer" })

  vim.api.nvim_create_user_command("CsvColsClear", function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    local w = vim.api.nvim_get_current_win()
    close_overlay(w); close_clean_overlay(w)
  end, { desc = "Clear csvcols highlights/header/clean-view in current buffer" })

  -- Clean-view: command and default keymap
  vim.api.nvim_create_user_command("CsvCleanToggle", function()
    M.toggle_clean_view()
  end, { desc = "Toggle clean spreadsheet-like view for current CSV/TSV buffer" })

  if M.config.keymap ~= false then
    vim.keymap.set('n', 'gC', function() require('csvcols').toggle_clean_view() end,
      { desc = 'csvcols: toggle clean view' })
  end
end

return M

