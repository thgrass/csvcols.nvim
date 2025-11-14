-- csvcols/init.lua
-- CSV/TSV column coloring + sticky header + clean-view (tabular) overlay.
-- Sticky header is a per-window floating overlay at row 0.
-- Clean-view is another overlay that renders a padded, spreadsheet-like view
-- that scrolls in sync with the main window and mirrors the cursor position.

local M            = {}

-- Namespaces
local ns           = vim.api.nvim_create_namespace("csvcols")        -- column hl (main buf and overlays)
local header_ns    = vim.api.nvim_create_namespace("csvcols_header") -- (kept for safety)

-- Augroup name (setup recreates it each time to avoid dupes)
local AUGROUP_NAME = "csvcols_autocmds"

-- Config (defaults)
M.config           = {
	colors                  = {
		"#2e7d32", "#1565c0", "#ad1457", "#ef6c00", "#6a1b9a",
		"#00838f", "#827717", "#441fa2", "#37474f", "#558b2f",
		"#c62828", "#283593", "#00897b", "#5d4037", "#1976d2",
	},
	mode                    = "bg", -- "bg" or "fg"
	max_columns             = 128,
	patterns                = { "*.csv", "*.tsv" },
	filetypes               = { "csv", "tsv" },

	default_header_lines    = 1, -- sticky header ON by default
	use_winbar_controls     = true, -- show [-] n [+] buttons in winbar

	-- Clean-view settings
	-- true: compute column widths from whole file; false: from visible region (faster for huge files)
	clean_view_full_scan    = false,

	-- Default keymap for clean-view toggle (gC). Set to false to disable.
	keymap                  = true,

	-- autodetection of separator
	auto_detect_separator   = true, -- ON by default
	detect_candidates       = { "\t", ",", ";", "|" },
	detect_max_lines        = 200, -- read at most this many lines
	detect_nonempty_limit   = 10, -- stop after this many non-empty lines

	-- autodetection for arbitrary buffers (if this plugin should turn itself on)
	auto_enable_any_buffer  = true, -- ON by default
	auto_enable_num_columns = 3, -- N
	auto_enable_agree_level = 0.7, -- % of sampled non-empty lines that must have >= N columns

	-- auto-enable clean-view mode
	auto_enable_clean_view  = false, -- OFF by default
}

-- per-buffer state (weak keys)
M._state           = setmetatable({}, { __mode = "k" })
local function bufstate(buf)
	local st = M._state[buf]
	if not st then
		st = {}; M._state[buf] = st
	end
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
	col_off  = col_off or 0
	width    = math.max(1, width or 1)

	if ov and ov.win and vim.api.nvim_win_is_valid(ov.win) then
		pcall(vim.api.nvim_win_set_config, ov.win, {
			relative = "win",
			win = win,
			row = 0,
			col = col_off,
			width = width,
			height = height,
			focusable = false,
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
	pcall(vim.api.nvim_set_option_value, "wrap", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "number", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = float })
	pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = float })

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

local function ensure_default_clean_view(buf)
	local st = bufstate(buf)
	if st.clean_active == nil then
		st.clean_active = true -- default ON; user can toggle later
	end
end

-- Enable/restore horizontal panning so cursor can move beyond EOL in clean-view.
local function apply_clean_scroll_opts(win, enable)
	local buf = vim.api.nvim_win_get_buf(win)
	local st  = bufstate(buf)

	-- set the scroll_opts
	if enable then
		if not st._saved_scroll then
			st._saved_scroll = {
				wrap        = vim.api.nvim_get_option_value("wrap", { win = win }),
				virtualedit = vim.api.nvim_get_option_value("virtualedit", { win = win }),
			}
		end

		-- these are per-window, safe to tweak
		pcall(vim.api.nvim_set_option_value, "wrap", false, { win = win })
		pcall(vim.api.nvim_set_option_value, "virtualedit", "all", { win = win })
	else
		local sv = st._saved_scroll
		if sv then
			pcall(vim.api.nvim_set_option_value, "wrap", sv.wrap, { win = win })
			pcall(vim.api.nvim_set_option_value, "virtualedit", sv.virtualedit, { win = win })
			st._saved_scroll = nil
		end
	end
end

-- Ensure clean-view float exists over the text area
local function ensure_clean_overlay(win, height, col_off, width)
	local ov = clean_ov[win]
	col_off  = col_off or 0
	width    = math.max(1, width or 1)

	if ov and ov.win and vim.api.nvim_win_is_valid(ov.win) then
		pcall(vim.api.nvim_win_set_config, ov.win, {
			relative = "win",
			win = win,
			row = 0, -- full text area (header sits above with higher zindex)
			col = col_off,
			width = width,
			height = height,
			zindex = 40, -- below header overlay
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
		focusable = false, -- behaves like viewer; we mirror cursor
		style = "minimal",
		noautocmd = true,
		zindex = 40,
	})

	-- minimal UI on clean overlay
	pcall(vim.api.nvim_set_option_value, "wrap", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "number", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = float })
	pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = float })
	pcall(vim.api.nvim_set_option_value, "foldcolumn", "0", { win = float })

	-- Inherit tabstop from source buf (for any rendering that depends on it)
	local src_buf = vim.api.nvim_win_get_buf(win)
	local ok_ts, ts_val = pcall(vim.api.nvim_get_option_value, "tabstop", { buf = src_buf })
	if ok_ts then pcall(vim.api.nvim_set_option_value, "tabstop", ts_val, { buf = buf }) end

	clean_ov[win] = { win = float, buf = buf }
	return clean_ov[win]
end

-- Helpers for horizontal scrolling and slicing lines by display width.
-- Return the text offset (excluded columns) and the text area width for window 'win'.
local function win_text_area(win)
	local info    = vim.fn.getwininfo(win)[1]
	local col_off = (info and info.textoff) or 0
	local text_w  = math.max(1, ((info and info.width) or vim.api.nvim_win_get_width(win)) - col_off)
	return col_off, text_w
end

-- Return the leftmost display column of window 'win' (horizontal scroll).
local function win_leftcol(win)
	local v = vim.fn.winsaveview()
	return (v and v.leftcol) or 0
end

-- Slice a line by display columns [leftcol, leftcol+width) and return the
-- substring plus the byte offset into the original line.
local function slice_display(line, leftcol, width)
	if width <= 0 then return "", 0 end
	if not line or line == "" then return "", 0 end
	local disp = 0
	local i = 1
	while i <= #line and disp < leftcol do
		local ch = line:sub(i, i)
		disp = disp + (vim.fn.strdisplaywidth(ch) or 1)
		i = i + 1
	end
	local start_byte = i
	local j = i
	local target = leftcol + width
	while j <= #line and disp < target do
		local ch = line:sub(j, j)
		disp = disp + (vim.fn.strdisplaywidth(ch) or 1)
		j = j + 1
	end
	return line:sub(start_byte, j - 1), (start_byte - 1)
end

-- Add a one-line highlight via extmark for range [s_byte,e_byte] on row `row`
-- (handles end-of-line when e_byte == -1).
local function add_hl_line(buf, ns_id, hl_group, row, s_byte, e_byte)
	local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
	local line_len = #line
	local e
	if e_byte == -1 then
		e = line_len
	else
		e = math.min(e_byte, line_len)
	end
	local s = math.max(0, math.min(s_byte, line_len))
	-- Only place highlight if start < end
	if s >= e then return end
	vim.api.nvim_buf_set_extmark(buf, ns_id, row, s_byte, {
		end_row  = row,
		end_col  = e,
		hl_group = hl_group,
		hl_mode  = "combine",
	})
end

-- helpers
-- count nr of delimiters in a line
local function count_occ(line, delim)
	local _, c = line:gsub(delim, "")
	return c
end

-- Scan a small sample and pick the delimiter with the highest count.
local function detect_sep(buf)
	local total = vim.api.nvim_buf_line_count(buf)
	if total == 0 then return nil end

	local max_lines        = math.min((M.config.detect_max_lines or 200), total)
	local need_lines       = (M.config.detect_nonempty_limit or 10)
	local candidates       = (M.config.detect_candidates or { "\t", ",", ";", "|" })

	local counts, nonempty = {}, 0
	for _, d in ipairs(candidates) do counts[d] = 0 end

	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, max_lines, false)) do
		if line and line:match("%S") then
			for _, d in ipairs(candidates) do
				counts[d] = counts[d] + count_occ(line, d)
			end
			nonempty = nonempty + 1
			if nonempty >= need_lines then break end
		end
	end

	local best, bestc = nil, -1
	for d, c in pairs(counts) do
		if c > bestc then best, bestc = d, c end
	end
	return (bestc and bestc > 0) and best or nil
end

--- Check if a buffer should auto-enable based on column count
function M.should_auto_enable(bufnr)
	if not M.config.auto_enable_any_buffer then
		return false
	end

	bufnr           = bufnr or vim.api.nvim_get_current_buf()

	-- Get all lines in the buffer
	local lines     = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local non_empty = 0
	local agree     = 0

	for _, line in ipairs(lines) do
		-- Trim whitespace
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			non_empty = non_empty + 1

			-- Split by whitespace into "columns"
			local cols = vim.split(trimmed, "%s+", { trimempty = true })
			if #cols >= M.config.auto_enable_num_columns then
				agree = agree + 1
			end
		end
	end

	if non_empty == 0 then
		return false
	end

	local fraction = agree / non_empty
	return fraction >= M.config.auto_enable_agree_level
end

-- Heuristic: consider a buffer "probably delimited" if a good fraction of sampled
-- non-empty lines have at least N fields with the best delimiter.
local function is_probably_delimited(buf)
	local sep = detect_sep(buf)
	if not sep then return false, nil end

	local total = vim.api.nvim_buf_line_count(buf)
	if total == 0 then return false, nil end

	local lines           = vim.api.nvim_buf_get_lines(
		buf, 0, math.min((M.config.auto_enable_probe_lines or 200), total), false
	)

	local need_cols       = (M.config.auto_enable_min_columns or 2)
	local agree_ratio     = (M.config.auto_enable_min_agree or 0.7)
	local limit_nonempty  = (M.config.auto_enable_nonempty or 20)

	local nonempty, agree = 0, 0
	for _, line in ipairs(lines) do
		if line and line:match("%S") then
			nonempty = nonempty + 1
			local fields = 1
			local dc = count_occ(line, sep)
			if dc > 0 then fields = dc + 1 end
			if fields >= need_cols then agree = agree + 1 end
			if nonempty >= limit_nonempty then break end
		end
	end

	if nonempty == 0 then return false, nil end
	local ratio = agree / nonempty
	return (ratio >= agree_ratio), sep
end

local function is_csv_buf(buf)
	-- fast-path: explicit filetype or extension
	local ft = vim.bo[buf].filetype
	if ft == "csv" or ft == "tsv" then return true end
	local name = (vim.api.nvim_buf_get_name(buf) or ""):lower()
	if name:match("%.csv$") or name:match("%.tsv$") then return true end

	-- auto-enable for any buffer if enabled
	if M.should_auto_enable(buf) then
		local st = bufstate(buf)
		if st.auto_csvcols ~= nil then
			return st.auto_csvcols
		end
		local ok, sep = is_probably_delimited(buf)
		st.auto_csvcols = ok
		st.auto_sep = sep
		return ok
	end

	return false
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



-- determine the separator used in buf
local function get_sep(buf)
	local st = bufstate(buf)
	if st.auto_sep then
		return st.auto_sep
	end

	local ft = vim.bo[buf].filetype
	if ft == "tsv" then return "\t" end
	local name = (vim.api.nvim_buf_get_name(buf) or ""):lower()
	if name:match("%.tsv$") then return "\t" end

	-- Optional: content-sniff auto separator
	if M.config.auto_detect_separator then
		local guessed = detect_sep(buf)
		if guessed then return guessed end
	end

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

local function compute_column_widths_for(buf, sep, top, bottom, full_scan)
	local widths    = {}
	local max_cols  = M.config.max_columns or 64

	local start_idx = 0
	local end_idx   = vim.api.nvim_buf_line_count(buf)

	if not full_scan then
		start_idx = math.max(0, top or 0)
		end_idx   = math.max(start_idx, bottom or start_idx)
	end

	local lines = vim.api.nvim_buf_get_lines(buf, start_idx, end_idx, false)
	for _, line in ipairs(lines) do
		local ranges = field_ranges(line, sep, max_cols)
		for col_idx, r in ipairs(ranges) do
			local s, e = r[1], r[2]
			local cell = (e == -1) and line:sub(s + 1) or line:sub(s + 1, e)

			-- trim spaces
			cell = cell:gsub("^%s*", ""):gsub("%s*$", "")

			-- unquote RFC-4180 style quoted fields
			if cell:sub(1, 1) == '"' and cell:sub(-1) == '"' then
				cell = cell:sub(2, -2)
				cell = cell:gsub('""', '"')
			end

			local w = vim.fn.strdisplaywidth(cell) or #cell
			widths[col_idx] = math.max(widths[col_idx] or 0, w)
		end
	end
	return widths
end

local function build_padded_lines(lines, sep, widths)
	local result = {}
	local starts_per_line = {} -- { {start_col0,start_col1,...}, ... }
	local max_cols = math.max(#widths, 1)
	local gap = 2       -- spaces between columns

	for _, line in ipairs(lines) do
		local ranges = field_ranges(line, sep, max_cols)
		local parts = {}
		local starts = {}
		local x = 0

		for col_idx, r in ipairs(ranges) do
			starts[col_idx] = x
			local s, e = r[1], r[2]
			local cell = (e == -1) and line:sub(s + 1) or line:sub(s + 1, e)

			-- trim + unquote
			cell = cell:gsub("^%s*", ""):gsub("%s*$", "")
			if cell:sub(1, 1) == '"' and cell:sub(-1) == '"' then
				cell = cell:sub(2, -2)
				cell = cell:gsub('""', '"')
			end

			local disp        = vim.fn.strdisplaywidth(cell) or #cell
			local pad         = math.max(0, (widths[col_idx] or 0) - disp)
			parts[#parts + 1] = cell .. string.rep(" ", pad + gap)

			-- advance x by *byte* length + pad + gap (consistent with use in extmarks)
			x                 = x + #cell + pad + gap
		end

		local padded = table.concat(parts)
		result[#result + 1] = padded
		starts_per_line[#starts_per_line + 1] = starts
	end

	return result, starts_per_line
end

-- Render sticky header, aligned via textoff, with horizontal scrolling support.
-- Render sticky header, aligned via textoff, with horizontal scrolling support.
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

	-- Source header lines
	local upto            = math.min(n, total)
	local header_lines    = vim.api.nvim_buf_get_lines(buf, 0, upto, false)

	-- Window geometry and horizontal scroll
	local col_off, text_w = win_text_area(win)
	local left            = win_leftcol(win)

	-- Ensure/resize overlay
	local ov              = ensure_overlay(win, upto, col_off, text_w)
	vim.api.nvim_set_option_value("modifiable", true, { buf = ov.buf })
	vim.api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

	local st = bufstate(buf)

	if st.clean_active then
		----------------------------------------------------------------
		-- CLEAN VIEW: use same column widths as body (if available)
		----------------------------------------------------------------
		local widths = st.clean_widths_merged or st.clean_widths or {}

		-- Fallback: compute widths if nothing is cached yet
		if (not widths or #widths == 0) then
			local changedtick = vim.api.nvim_buf_get_changedtick(buf)
			if not st.clean_widths or st.clean_widths_tick ~= changedtick then
				st.clean_widths      = compute_column_widths_for(buf, sep, 0, total, true)
				st.clean_widths_tick = changedtick
			end
			widths = st.clean_widths or {}
		end

		-- Build padded header lines and per-column starts
		local padded, starts_per_line = build_padded_lines(header_lines, sep, widths)

		-- Slice each padded header line to visible region
		local sliced                  = {}
		local slice_offsets           = {}
		for i, pl in ipairs(padded) do
			local s_txt, s_off = slice_display(pl, left, text_w)
			sliced[i]          = s_txt
			slice_offsets[i]   = s_off
		end
		vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, sliced)

		-- Colorize by column using padded starts and slice offsets
		for i, _ in ipairs(header_lines) do
			local starts   = starts_per_line[i] or {}
			local s_off    = slice_offsets[i] or 0
			local line_txt = sliced[i] or ""
			for col_idx = 1, #starts do
				local group      = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
				local sx         = (starts[col_idx] or 0) - s_off
				local next_start = starts[col_idx + 1]
				local nx         = (next_start and (next_start - s_off)) or -1
				if nx == -1 then
					if sx < #line_txt then
						add_hl_line(ov.buf, ns, group, i - 1, math.max(0, sx), -1)
					end
				else
					if nx > 0 and sx < #line_txt then
						add_hl_line(ov.buf, ns, group, i - 1, math.max(0, sx), math.max(0, nx))
					end
				end
			end
		end
	else
		----------------------------------------------------------------
		-- NORMAL VIEW: your original code, unchanged
		----------------------------------------------------------------
		local sliced        = {}
		local slice_offsets = {}
		for i, raw in ipairs(header_lines) do
			local s_txt, s_off = slice_display(raw, left, text_w)
			sliced[i]          = s_txt
			slice_offsets[i]   = s_off
		end
		vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, sliced)

		for i, raw in ipairs(header_lines) do
			local ranges = field_ranges(raw, sep, M.config.max_columns)
			local s_off  = slice_offsets[i] or 0
			local vis    = sliced[i] or ""
			for col_idx, r in ipairs(ranges) do
				local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
				local s, e  = r[1], r[2]
				local vs    = s - s_off
				local ve    = (e == -1) and -1 or (e - s_off)

				if ve == -1 then
					if vs < #vis then
						add_hl_line(ov.buf, ns, group, i - 1, math.max(0, vs), -1)
					end
				else
					if ve > 0 and vs < #vis then
						add_hl_line(ov.buf, ns, group, i - 1, math.max(0, vs), math.max(0, ve))
					end
				end

				-- highlight separators if visible
				if col_idx < #ranges and e ~= -1 then
					local sep_col = e - s_off
					if sep_col >= 0 and sep_col < #vis then
						vim.api.nvim_buf_set_extmark(ov.buf, ns, i - 1, sep_col, {
							end_row  = i - 1,
							end_col  = sep_col + 1,
							hl_group = "CsvSep",
							hl_mode  = "combine",
						})
					end
				end
			end
		end
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = ov.buf })
end

-- Build the winbar string (buttons and right-aligned tag).
function M._winbar_for(win)
	local buf = vim.api.nvim_win_get_buf(win)
	if not is_csv_buf(buf) or not M.config.use_winbar_controls then
		return ""
	end
	local n = get_header_n(buf)
	local left, right

	if mouse_supports_clicks() then
		left = table.concat({
			"%#Title#CSV hdr:%* ",
			"%@v:lua.require'csvcols'._click_dec@[-]%X ",
			"%#Title#", tostring(n), "%* ",
			"%@v:lua.require'csvcols'._click_inc@[+]%X",
		})
		right = table.concat({
			"%@v:lua.require'csvcols'._click_toggle_clean@[⯈]%X",
			"%=%#Comment#  csvcols%*",
		})
	else
		left = table.concat({
			"%#Title#CSV hdr:%* ",
			"%#Title#", tostring(n), "%* ",
		})
		right = "%=%#Comment#  csvcols%*"
	end
	return table.concat({ left, right })
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

function M._click_toggle_clean(_, _, _, _)
	M.toggle_clean_view()
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
	-- window geometry + horizontal scroll
	local col_off, text_w = win_text_area(win)
	local left            = win_leftcol(win)
	local text_h          = math.max(1, vim.api.nvim_win_get_height(win))

	local st              = bufstate(buf)
	st.clean_active       = true

	-- widths: whole file (cached) or region
	local full            = M.config.clean_view_full_scan
	local changedtick     = vim.api.nvim_buf_get_changedtick(buf)
	if full then
		if not st.clean_widths or st.clean_widths_tick ~= changedtick then
			st.clean_widths      = compute_column_widths_for(buf, sep, top, bottom, true)
			st.clean_widths_tick = changedtick
		end
	else
		st.clean_widths      = compute_column_widths_for(buf, sep, top, bottom, false)
		st.clean_widths_tick = changedtick
	end
	local body_widths   = st.clean_widths or {}

	local header_widths = {}
	local header_n      = get_header_n(buf) -- number of header lines from top

	if header_n and header_n > 0 then
		-- iterate header lines 0 .. header_n-1
		for lnum = 0, header_n - 1 do
			local line = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
			if not line then
				break
			end

			-- only consider header lines that actually contain the separator
			if line:find(sep, 1, true) then
				-- compute widths for THIS single header line
				local w = compute_column_widths_for(buf, sep, lnum, lnum + 1, false)
				for i, width in ipairs(w) do
					if width > (header_widths[i] or 0) then
						header_widths[i] = width
					end
				end
			end
		end
	end

	-- merge body and header widths
	local widths   = {}
	local max_cols = math.max(#body_widths, #header_widths)
	for i = 1, max_cols do
		local wb = body_widths[i] or 0
		local wh = header_widths[i] or 0
		widths[i] = (wb > wh) and wb or wh
	end

	-- store for header renderer to reuse
	st.clean_widths_merged = widths

	-- visible source lines
	local src_lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)

	-- build padded lines + per-column starts in padded space, now using merged widths
	local padded, starts_per_line = build_padded_lines(src_lines, sep, widths)

	-- ensure/resize clean overlay to text area
	local ov = ensure_clean_overlay(win, text_h, col_off, text_w)

	-- ensure nowrap in both windows; we slice by win_leftcol(win)
	for _, w in ipairs({ win, ov.win }) do
		vim.api.nvim_set_option_value("wrap", false, { win = w })
	end

	-- slice padded lines to visible region [left, left+text_w)
	local sliced, slice_offsets = {}, {}
	for i, pl in ipairs(padded) do
		local s_txt, s_off = slice_display(pl, left, text_w)
		sliced[i]          = s_txt
		slice_offsets[i]   = s_off
	end

	-- fill buffer and colorize
	vim.api.nvim_set_option_value("modifiable", true, { buf = ov.buf })
	vim.api.nvim_buf_set_lines(ov.buf, 0, -1, false, sliced)
	vim.api.nvim_buf_clear_namespace(ov.buf, ns, 0, -1)

	for i = 1, #src_lines do
		local starts = starts_per_line[i] or {}
		local s_off  = slice_offsets[i] or 0
		local vis    = sliced[i] or ""

		for col_idx = 1, #starts do
			local group      = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
			local sx         = (starts[col_idx] or 0) - s_off
			local next_start = starts[col_idx + 1]
			local ex         = (next_start and (next_start - s_off)) or -1

			if ex == -1 then
				if sx < #vis then
					add_hl_line(ov.buf, ns, group, i - 1, math.max(0, sx), -1)
				end
			else
				if ex > 0 and sx < #vis then
					add_hl_line(ov.buf, ns, group, i - 1, math.max(0, sx), math.max(0, ex))
				end
			end
		end
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = ov.buf })

	-- Mirror cursor: jump to start of current cell in sliced padded space
	local cur = vim.api.nvim_win_get_cursor(win) -- {row1, col0}
	local cur_row0 = cur[1] - 1
	local cur_col0 = cur[2]
	if cur_row0 >= top and cur_row0 < bottom then
		local line    = vim.api.nvim_buf_get_lines(buf, cur_row0, cur_row0 + 1, false)[1] or ""
		local col_idx = cursor_col_index(line, sep, M.config.max_columns, cur_col0)
		local rel     = cur_row0 - top
		local sx      = (starts_per_line[rel + 1] and starts_per_line[rel + 1][col_idx]) or 0
		-- shift by slice offset so the cursor lands inside the visible slice
		local off     = slice_offsets[rel + 1] or 0
		local sx_vis  = math.max(0, sx - off)
		pcall(vim.api.nvim_win_set_cursor, ov.win, { rel + 1, sx_vis })
	end
end

-- main refresh
function M.refresh(win)
	win = (win ~= 0 and win) or vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_win_get_buf(win)

	if not is_csv_buf(buf) then
		close_overlay(win)
		close_clean_overlay(win)
		apply_clean_scroll_opts(win, false)
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

	-- recolor visible columns
	vim.api.nvim_buf_clear_namespace(buf, ns, top, bottom)
	local lines = vim.api.nvim_buf_get_lines(buf, top, bottom, false)
	for i, line in ipairs(lines) do
		local ranges = field_ranges(line, sep, M.config.max_columns)
		for col_idx, r in ipairs(ranges) do
			local group = ("CsvCol%d"):format(((col_idx - 1) % #M.config.colors) + 1)
			local start_col, end_col = r[1], r[2]
			vim.api.nvim_buf_set_extmark(buf, ns, top + i - 1, start_col,
				{
					end_row = top + i - 1,
					end_col = (end_col == -1 and #(vim.api.nvim_buf_get_lines(buf, top + i - 1, top + i, false)[1] or "") or end_col),

					hl_group =
					    group,

					hl_mode = "combine"
				})
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
	if st.clean_active then
		apply_clean_scroll_opts(win, true)
	else
		apply_clean_scroll_opts(win, false)
		close_clean_overlay(win)
	end
	M.refresh(win)
end

-- setup
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	set_default_hl()

	-- recreate augroup on every setup
	pcall(vim.api.nvim_del_augroup_by_name, AUGROUP_NAME)
	local augroup = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })

	vim.api.nvim_create_autocmd(
		{ "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI", "InsertLeave", "WinScrolled", "CursorMoved",
			"WinResized" },
		{
			group = augroup,
			pattern = "*", -- run everywhere; refresh() bails for non-CSV
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
			if w then
				close_overlay(w); close_clean_overlay(w)
			end
		end,
		desc = "csvcols: cleanup overlays on window close",
	})

	-- On opening new buf, start detection if buf is csv/tsv and turn on plugin if enabled
	-- (also turn on clean view mode when that is set)
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = augroup,
		pattern = "*",
		callback = function(args)
			local buf = args.buf
			local st  = bufstate(buf)

			-- (a) Prime autodiscovery cache if enabled
			if M.config.auto_enable_any_buffer and st.auto_csvcols == nil then
				local ok, sep = is_probably_delimited(buf)
				st.auto_csvcols, st.auto_sep = ok, sep
			end

			-- (b) If this buffer is either supported (csv/tsv) OR autodiscovered,
			--     and auto-clean is ON, default Clean View ON (once).
			local ft = vim.bo[buf].filetype
			local name = (vim.api.nvim_buf_get_name(buf) or ""):lower()
			local supported = (ft == "csv" or ft == "tsv" or name:match("%.csv$") or name:match("%.tsv$"))
			local looks_delimited = (st.auto_csvcols == true)

			if M.config.auto_enable_clean_view and (supported or looks_delimited) then
				ensure_default_clean_view(buf)
				-- immediate render if we just turned it on
				require("csvcols").refresh(0)
			end
		end,
		desc = "csvcols: default Clean View via existing toggles",
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

	-- "Clean-view" mode: command and default keymap
	vim.api.nvim_create_user_command("CsvCleanToggle", function()
		M.toggle_clean_view()
	end, { desc = "Toggle clean spreadsheet-like view for current CSV/TSV buffer" })

	-- Automatic separater detection toggle & on/offset
	vim.api.nvim_create_user_command("CsvAutoSepToggle", function()
		M.config.auto_detect_separator = not M.config.auto_detect_separator
		local state = M.config.auto_detect_separator and "ON" or "OFF"
		vim.notify("[csvcols] auto separator detection: " .. state)
		M.refresh(0)
	end, { desc = "Toggle automatic delimiter detection" })

	vim.api.nvim_create_user_command("CsvAutoSep", function(cmd)
		local arg = (cmd.args or ""):lower()
		if arg == "on" or arg == "1" or arg == "true" then
			M.config.auto_detect_separator = true
		elseif arg == "off" or arg == "0" or arg == "false" then
			M.config.auto_detect_separator = false
		else
			vim.notify("[csvcols] usage: :CsvAutoSep {on|off}", vim.log.levels.WARN)
			return
		end
		M.refresh(0)
	end, { nargs = 1, desc = "Enable/disable automatic delimiter detection" })

	-- Autodection for any buf
	vim.api.nvim_create_user_command("CsvAutoEnable", function(cmd)
		local arg = (cmd.args or ""):lower()
		if arg == "on" or arg == "1" or arg == "true" then
			M.config.auto_enable_any_buffer = true
		elseif arg == "off" or arg == "0" or arg == "false" then
			M.config.auto_enable_any_buffer = false
		else
			vim.notify("[csvcols] usage: :CsvAutoEnable {on|off}", vim.log.levels.WARN); return
		end
		-- clear per-buffer cache so we re-evaluate
		M._state = setmetatable({}, { __mode = "k" })
		M.refresh(0)
	end, { nargs = 1, desc = "Enable/disable auto CSV detection for any buffer" })

	-- Enable clean view mode as default
	vim.api.nvim_create_user_command("CsvAutoClean", function(cmd)
		local arg = (cmd.args or ""):lower()
		if arg == "on" or arg == "1" or arg == "true" then
			M.config.auto_enable_clean_view = true
		elseif arg == "off" or arg == "0" or arg == "false" then
			M.config.auto_enable_clean_view = false
		else
			vim.notify("[csvcols] usage: :CsvAutoClean {on|off}", vim.log.levels.WARN); return
		end
		-- existing buffers already marked can flip their overlay on next refresh
		M.refresh(0)
	end, { nargs = 1, desc = "Enable/disable auto Clean View when auto-enabling" })


	if M.config.keymap ~= false then
		vim.keymap.set('n', 'gC', function() require('csvcols').toggle_clean_view() end,
			{ desc = 'csvcols: toggle clean view' })
	end
end

return M
