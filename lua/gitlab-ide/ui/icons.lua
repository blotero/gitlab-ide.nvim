-- Shared status icons and highlights for gitlab-ide.nvim
local M = {}

-- Status icons mapping
M.icons = {
	SUCCESS = "✓",
	FAILED = "✗",
	RUNNING = "●",
	PENDING = "○",
	SKIPPED = "⊘",
	CANCELED = "⊘",
	MANUAL = "▶",
	CREATED = "○",
	WAITING_FOR_RESOURCE = "○",
	PREPARING = "○",
	SCHEDULED = "◷",
}

-- Highlight groups mapping
M.highlights = {
	SUCCESS = "DiagnosticOk",
	FAILED = "DiagnosticError",
	RUNNING = "DiagnosticInfo",
	PENDING = "Comment",
	SKIPPED = "Comment",
	CANCELED = "DiagnosticWarn",
	MANUAL = "DiagnosticHint",
	CREATED = "Comment",
	WAITING_FOR_RESOURCE = "Comment",
	PREPARING = "DiagnosticInfo",
	SCHEDULED = "DiagnosticHint",
}

--- Get the icon for a status
---@param status string The job/stage status
---@return string icon The status icon
function M.get_icon(status)
	return M.icons[status] or "?"
end

--- Get the highlight group for a status
---@param status string The job/stage status
---@return string highlight The highlight group name
function M.get_highlight(status)
	return M.highlights[status] or "Normal"
end

return M
