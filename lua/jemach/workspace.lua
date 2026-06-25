local M = {}
local config = require("jemach.config")
local repl = nil -- Lazy load to avoid circular dependencies

local function get_project_dir()
	local cwd = vim.fn.getcwd()
	local proj_toml = vim.fs.find("Project.toml", { upward = true, path = cwd })[1]
	if proj_toml then
		return vim.fs.dirname(proj_toml)
	end
	return cwd
end

local function get_safe_name()
	local pdir = get_project_dir()
	return pdir:gsub("[^a-zA-Z0-9]", "_")
end

M.state = {
	workspace_bufnr = nil,
	workspace_win_id = nil,
	workspace_save_file = vim.fn.stdpath("cache") .. "/julia_workspace_save.jl",
	cache = {
		last_update = 0,
		data = nil,
		debounce_timer = nil,
	},
	rpc_client = nil,
	rpc_pipe_path = "/tmp/jemach.sock",
}

-- Obsługa otrzymanej asynchronicznie wiadomości od Julii (JSON)
local function handle_rpc_data(data)
	if not M.state.workspace_bufnr or not vim.api.nvim_buf_is_valid(M.state.workspace_bufnr) then
		return
	end

	-- Simple validation or splitting if multiple JSONs arrived
	local ok, decoded = pcall(vim.fn.json_decode, data)
	if not ok or not decoded then
		-- Fallback to raw text if not JSON (or parsing error)
		decoded = vim.split(data, "\n", { trimempty = true })
	else
		-- Render formatted lines based on JSON state
		local lines = {
			"╭─────────────────────────────────────────╮",
			"│  jEMach Workspace                         │",
			"╰─────────────────────────────────────────╯",
			"",
		}

		local items = {}
		if decoded.modules then
			for _, mod in ipairs(decoded.modules) do
				if mod.items then
					for _, item in ipairs(mod.items) do
						table.insert(items, item)
					end
				end
			end
		elseif type(decoded) == "table" then
			items = decoded
		end

		local flat_items = {}
		local function add_formatted_items(item, depth)
			table.insert(flat_items, {
				name = item.name,
				type = item.type,
				value = item.value,
				expr = item.expr or item.name,
				depth = depth,
			})
			if item.children then
				table.sort(item.children, function(a, b) return a.name < b.name end)
				for _, child in ipairs(item.children) do
					add_formatted_items(child, depth + 1)
				end
			end
		end

		table.sort(items, function(a, b)
			return a.name < b.name
		end)

		for _, item in ipairs(items) do
			add_formatted_items(item, 0)
		end

		M.state.cache.raw_data = flat_items
		M.state.line_exprs = {}

		if vim.tbl_isempty(flat_items) then
			table.insert(lines, "  No variables defined")
		else
			table.insert(lines, "  Name              Type                Value")
			table.insert(lines, "  ────────────────  ──────────────────  ─────────────")

			for _, v in ipairs(flat_items) do
				local indent = string.rep("  ", v.depth)
				local name_prefix = ""
				if v.depth > 0 then
					name_prefix = "└─ "
				end
				local name_str = indent .. name_prefix .. v.name
				local n = name_str .. string.rep(" ", math.max(0, 16 - #name_str))
				local t = v.type .. string.rep(" ", math.max(0, 18 - #v.type))
				local line_text = "  " .. n .. "  " .. t .. "  " .. v.value
				table.insert(lines, line_text)
				M.state.line_exprs[#lines] = v.expr
			end
		end

		table.insert(lines, "")
		table.insert(lines, "╭─────────────────────────────────────────╮")
		table.insert(lines, "│  <CR> print │ i inspect │ d delete       │")
		table.insert(lines, "│  r refresh  │ q close                   │")
		table.insert(lines, "╰─────────────────────────────────────────╯")

		decoded = lines
	end

	M.state.cache.data = decoded
	M.state.cache.last_update = vim.loop.now()

	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(M.state.workspace_bufnr) then
			vim.bo[M.state.workspace_bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(M.state.workspace_bufnr, 0, -1, false, decoded)
			vim.bo[M.state.workspace_bufnr].modifiable = false
		end
	end)
end

function M.start_server_if_needed()
	M.state.rpc_pipe_path = "/tmp/jemach_" .. get_safe_name() .. ".sock"

	if M.state.rpc_client and not M.state.rpc_client:is_closing() then
		return
	end

	local now = vim.loop.now()
	if M.state.last_connect_time and now - M.state.last_connect_time < 1000 then
		return
	end
	M.state.last_connect_time = now

	M.state.rpc_client = vim.loop.new_pipe(false)
	M.state.rpc_client:connect(M.state.rpc_pipe_path, function(err)
		if err then
			if M.state.rpc_client then
				M.state.rpc_client:close()
				M.state.rpc_client = nil
			end

			-- Start the broker in the background using jobstart
			local broker_bin = require("jemach.utils").get_plugin_root() .. "/zig/zig-out/bin/jemach-broker"
			if vim.fn.executable(broker_bin) == 1 then
				vim.fn.jobstart({ broker_bin, M.state.rpc_pipe_path }, { detach = true })
				-- Wait a little bit and retry once.
				vim.defer_fn(function()
					M.start_server_if_needed()
				end, 200)
			else
				vim.schedule(function()
					vim.notify("⚠️ jEMach broker binary not found or not executable: " .. broker_bin, vim.log.levels.ERROR)
				end)
			end
			return
		end

		-- Connection succeeded!
		-- Register as SUB
		M.state.rpc_client:write("SUB\n")

		-- Read start
		local buffer = ""
		M.state.rpc_client:read_start(function(read_err, chunk)
			if read_err then
				if M.state.rpc_client then
					M.state.rpc_client:close()
					M.state.rpc_client = nil
				end
			elseif chunk then
				buffer = buffer .. chunk
				while true do
					local nl = string.find(buffer, "\n")
					if not nl then
						break
					end
					local line = string.sub(buffer, 1, nl - 1)
					buffer = string.sub(buffer, nl + 1)
					if line ~= "" then
						handle_rpc_data(line)
					end
				end
			else
				-- EOF
				if M.state.rpc_client then
					M.state.rpc_client:close()
					M.state.rpc_client = nil
				end
			end
		end)
	end)
end

function M.stop_server()
	if M.state.rpc_client and not M.state.rpc_client:is_closing() then
		M.state.rpc_client:close()
		M.state.rpc_client = nil
	end
end

function M.update_workspace_panel()
	if not repl then
		repl = require("jemach.repl")
	end

	if not repl.is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	if not M.state.workspace_bufnr or not vim.api.nvim_buf_is_valid(M.state.workspace_bufnr) then
		return
	end

	M.start_server_if_needed()

	-- Auto-load watcher if not yet loaded in this session
	local active_buf = repl.state.terminal_bufnr or (repl.state.julia_terminal_obj and repl.state.julia_terminal_obj.bufnr)
	if active_buf then
		if not M.state.watcher_loaded_for_buf then
			M.state.watcher_loaded_for_buf = {}
		end
		if not M.state.watcher_loaded_for_buf[active_buf] then
			local watcher_path = require("jemach.utils").get_plugin_root() .. "/scripts/jl_watcher.jl"
			repl.send_to_backend(string.format('try if !isdefined(Main, :jEMach); include("%s"); end catch; end', watcher_path))
			M.state.watcher_loaded_for_buf[active_buf] = true
			-- Wait a short moment for the background task to start before triggering the first state publish
			vim.defer_fn(function()
				repl.send_to_backend("try jEMach.publish_state() catch; end")
			end, 500)
			return
		end
	end

	-- Trigger immediate state publish in the Julia REPL
	repl.send_to_backend("try jEMach.publish_state() catch; end")
end

local function get_variable_under_cursor()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	if M.state.line_exprs and M.state.line_exprs[row] then
		return M.state.line_exprs[row]
	end

	local line = vim.api.nvim_get_current_line()
	local var = line:match("^%s+(%S+)%s+%S+%s*")
	return var
end

local function setup_workspace_keymaps(bufnr)
	if not repl then
		repl = require("jemach.repl")
	end

	vim.keymap.set("n", "<CR>", function()
		local var = get_variable_under_cursor()
		if var and repl.is_repl_running() then
			repl.send_to_backend(string.format("println(%s)", var))
			vim.notify("📤 println(" .. var .. ")", vim.log.levels.INFO)
		end
	end, { buffer = bufnr, desc = "Print variable" })

	vim.keymap.set("n", "i", function()
		local var = get_variable_under_cursor()
		if var and repl.is_repl_running() then
			repl.send_to_backend(string.format("jEMach.inspect_var(Main, %q)", var))
			vim.notify("🔍 Inspecting: " .. var, vim.log.levels.INFO)
		end
	end, { buffer = bufnr, desc = "Inspect variable" })

	vim.keymap.set("n", "d", function()
		local var = get_variable_under_cursor()
		if var and repl.is_repl_running() then
			local confirm = vim.fn.confirm(string.format("Delete '%s'?", var), "&Yes\n&No", 2)
			if confirm == 1 then
				if var:find("%.") or var:find("%[") then
					local dict_expr, key_expr = var:match("^(.+)%[(.+)%]$")
					if dict_expr and key_expr then
						repl.send_to_backend(string.format("delete!(%s, %s)", dict_expr, key_expr))
					else
						repl.send_to_backend(string.format("%s = nothing", var))
					end
				else
					repl.send_to_backend(string.format("%s = nothing", var))
				end
				vim.notify("🗑️ Deleted: " .. var, vim.log.levels.WARN)
				M.state.cache.data = nil
				vim.defer_fn(M.update_workspace_panel, 400)
			end
		end
	end, { buffer = bufnr, desc = "Delete variable" })

	vim.keymap.set("n", "r", function()
		M.state.cache.data = nil
		M.update_workspace_panel()
		vim.notify("🔄 Refreshed", vim.log.levels.INFO)
	end, { buffer = bufnr, desc = "Refresh" })

	vim.keymap.set("n", "q", function()
		if M.state.workspace_win_id and vim.api.nvim_win_is_valid(M.state.workspace_win_id) then
			vim.api.nvim_win_close(M.state.workspace_win_id, true)
			M.state.workspace_win_id = nil
			M.state.workspace_bufnr = nil
		end
	end, { buffer = bufnr, desc = "Close" })
end

function M.create_workspace_buffer()
	M.state.workspace_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[M.state.workspace_bufnr].buftype = "nofile"
	vim.bo[M.state.workspace_bufnr].bufhidden = "hide"
	vim.bo[M.state.workspace_bufnr].swapfile = false
	vim.bo[M.state.workspace_bufnr].filetype = "julia"
	return M.state.workspace_bufnr
end

function M.toggle_workspace_panel()
	if not repl then
		repl = require("jemach.repl")
	end

	if M.state.workspace_win_id and vim.api.nvim_win_is_valid(M.state.workspace_win_id) then
		vim.api.nvim_win_close(M.state.workspace_win_id, true)
		M.state.workspace_win_id = nil
		M.state.workspace_bufnr = nil
		return
	end

	M.create_workspace_buffer()
	vim.bo[M.state.workspace_bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(M.state.workspace_bufnr, 0, -1, false, { "Loading..." })
	vim.bo[M.state.workspace_bufnr].modifiable = false

	vim.cmd("set splitright")
	vim.cmd(string.format("vsplit | vertical resize %d", config.options.workspace_width))

	M.state.workspace_win_id = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(M.state.workspace_win_id, M.state.workspace_bufnr)
	vim.wo[M.state.workspace_win_id].foldenable = false
	vim.wo[M.state.workspace_win_id].spell = false
	vim.wo[M.state.workspace_win_id].number = false
	vim.wo[M.state.workspace_win_id].relativenumber = false
	vim.wo[M.state.workspace_win_id].wrap = false
	vim.wo[M.state.workspace_win_id].linebreak = false

	setup_workspace_keymaps(M.state.workspace_bufnr)

	if repl.is_repl_running() then
		M.update_workspace_panel()
	else
		vim.bo[M.state.workspace_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(M.state.workspace_bufnr, 0, -1, false, {
			"╭─────────────────────────────────────────╮",
			"│  jEMach Workspace                         │",
			"╰─────────────────────────────────────────╯",
			"",
			"  Start REPL first:",
			"    :Jr or <leader>jw",
			"",
			"╭─────────────────────────────────────────╮",
			"│  <CR> print │ i inspect │ d delete       │",
			"│  r refresh  │ q close                   │",
			"╰─────────────────────────────────────────╯",
		})
		vim.bo[M.state.workspace_bufnr].modifiable = false
	end
end

function M.setup_workspace_keymaps(bufnr)
	setup_workspace_keymaps(bufnr)
end

function M.save_workspace()
	if not repl then
		repl = require("jemach.repl")
	end

	if not repl.is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	local save_code = string.format(
		[[
using Serialization
const __nvim_save_path = raw"%s"
const __nvim_excluded = [:Main, :Core, :Base, :__nvim_save_path, :__nvim_excluded]

function __save_workspace()
    workspace_data = Dict{Symbol, Any}()

    all_names = names(Main, all=true)
    for name in all_names
        str_name = string(name)
        if !startswith(str_name, "#") &&
           !startswith(str_name, "__nvim") &&
           !(name in __nvim_excluded)
            try
                val = getfield(Main, name)
                # Only save serializable types (exclude Modules and Functions)
                if !(val isa Module) && !(val isa Function)
                    workspace_data[name] = val
                end
            catch e
                @warn "Could not save variable: $name" exception=e
            end
        end
    end

    try
        open(__nvim_save_path, "w") do io
            serialize(io, workspace_data)
        end
        println("✅ Workspace saved ($(length(workspace_data)) variables)")
        return true
    catch e
        @error "Failed to save workspace" exception=e
        return false
    end
end

__save_workspace()
]],
		M.state.workspace_save_file
	)

	repl.send_to_backend(save_code)
	vim.notify("💾 Saving workspace...", vim.log.levels.INFO)
end

function M.restore_workspace()
	if not repl then
		repl = require("jemach.repl")
	end

	if not repl.is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	if vim.fn.filereadable(M.state.workspace_save_file) ~= 1 then
		vim.notify("📭 No saved workspace found", vim.log.levels.WARN)
		return
	end

	local restore_code = string.format(
		[[
using Serialization
const __nvim_restore_path = raw"%s"

function __restore_workspace()
    if !isfile(__nvim_restore_path)
        println("❌ No workspace file found")
        return false
    end

    try
        workspace_data = open(__nvim_restore_path, "r") do io
            deserialize(io)
        end

        count = 0
        for (name, val) in workspace_data
            try
                # Validate name is a valid Symbol and not trying to override Core/Base
                if name isa Symbol && !startswith(string(name), "#") &&
                   !(name in [:Main, :Core, :Base])
                    setfield!(Main, name, val)
                    count += 1
                end
            catch e
                @warn "Could not restore variable: $name" exception=e
            end
        end

        println("✅ Workspace restored ($count variables)")
        return true
    catch e
        @error "Failed to restore workspace" exception=e
        return false
    end
end

__restore_workspace()
]],
		M.state.workspace_save_file
	)

	repl.send_to_backend(restore_code)
	vim.notify("📂 Restoring workspace...", vim.log.levels.INFO)

	if config.options.auto_update_workspace and M.state.workspace_bufnr and vim.api.nvim_buf_is_valid(M.state.workspace_bufnr) then
		vim.defer_fn(M.update_workspace_panel, 1000)
	end
end

function M.clear_saved_workspace()
	if vim.fn.filereadable(M.state.workspace_save_file) ~= 1 then
		vim.notify("📭 No saved workspace found", vim.log.levels.INFO)
		return
	end

	local confirm = vim.fn.confirm("Clear saved workspace?", "&Yes\n&No", 2)
	if confirm == 1 then
		os.remove(M.state.workspace_save_file)
		vim.notify("🗑️ Saved workspace cleared", vim.log.levels.INFO)
	end
end

return M
