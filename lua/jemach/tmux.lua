local M = {}

-- State
local state = {
    pane_id = nil,
    inspector_pane_id = nil,
    last_nvim_pane = nil
}

function M.is_available()
    return vim.fn.executable("tmux") == 1 and vim.env.TMUX ~= nil
end

function M.is_running()
    if not state.pane_id then
        -- Try to rediscover if we have a known session
        local session_name = "jemach_repl"
        local handle = io.popen("tmux list-panes -t " .. session_name .. " -F '#{pane_id}' 2>/dev/null")
        if handle then
            local pid = handle:read("*l")
            handle:close()
            if pid then
                state.pane_id = pid
                return true
            end
        end

        -- Fallback: Look for any pane running julia
        local julia_panes = M.find_julia_panes()
        if #julia_panes > 0 then
            state.pane_id = julia_panes[1].id
            return true
        end
        return false
    end

    -- Verify it still exists AND is actually running Julia
    -- We fetch both ID and command to ensure we don't attach to a shell
    local handle = io.popen("tmux list-panes -a -F '#{pane_id}:#{pane_current_command}'")
    if handle then
        local found = false
        for line in handle:lines() do
            local id, cmd = line:match("([^:]+):(.+)")
            if id == state.pane_id then
                -- Check if the command is still julia
                if cmd and cmd:lower():find("julia", 1, true) then
                    found = true
                else
                    -- Pane exists but not running julia (e.g. dropped to shell)
                    found = false
                end
                break
            end
        end
        handle:close()

        if found then
            return true
        end
    end

    state.pane_id = nil
    return false
end

-- Utility: Get current nvim pane
function M.get_current_tmux_pane()
    local handle = io.popen('tmux display-message -p "#{pane_id}"')
    if handle then
        local id = handle:read("*l")
        handle:close()
        return id
    end
    return nil
end

-- Utility: List panes
function M.list_panes()
    if not M.is_available() then return {} end
    local handle = io.popen('tmux list-panes -a -F "#{pane_id}:#{pane_current_command}:#{pane_title}"')
    if not handle then return {} end

    local panes = {}
    for line in handle:lines() do
        local id, cmd, title = line:match("([^:]+):([^:]+):(.+)")
        if id then
            table.insert(panes, {id=id, command=cmd, title=title})
        end
    end
    handle:close()
    return panes
end

function M.find_julia_panes()
    local panes = M.list_panes()
    local julia_panes = {}
    local current_pane = M.get_current_tmux_pane()
    for _, pane in ipairs(panes) do
        if pane.id ~= current_pane then
            -- Strict check: ONLY trust the command, not the title.
            -- This prevents attaching to shells in windows named "Julia REPL"
            if pane.command:lower():find("julia", 1, true) then
                table.insert(julia_panes, pane)
            end
        end
    end
    return julia_panes
end

function M.start(cmd, opts)
    if not M.is_available() then
        vim.notify("Tmux not found or not in a session", vim.log.levels.ERROR)
        return false
    end

    local isolation = opts.isolation or "window"

    if M.is_running() then
        local current = M.get_current_tmux_pane()
        if state.pane_id == current then
             state.pane_id = nil
        else
             vim.notify("Julia pane already detected: " .. state.pane_id, vim.log.levels.INFO)
             return true
        end
    end

    if isolation == "pane" then
        local existing = M.find_julia_panes()
        if #existing > 0 then
            state.pane_id = existing[1].id
            vim.notify("Attached to existing Julia pane: " .. state.pane_id, vim.log.levels.INFO)
            return true
        end
    end

    local nvim_pane = M.get_current_tmux_pane()

    if isolation == "session" then
        local session_name = "jemach_repl"
        local check = os.execute("tmux has-session -t " .. session_name .. " 2>/dev/null")
        if check == 0 then
            local handle = io.popen("tmux list-panes -t " .. session_name .. " -F '#{pane_id}'")
            if handle then
                local pid = handle:read("*l")
                handle:close()
                if pid then
                    state.pane_id = pid
                    vim.notify("Attached to existing session: " .. session_name, vim.log.levels.INFO)
                    return true
                end
            end
            vim.notify("Failed to find pane in existing session " .. session_name, vim.log.levels.ERROR)
        else
            local ret = os.execute("tmux new-session -d -s " .. session_name .. " '" .. cmd .. "'")
            vim.loop.sleep(100)

            local handle = io.popen("tmux list-panes -t " .. session_name .. " -F '#{pane_id}'")
            if handle then
                local pid = handle:read("*l")
                handle:close()
                if pid then
                    state.pane_id = pid
                    vim.notify("Started Julia in new session: " .. session_name, vim.log.levels.INFO)
                    return true
                end
            end
            vim.notify("❌ Failed to create/find tmux session: " .. session_name .. ". Check tmux logs.", vim.log.levels.ERROR)
        end
        return false

    elseif isolation == "window" then
        local tmux_cmd = string.format("tmux new-window -P -n 'Julia REPL' -F '#{pane_id}' '%s'", cmd)
        local handle = io.popen(tmux_cmd)
        if handle then
            local new_id = handle:read("*l")
            handle:close()
            if new_id then
                state.pane_id = new_id
                vim.notify("Started Julia in new window: " .. new_id, vim.log.levels.INFO)

                -- Optional: Attach workspace viewer in a split
                if opts.attach_workspace then
                    local ws_file = vim.fn.stdpath("cache") .. "/jemach.log"
                    -- Create dummy file if not exists
                    local f = io.open(ws_file, "a"); if f then f:close() end

                    local split_flag = "-h"
                    if opts.workspace_layout == "horizontal" then split_flag = "-v" end

                    -- We want to run a command that displays the log cleanly.
                    -- Simple `tail -f` for now. `column` is nice but requires complex piping.
                    -- Let's try to format it slightly with awk if possible, else just cat.
                    -- Safest is tail -f.
                    local viewer_cmd = string.format("tail -n 100 -f %s", vim.fn.shellescape(ws_file))

                    -- Split the NEW window (target new_id)
                    -- We need to target the pane ID we just got.
                    local split_cmd = string.format("tmux split-window %s -l 40 -t %s '%s'", split_flag, new_id, viewer_cmd)
                    os.execute(split_cmd)

                    -- Rename the pane for clarity?
                    -- We need the ID of the new pane. split-window -P -F '#{pane_id}'
                    -- But let's just assume it worked.
                    -- Also, select the REPL pane back so focus is on REPL.
                    os.execute("tmux select-pane -t " .. new_id)
                end

                return true
            end
        end
        vim.notify("❌ Failed to create tmux window.", vim.log.levels.ERROR)

    else -- pane
        local direction = opts.direction or "horizontal"
        local size = opts.size or 15
        local split_flag = (direction == "vertical") and "-h" or "-v"
        if direction == "vertical" then split_flag = "-h" else split_flag = "-v" end

        local tmux_cmd = string.format("tmux split-window %s -l %d -P -F '#{pane_id}' '%s'", split_flag, size, cmd)
        local handle = io.popen(tmux_cmd)
        if handle then
            local new_id = handle:read("*l")
            handle:close()
            if new_id then
                state.pane_id = new_id
                vim.notify("Started Julia in split pane: " .. new_id, vim.log.levels.INFO)
                if nvim_pane then
                    os.execute("tmux select-pane -t " .. nvim_pane)
                end
                return true
            end
        end
        vim.notify("❌ Failed to split tmux pane.", vim.log.levels.ERROR)
    end

    return false
end

function M.send(text)
    local current_pane = M.get_current_tmux_pane()

    if not state.pane_id then
        vim.notify("❌ No Julia pane targeted. Please run :Jr or restart plugin.", vim.log.levels.ERROR)
        return false
    end

    if state.pane_id == current_pane then
        vim.notify("❌ Critical: Plugin attempted to paste into editor! Aborting send.", vim.log.levels.ERROR)
        state.pane_id = nil
        return false
    end

    if not M.is_running() then
        vim.notify("❌ Julia pane not found (or not running Julia).", vim.log.levels.ERROR)
        return false
    end

    local tfile = vim.fn.tempname()
    local f2 = io.open(tfile, "w")
    if f2 then
        f2:write(text)
        if text:sub(-1) ~= "\n" then f2:write("\n") end
        f2:close()

        local escaped_tfile = vim.fn.shellescape(tfile)

        vim.fn.system(string.format("tmux load-buffer %s", escaped_tfile))
        vim.fn.system(string.format("tmux paste-buffer -d -t %s", state.pane_id))

        os.remove(tfile)
        return true
    end

    return false
end

function M.show(direction)
    if not M.is_running() then return end

    local handle = io.popen("tmux display-message -p -t " .. state.pane_id .. " '#{session_name}'")
    local target_session = handle:read("*l")
    handle:close()

    local handle2 = io.popen("tmux display-message -p '#{session_name}'")
    local current_session = handle2:read("*l")
    handle2:close()

    if target_session ~= current_session then
        if vim.env.TMUX then
             vim.notify("🔄 Switching to session '".. target_session .."'...", vim.log.levels.INFO)
             os.execute("tmux switch-client -t " .. target_session)
        else
             vim.notify("Julia is running in detached session '".. (target_session or "?") .."'. Attach tmux to view.", vim.log.levels.INFO)
        end
    else
        os.execute("tmux select-pane -t " .. state.pane_id)
    end
end

function M.hide()
    local current = M.get_current_tmux_pane()
    if current then
        state.last_nvim_pane = current
    end
end

function M.toggle(direction)
    M.show()
end

function M.get_window()
    return nil
end

-- --- Inspector Pane Support ---

function M.ensure_inspector_pane()
    if state.inspector_pane_id then
        local handle = io.popen("tmux display-message -p -t " .. state.inspector_pane_id .. " '#{pane_id}' 2>/dev/null")
        if handle then
            local pid = handle:read("*l")
            handle:close()
            if pid then return pid end
        end
    end

    local inspect_file = vim.fn.stdpath("cache") .. "/jemach_inspect.log"
    local f = io.open(inspect_file, "a"); if f then f:close() end

    local cmd = string.format("tail -F %s", vim.fn.shellescape(inspect_file))
    local tmux_cmd = string.format("tmux split-window -h -l 40 -P -F '#{pane_id}' '%s'", cmd)

    local handle = io.popen(tmux_cmd)
    if handle then
        local pid = handle:read("*l")
        handle:close()
        if pid then
            state.inspector_pane_id = pid
            os.execute("tmux select-pane -t " .. pid .. " -T 'jEMach Inspector'")
            local nvim = M.get_current_tmux_pane()
            if nvim then os.execute("tmux select-pane -t " .. nvim) end
            return pid
        end
    end
    return nil
end

function M.open_inspector_pane()
    M.ensure_inspector_pane()
end

function M.close_inspector_pane()
    if state.inspector_pane_id then
        os.execute("tmux kill-pane -t " .. state.inspector_pane_id)
        state.inspector_pane_id = nil
    end
end

function M.toggle_tui_popup()
    if not M.is_available() then
        vim.notify("Tmux not found or not in a session", vim.log.levels.ERROR)
        return
    end

    local plugin_root = require("jemach.utils").get_plugin_root()
    local tui_script = plugin_root .. "/scripts/jl_tui.lua"
    local pane_arg = state.pane_id or "{left-of}"

    local cmd = string.format(
        "tmux display-popup -w 85%% -h 80%% -d %s -E 'luajit %s %s'",
        vim.fn.shellescape(vim.fn.getcwd()),
        vim.fn.shellescape(tui_script),
        vim.fn.shellescape(pane_arg)
    )

    vim.fn.system(cmd)
end

return M
