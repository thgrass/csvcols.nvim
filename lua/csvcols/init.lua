-- csvcols/init.lua
-- CSV/TSV column coloring + sticky header.
-- Sticky header is rendered via a per-window floating overlay at row 0.
-- Buttons in the winbar adjust the number of header lines per buffer.
-- Alignment uses the window's text offset (line numbers/sign/fold) so headers line up.

local M = {}

-- Namespaces
local ns         = vim.api.nvim_create_namespace("csvcols")         -- column hl
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

-- floating overlay manager (per-window)
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

-- Ensure a float exists at row 0 with given width/height and left offset col_off
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
      zindex = 50,
    })
    ov.height = height
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
  -- minimal UI
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = float })
  pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = float })
  pcall(vim.api.nvim_set_option_value, "number", false, { win = float })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = float })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = float })
  pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = float })
  pcall(vim.api.nvim_set_option_value, "list", vim.api.nvim_get_option_value("list", { win = win }), { win = float })
  pcall(vim.api.nvim_set_option_value, "tabstop", vim.api.nvim_get_option_value("tabstop", { win = win }), { win = float })

  overlays[win] = { win = float, buf = buf, height = height }
  return overlays[win]
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

-- Render sticky header via a floating window pinned to row 0 of the target window.
-- Alignment is handled by anchoring the float at the window's text offset ("textoff").
local function render_header(win, buf, sep, top)
  local n = get_header_n(buf)

  -- No header or we're at the very top -> close overlay
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

  -- Get exact on-screen left offset for buffer text area (line numbers/sign/fold)
  local info = vim.fn.getwininfo(win)[1]
  local col_off = (info and info.textoff) or 0
  local text_w  = math.max(1, ((info and info.width) or vim.api.nvim_win_get_width(win)) - col_off)

  -- Create/resize overlay at correct horizontal offset
  local ov = ensure_overlay(win, upto, col_off, text_w)

  -- Fill overlay buffer and colorize columns
  vim.api.nvim_buf_set_option(ov.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, header_lines)
  vim.api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

  for i, line in ipairs(header_lines) do
    local ranges = field_ranges(line, sep, M.config.max_columns)
    for col_idx, r in ipairs(ranges) do
      local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
      local start_col, end_col = r[1], r[2]
      vim.api.nvim_buf_add_highlight(ov.buf, ns, group, i - 1, start_col, end_col)
      -- draw separator highlight if present
      if col_idx < #ranges and end_col ~= -1 then
        vim.api.nvim_buf_add_highlight(ov.buf, ns, "CsvSep", i - 1, end_col, end_col + 1)
      end
    end
  end

  vim.api.nvim_buf_set_option(ov.buf, "modifiable", false)
end

-- Build the winbar string (buttons and right-aligned tag).
-- NO string.format here, to avoid statusline '%' issues.
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
    })
  else
    left = table.concat({
      "%#Title#CSV hdr:%* ",
      "%#Title#", tostring(n), "%* ",
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
  pcall(vim.api.nvim_set_option_value, "winbar", M._winbar_for(win), { scope = "local", win = win })
end

-- main refresh
function M.refresh(win)
  win = (win ~= 0 and win) or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)

  if not is_csv_buf(buf) then
    close_overlay(win)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
    return
  end

  local sep = get_sep(buf)
  local top = vim.fn.line("w0") - 1
  local bottom = vim.fn.line("w$")

  if bottom <= top then
    close_overlay(win)
    vim.api.nvim_buf_clear_namespace(buf, header_ns, 0, -1)
    maybe_set_winbar(win)
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

  -- winbar controls
  maybe_set_winbar(win)
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
      desc = "csvcols: colorize CSV/TSV columns & sticky header (float)",
    }
  )

  -- On WinClosed, <amatch> is the closing window id as a string
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      local w = tonumber(args.match)
      if w then close_overlay(w) end
    end,
    desc = "csvcols: cleanup overlay on window close",
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
    close_overlay(w)
  end, { desc = "Clear csvcols highlights/header in current buffer" })
end

return M

