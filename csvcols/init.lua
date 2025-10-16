-- csvcols/init.lua
local M = {}

local ns = vim.api.nvim_create_namespace("csvcols")
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
}

local function set_default_hl()
  for i, color in ipairs(M.config.colors) do
    local def = (M.config.mode == "bg") and { bg = color } or { fg = color }
    def.bold = false
    vim.api.nvim_set_hl(0, ("CsvCol%d"):format(i), def)
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

function M.refresh(win)
  win = win ~= 0 and win or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)

  -- Quick filter: only run on csv/tsv buffers
  local ft = vim.bo[buf].filetype
  local matches_ft = false
  for _, f in ipairs(M.config.filetypes) do
    if ft == f then matches_ft = true; break end
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local matches_pat = name:match("%.csv$") or name:match("%.tsv$")
  if not (matches_ft or matches_pat) then return end

  local sep = get_sep(buf)
  local top = vim.fn.line("w0") - 1      -- 0-based top line in window
  local bottom = vim.fn.line("w$")       -- 1-based bottom line (exclusive in clear)
  if bottom <= top then return end

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
      desc = "csvcols: colorize CSV/TSV columns",
    }
  )

  vim.api.nvim_create_user_command("CsvColsRefresh", function() M.refresh(0) end, { desc = "Recolorize visible CSV/TSV columns in current buffer" })
  vim.api.nvim_create_user_command("CsvColsClear", function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end, { desc = "Clear csvcols highlights in current buffer" })
end

return M

