local M = {}
local config = require("jemach.config")

function M.find_project_root()
	local current_buf = vim.api.nvim_buf_get_name(0)
	if current_buf == "" then
		return nil
	end
	local current_dir = vim.fn.fnamemodify(current_buf, ":p:h")
	local project_files = { "Project.toml", "JuliaProject.toml" }
	local root_files = vim.fs.find(project_files, { path = current_dir, upward = true, type = "file" })

	if not root_files or #root_files == 0 then
		return nil
	end
	return vim.fn.fnamemodify(root_files[1], ":p:h")
end

local function is_native_terminal_running(repl)
	return repl.terminal_bufnr and vim.api.nvim_buf_is_valid(repl.terminal_bufnr)
end

function M.is_repl_running(repl)
	if config.options.terminal_type == "native" then
		return is_native_terminal_running(repl)
	end

	local backend = config.options.backend

	if backend == "vim-slime" then
		return vim.g.slime_target ~= nil or config.options.slime_target ~= nil
	elseif backend == "toggleterm" then
		if not repl.julia_terminal_obj then
			return false
		end

		if not repl.julia_terminal_obj.job_id then
			return false
		end

		local job_status = vim.fn.jobwait({ repl.julia_terminal_obj.job_id }, 0)[1]
		return job_status == -1
	end

	return false
end

function M.get_repl_window(repl)
	if config.options.terminal_type == "native" then
		if repl.terminal_win_id and vim.api.nvim_win_is_valid(repl.terminal_win_id) then
			return repl.terminal_win_id
		end
		return nil
	end

	if not repl.julia_terminal_obj or not repl.julia_terminal_obj.window then
		return nil
	end

	if vim.api.nvim_win_is_valid(repl.julia_terminal_obj.window) then
		return repl.julia_terminal_obj.window
	end

	return nil
end

function M.get_plugin_root()
	local source = debug.getinfo(1).source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	return vim.fn.fnamemodify(source, ":p:h:h:h")
end

return M
