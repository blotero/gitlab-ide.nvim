-- Merge Request discussion threads UI for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")

local state = {
	threads_window = nil,
	threads_buffer = nil,
	input_window = nil,
	input_buffer = nil,
	discussions = {},
	expanded = {},
	line_to_discussion = {},
	api_context = nil,
	mr = nil,
	return_to_detail_window = nil,
}

--- Filter out discussions that consist entirely of system notes (state changes)
---@param discussions table Raw discussion list from API
---@return table filtered
local function filter_discussions(discussions)
	local out = {}
	for _, d in ipairs(discussions or {}) do
		local has_user_note = false
		for _, n in ipairs(d.notes or {}) do
			if not n.system then
				has_user_note = true
				break
			end
		end
		if has_user_note then
			table.insert(out, d)
		end
	end
	return out
end

--- Get the first non-system note from a discussion
---@param discussion table
---@return table|nil note
local function first_user_note(discussion)
	for _, n in ipairs(discussion.notes or {}) do
		if not n.system then
			return n
		end
	end
	return nil
end

--- Extract YYYY-MM-DD from an ISO timestamp
---@param ts string|nil
---@return string
local function format_date(ts)
	if not ts then
		return "unknown"
	end
	return ts:match("^[^T]+") or ts
end

--- Build the file:line label for a positional note
---@param note table
---@return string|nil
local function position_label(note)
	if not note or not note.position then
		return nil
	end
	local pos = note.position
	local path = pos.new_path or pos.old_path
	local line = pos.new_line or pos.old_line
	if not path then
		return nil
	end
	if line then
		return string.format("%s:%d", path, line)
	end
	return path
end

--- Close the input window/buffer if open
local function close_input()
	if state.input_window and vim.api.nvim_win_is_valid(state.input_window) then
		vim.api.nvim_win_close(state.input_window, true)
	end
	if state.input_buffer and vim.api.nvim_buf_is_valid(state.input_buffer) then
		vim.api.nvim_buf_delete(state.input_buffer, { force = true })
	end
	state.input_window = nil
	state.input_buffer = nil
end

--- Close the threads window/buffer
local function close_threads()
	close_input()
	if state.threads_window and vim.api.nvim_win_is_valid(state.threads_window) then
		vim.api.nvim_win_close(state.threads_window, true)
	end
	if state.threads_buffer and vim.api.nvim_buf_is_valid(state.threads_buffer) then
		vim.api.nvim_buf_delete(state.threads_buffer, { force = true })
	end
	state.threads_window = nil
	state.threads_buffer = nil
end

--- Close everything and clear state
local function close_all()
	close_threads()
	state.discussions = {}
	state.expanded = {}
	state.line_to_discussion = {}
	state.api_context = nil
	state.mr = nil
	state.return_to_detail_window = nil
end

--- Get the discussion under cursor
---@return table|nil
local function get_discussion_under_cursor()
	if not state.threads_window or not vim.api.nvim_win_is_valid(state.threads_window) then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(state.threads_window)[1]
	local did = state.line_to_discussion[row]
	if not did then
		return nil
	end
	for _, d in ipairs(state.discussions) do
		if d.id == did then
			return d
		end
	end
	return nil
end

--- Render the threads buffer
---@param buf number
local function render(buf)
	local lines = {}
	local highlights = {}
	local ns_id = vim.api.nvim_create_namespace("gitlab_ide_mr_threads")
	state.line_to_discussion = {}

	local unresolved, resolved = 0, 0
	for _, d in ipairs(state.discussions) do
		local n = first_user_note(d)
		if n and n.resolvable then
			if n.resolved then
				resolved = resolved + 1
			else
				unresolved = unresolved + 1
			end
		end
	end

	local header = string.format("  Threads (%d unresolved · %d resolved)", unresolved, resolved)
	table.insert(lines, header)
	table.insert(lines, string.rep("═", 80))
	table.insert(lines, "")

	if #state.discussions == 0 then
		table.insert(lines, "  No discussions on this merge request.")
	end

	for _, d in ipairs(state.discussions) do
		local first = first_user_note(d)
		if first then
			local is_expanded = state.expanded[d.id] ~= false -- default true
			local arrow = is_expanded and "▼" or "▶"
			local author = (first.author and first.author.name) or "unknown"
			local date = format_date(first.created_at)
			local resolved_tag = ""
			local resolved_hl = nil
			if first.resolvable then
				if first.resolved then
					resolved_tag = "[●]"
					resolved_hl = "DiagnosticOk"
				else
					resolved_tag = "[○]"
					resolved_hl = "DiagnosticWarn"
				end
			end
			local pos_label = position_label(first)

			-- Count non-system notes total and replies
			local user_notes = {}
			for _, nn in ipairs(d.notes or {}) do
				if not nn.system then
					table.insert(user_notes, nn)
				end
			end
			local reply_count = math.max(0, #user_notes - 1)

			local header_parts = { string.format("  %s  %s · %s", arrow, author, date) }
			if resolved_tag ~= "" then
				table.insert(header_parts, resolved_tag)
			end
			if pos_label then
				table.insert(header_parts, pos_label)
			end
			if not is_expanded and reply_count > 0 then
				table.insert(header_parts, string.format("(%d replies)", reply_count))
			end
			local header_line = table.concat(header_parts, "  ")
			table.insert(lines, header_line)
			local header_row = #lines - 1
			state.line_to_discussion[#lines] = d.id

			-- Highlight resolved tag
			if resolved_hl then
				local tag_start = header_line:find(resolved_tag, 1, true)
				if tag_start then
					table.insert(highlights, {
						line = header_row,
						col_start = tag_start - 1,
						col_end = tag_start - 1 + #resolved_tag,
						hl_group = resolved_hl,
					})
				end
			end
			-- Dim resolved threads
			if first.resolvable and first.resolved then
				table.insert(highlights, {
					line = header_row,
					col_start = 0,
					col_end = #header_line,
					hl_group = "Comment",
				})
			end

			if is_expanded then
				-- First note body
				for _, body_line in ipairs(vim.split(first.body or "", "\n", { trimempty = false })) do
					table.insert(lines, "     " .. body_line)
					state.line_to_discussion[#lines] = d.id
				end

				-- Replies
				for i = 2, #user_notes do
					local reply = user_notes[i]
					local reply_author = (reply.author and reply.author.name) or "unknown"
					local reply_date = format_date(reply.created_at)
					table.insert(lines, "")
					state.line_to_discussion[#lines] = d.id
					local reply_header = string.format("     └─ %s · %s", reply_author, reply_date)
					table.insert(lines, reply_header)
					state.line_to_discussion[#lines] = d.id
					table.insert(highlights, {
						line = #lines - 1,
						col_start = 0,
						col_end = #reply_header,
						hl_group = "Comment",
					})
					for _, body_line in ipairs(vim.split(reply.body or "", "\n", { trimempty = false })) do
						table.insert(lines, "        " .. body_line)
						state.line_to_discussion[#lines] = d.id
					end
				end
			end

			table.insert(lines, "")
		end
	end

	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end
end

--- Refetch discussions and re-render (preserves expanded state)
local function refresh()
	if not state.api_context or not state.mr then
		return
	end
	local ctx = state.api_context
	api.fetch_mr_discussions(ctx.gitlab_url, ctx.token, ctx.project_path, state.mr.iid, function(err, data)
		if err then
			vim.notify("Failed to fetch discussions: " .. err, vim.log.levels.ERROR)
			return
		end
		state.discussions = filter_discussions(data)
		if state.threads_buffer and vim.api.nvim_buf_is_valid(state.threads_buffer) then
			render(state.threads_buffer)
		end
	end)
end

--- Open an input window for replying or creating a new top-level comment
---@param opts table { kind = "reply"|"new", discussion = table|nil }
local function open_input(opts)
	close_input()

	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.floor(editor_width * 0.6)
	local height = math.floor(editor_height * 0.3)
	local col = math.floor((editor_width - width) / 2)
	local row = math.floor((editor_height - height) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

	local title
	if opts.kind == "reply" then
		local short_id = tostring(opts.discussion.id or ""):sub(1, 8)
		title = string.format(" Reply · thread %s ", short_id)
	else
		title = " New comment "
	end
	local footer = " C-s:submit Esc:cancel "

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

	state.input_window = win
	state.input_buffer = buf

	local km_opts = { noremap = true, silent = true, buffer = buf }

	vim.keymap.set("n", "<Esc>", close_input, km_opts)

	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local body = table.concat(buf_lines, "\n")
		if body:match("^%s*$") then
			vim.notify("Body cannot be empty", vim.log.levels.WARN)
			return
		end

		local ctx = state.api_context
		local iid = state.mr.iid

		local function on_done(err)
			if err then
				vim.notify("Submit failed: " .. err, vim.log.levels.ERROR)
				return
			end
			close_input()
			refresh()
		end

		if opts.kind == "reply" then
			api.reply_to_discussion(
				ctx.gitlab_url,
				ctx.token,
				ctx.project_path,
				iid,
				opts.discussion.id,
				body,
				on_done
			)
		else
			api.create_mr_note(ctx.gitlab_url, ctx.token, ctx.project_path, iid, body, on_done)
		end
	end, km_opts)

	vim.cmd("startinsert")
end

--- Set up keymaps for the threads window
---@param buf number
local function setup_keymaps(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Close + return to detail
	local function close_and_return()
		close_threads()
		if state.return_to_detail_window and vim.api.nvim_win_is_valid(state.return_to_detail_window) then
			vim.api.nvim_set_current_win(state.return_to_detail_window)
		end
	end
	vim.keymap.set("n", "q", close_and_return, opts)
	vim.keymap.set("n", "<BS>", close_and_return, opts)
	vim.keymap.set("n", "<Esc>", close_all, opts)

	-- Toggle expand
	vim.keymap.set("n", "<CR>", function()
		local d = get_discussion_under_cursor()
		if not d then
			return
		end
		if state.expanded[d.id] == false then
			state.expanded[d.id] = true
		else
			state.expanded[d.id] = false
		end
		render(buf)
	end, opts)

	-- Open positional file at line
	vim.keymap.set("n", "o", function()
		local d = get_discussion_under_cursor()
		if not d then
			vim.notify("No thread under cursor", vim.log.levels.WARN)
			return
		end
		local n = first_user_note(d)
		if not n or not n.position then
			vim.notify("Not a positional thread", vim.log.levels.WARN)
			return
		end
		local path = n.position.new_path or n.position.old_path
		local line = n.position.new_line or n.position.old_line
		if not path then
			vim.notify("Thread has no file path", vim.log.levels.WARN)
			return
		end
		close_and_return()
		vim.cmd.edit(vim.fn.fnameescape(path))
		if line then
			pcall(vim.fn.cursor, line, 1)
		end
	end, opts)

	-- Reply to thread
	vim.keymap.set("n", "r", function()
		local d = get_discussion_under_cursor()
		if not d then
			vim.notify("No thread under cursor", vim.log.levels.WARN)
			return
		end
		open_input({ kind = "reply", discussion = d })
	end, opts)

	-- Toggle resolved
	vim.keymap.set("n", "R", function()
		local d = get_discussion_under_cursor()
		if not d then
			vim.notify("No thread under cursor", vim.log.levels.WARN)
			return
		end
		local n = first_user_note(d)
		if not n or not n.resolvable then
			vim.notify("Thread is not resolvable", vim.log.levels.WARN)
			return
		end
		local target = not n.resolved
		local verb = target and "Resolve" or "Unresolve"
		vim.ui.select({ "Yes", "No" }, {
			prompt = string.format("%s this thread?", verb),
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local ctx = state.api_context
			api.resolve_discussion(
				ctx.gitlab_url,
				ctx.token,
				ctx.project_path,
				state.mr.iid,
				d.id,
				target,
				function(err)
					if err then
						vim.notify(verb .. " failed: " .. err, vim.log.levels.ERROR)
						return
					end
					refresh()
				end
			)
		end)
	end, opts)

	-- New top-level comment
	vim.keymap.set("n", "c", function()
		open_input({ kind = "new" })
	end, opts)

	-- Manual refresh
	vim.keymap.set("n", "gr", refresh, opts)
end

--- Open the threads view for a merge request
---@param mr table The merge request (must have iid)
---@param api_context table { gitlab_url, token, project_path }
---@param detail_window number|nil The MR detail window id to return focus to on close
function M.open(mr, api_context, detail_window)
	if not mr or not mr.iid then
		vim.notify("Cannot open threads: no merge request", vim.log.levels.ERROR)
		return
	end
	if not api_context then
		vim.notify("Cannot open threads: API context missing", vim.log.levels.ERROR)
		return
	end

	close_all()
	state.api_context = api_context
	state.mr = mr
	state.return_to_detail_window = detail_window

	local ctx = api_context
	api.fetch_mr_discussions(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err, data)
		if err then
			vim.notify("Failed to fetch discussions: " .. err, vim.log.levels.ERROR)
			return
		end
		state.discussions = filter_discussions(data)

		local editor_width = vim.o.columns
		local editor_height = vim.o.lines
		local width = math.floor(editor_width * 0.85)
		local height = math.floor(editor_height * 0.85)
		local col = math.floor((editor_width - width) / 2)
		local row = math.floor((editor_height - height) / 2)

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "swapfile", false)

		local title = string.format(" Threads · !%s ", tostring(mr.iid))
		local footer = " ⏎:expand o:open file r:reply R:resolve c:new gr:refresh q/⌫:back Esc:close "

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
		vim.api.nvim_win_set_option(win, "cursorline", true)

		state.threads_window = win
		state.threads_buffer = buf

		render(buf)
		setup_keymaps(buf)
	end)
end

return M
