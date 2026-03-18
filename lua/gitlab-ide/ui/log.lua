-- Job log view for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")
local icons = require("gitlab-ide.ui.icons")

-- Namespace for log ANSI highlights
local log_ns = vim.api.nvim_create_namespace("gitlab_ide_log")

-- ANSI foreground color codes -> hex (Tomorrow Night palette, dark-theme friendly)
local ansi_fg_colors = {
	[30] = "#808080",
	[31] = "#cc6666",
	[32] = "#b5bd68",
	[33] = "#f0c674",
	[34] = "#81a2be",
	[35] = "#b294bb",
	[36] = "#8abeb7",
	[37] = "#c5c8c6",
	[90] = "#666666",
	[91] = "#ff7070",
	[92] = "#c5d16c",
	[93] = "#ffcc80",
	[94] = "#8bb8d4",
	[95] = "#c3a8cf",
	[96] = "#a0cfc9",
	[97] = "#e8e8e8",
}

-- Cache for lazily created ANSI highlight groups
local ansi_hl_cache = {}

--- Lazily create and cache a named highlight group for an ANSI SGR state
---@param fg_code number|nil ANSI foreground color code (30-37, 90-97), or nil
---@param bold boolean Whether bold is active
---@return string hl_group The highlight group name
local function get_ansi_hl(fg_code, bold)
	local key = tostring(fg_code or "nil") .. (bold and "_bold" or "")
	if ansi_hl_cache[key] then
		return ansi_hl_cache[key]
	end
	local name = "GitlabAnsi" .. (fg_code or "def") .. (bold and "Bold" or "")
	local attrs = {}
	if fg_code and ansi_fg_colors[fg_code] then
		attrs.fg = ansi_fg_colors[fg_code]
	end
	if bold then
		attrs.bold = true
	end
	vim.api.nvim_set_hl(0, name, attrs)
	ansi_hl_cache[key] = name
	return name
end

--- Parse SGR ANSI escape sequences from a single line
---@param raw_line string Raw line potentially containing ANSI codes
---@return string clean_text Line with all escape sequences removed
---@return table spans List of {col_start, col_end, hl} highlight spans
local function parse_sgr(raw_line)
	local clean_parts = {}
	local spans = {}
	local col = 0
	local fg_code = nil
	local bold = false
	local span_start = 0
	local len = #raw_line
	local i = 1
	while i <= len do
		local byte = raw_line:sub(i, i)
		if byte == "\27" and raw_line:sub(i + 1, i + 1) == "[" then
			local j = i + 2
			while j <= len and not raw_line:sub(j, j):match("[A-Za-z]") do
				j = j + 1
			end
			if j > len then
				break
			end
			local final = raw_line:sub(j, j)
			local params_str = raw_line:sub(i + 2, j - 1)
			if final == "m" then
				-- Flush the current span before changing state
				if (fg_code ~= nil or bold) and col > span_start then
					table.insert(spans, {
						col_start = span_start,
						col_end = col,
						hl = get_ansi_hl(fg_code, bold),
					})
				end
				-- Parse new state
				if params_str == "" or params_str == "0" then
					fg_code = nil
					bold = false
				else
					for code_str in params_str:gmatch("[^;]+") do
						local code = tonumber(code_str)
						if code == 0 then
							fg_code = nil
							bold = false
						elseif code == 1 then
							bold = true
						elseif (code >= 30 and code <= 37) or (code >= 90 and code <= 97) then
							fg_code = code
						end
					end
				end
				span_start = col
			end
			i = j + 1
		else
			table.insert(clean_parts, byte)
			col = col + 1
			i = i + 1
		end
	end
	-- Flush the final span
	if (fg_code ~= nil or bold) and col > span_start then
		table.insert(spans, {
			col_start = span_start,
			col_end = col,
			hl = get_ansi_hl(fg_code, bold),
		})
	end

	return table.concat(clean_parts), spans
end

--- Render a raw log text (with ANSI codes) into a buffer with proper highlights
---@param buf number Buffer ID
---@param ns_id number Namespace ID for highlights
---@param text string Raw log text with ANSI escape sequences
local function render_log_to_buf(buf, ns_id, text)
	-- Normalize line endings
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	local raw_lines = vim.split(text, "\n", { plain = true, trimempty = false })

	local clean_lines = {}
	local all_spans = {} -- list of {line_idx (0-based), col_start, col_end, hl}

	for idx, raw_line in ipairs(raw_lines) do
		local line_idx = idx - 1
		-- Check for GitLab section markers (before stripping ANSI)
		local section_name = raw_line:match("^section_start:%d+:([^\r\n\27]+)")
		if not section_name then
			-- Also check without ANSI prefix
			local stripped_check = raw_line:gsub("\27%[[%d;]*[A-Za-z]", "")
			section_name = stripped_check:match("^section_start:%d+:([^\r\n]+)")
		end
		local section_end = raw_line:match("^section_end:") or raw_line:gsub("\27%[[%d;]*[A-Za-z]", ""):match("^section_end:")

		if section_name then
			-- Replace underscores with spaces and format as header
			local display = "▶  " .. section_name:gsub("_", " "):gsub("%[0K", ""):gsub("%[%d*[A-Za-z]", "")
			table.insert(clean_lines, display)
			table.insert(all_spans, {
				line_idx = line_idx,
				col_start = 0,
				col_end = #display,
				hl = "DiagnosticInfo",
			})
		elseif section_end then
			table.insert(clean_lines, "")
		else
			local clean_text, spans = parse_sgr(raw_line)
			table.insert(clean_lines, clean_text)
			for _, span in ipairs(spans) do
				table.insert(all_spans, {
					line_idx = line_idx,
					col_start = span.col_start,
					col_end = span.col_end,
					hl = span.hl,
				})
			end
		end
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, clean_lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, span in ipairs(all_spans) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, span.hl, span.line_idx, span.col_start, span.col_end)
	end
end

--- Set up keybindings for the log view buffer
---@param buf number Buffer ID
---@param state table UI state reference
---@param close_fn function Function to close the entire UI
---@param reopen_fn function Function to reopen pipeline view
local function setup_log_keymaps(buf, state, close_fn, reopen_fn)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Back to pipeline view
	vim.keymap.set("n", "q", function()
		M.close(state, reopen_fn)
	end, opts)
	vim.keymap.set("n", "<BS>", function()
		M.close(state, reopen_fn)
	end, opts)

	-- Full close (exit everything)
	vim.keymap.set("n", "<Esc>", function()
		close_fn()
	end, opts)

	-- Manual log refresh
	vim.keymap.set("n", "r", function()
		if not state.log_state or not state.api_context then
			return
		end
		local job = state.log_state.job
		local log_buf = state.log_state.buffer
		local log_win = state.log_state.window
		local ctx = state.api_context
		api.fetch_job_log(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err, log_text)
			if not state.log_state or state.log_state.buffer ~= log_buf then
				return
			end
			if err then
				vim.notify("Log refresh failed: " .. err, vim.log.levels.ERROR)
				return
			end
			if vim.api.nvim_buf_is_valid(log_buf) then
				render_log_to_buf(log_buf, log_ns, log_text)
				if vim.api.nvim_win_is_valid(log_win) then
					local line_count = vim.api.nvim_buf_line_count(log_buf)
					vim.api.nvim_win_set_cursor(log_win, { math.max(1, line_count), 0 })
				end
			end
		end)
	end, opts)

	-- Open job URL in browser
	vim.keymap.set("n", "o", function()
		if not state.log_state or not state.api_context then
			return
		end
		local job = state.log_state.job
		if job and job.webPath then
			vim.ui.open(state.api_context.gitlab_url .. job.webPath)
		end
	end, opts)
end

--- Open the log view for a job (drill-down from pipeline view)
---@param job table Job data from the pipeline
---@param state table UI state reference
---@param close_pipeline_windows_fn function Function to close pipeline windows
---@param close_fn function Function to close the entire UI
---@param reopen_fn function Function to reopen pipeline view after closing log
function M.open(job, state, close_pipeline_windows_fn, close_fn, reopen_fn)
	if not state.api_context then
		vim.notify("API context not available", vim.log.levels.ERROR)
		return
	end

	-- Close pipeline windows
	close_pipeline_windows_fn()

	state.view = "log"

	-- Calculate dimensions (~85% of editor)
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.floor(editor_width * 0.85)
	local height = math.floor(editor_height * 0.85)
	local col = math.floor((editor_width - width) / 2)
	local row = math.floor((editor_height - height) / 2)

	-- Create log buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)

	-- Create log window
	local job_icon = icons.get_icon(job.status)
	local title = string.format(" %s %s [%s] ", job_icon, job.name, job.status)
	local footer = " q:back r:refresh Esc:close "
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})

	vim.api.nvim_win_set_option(win, "wrap", true)

	state.log_state = {
		window = win,
		buffer = buf,
		job = job,
		timer = nil,
	}

	-- Show loading placeholder
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading job log..." })

	-- Set up log keymaps
	setup_log_keymaps(buf, state, close_fn, reopen_fn)

	-- Fetch and display log
	local function fetch_and_display_log()
		local ctx = state.api_context
		api.fetch_job_log(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err, log_text)
			if not state.log_state or state.log_state.buffer ~= buf then
				return -- View was closed while fetching
			end
			if err then
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_set_option(buf, "modifiable", true)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error fetching log: " .. err })
					vim.api.nvim_buf_set_option(buf, "modifiable", false)
				end
				return
			end

			if vim.api.nvim_buf_is_valid(buf) then
				render_log_to_buf(buf, log_ns, log_text)

				-- Scroll to bottom
				if vim.api.nvim_win_is_valid(win) then
					local line_count = vim.api.nvim_buf_line_count(buf)
					vim.api.nvim_win_set_cursor(win, { math.max(1, line_count), 0 })
				end
			end
		end)
	end

	fetch_and_display_log()

	-- Auto-refresh for running/pending jobs
	if job.status == "RUNNING" or job.status == "PENDING" then
		local timer = vim.uv.new_timer()
		state.log_state.timer = timer
		timer:start(
			5000,
			5000,
			vim.schedule_wrap(function()
				if not state.log_state or state.log_state.buffer ~= buf then
					timer:stop()
					timer:close()
					return
				end
				fetch_and_display_log()
			end)
		)
	end
end

--- Close the log view and return to the pipeline view
---@param state table UI state reference
---@param reopen_fn function|nil Optional function to reopen pipeline view
function M.close(state, reopen_fn)
	if state.log_state then
		if state.log_state.timer then
			state.log_state.timer:stop()
			state.log_state.timer:close()
			state.log_state.timer = nil
		end
		if state.log_state.window and vim.api.nvim_win_is_valid(state.log_state.window) then
			vim.api.nvim_win_close(state.log_state.window, true)
		end
		if state.log_state.buffer and vim.api.nvim_buf_is_valid(state.log_state.buffer) then
			vim.api.nvim_buf_delete(state.log_state.buffer, { force = true })
		end
		state.log_state = nil
	end

	state.view = "pipeline"

	-- Reopen pipeline view
	if reopen_fn then
		reopen_fn()
	end
end

return M
