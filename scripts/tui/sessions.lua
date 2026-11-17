-- Discover only live sessions belonging to the selected project and user.
local ffi = require("ffi")
ffi.cdef([[
    unsigned int getuid(void);
    char *realpath(const char *path, char *resolved_path);
    void free(void *ptr);
    int socket(int domain, int type, int protocol);
    int connect(int fd, const void *addr, unsigned int len);
    int close(int fd);
]])
local M = {}

function M.quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.canonical(path)
	local resolved = ffi.C.realpath(path, nil)
	if resolved == nil then
		return path
	end
	local result = ffi.string(resolved)
	ffi.C.free(resolved)
	return result
end

function M.project_dir()
	local override = os.getenv("JEMACH_PROJ")
	if override and override ~= "" then
		return M.canonical(override)
	end
	local dir = M.canonical(".")
	local cwd = dir
	while dir ~= "" do
		local f = io.open(dir .. "/Project.toml", "r")
		if f then
			f:close()
			return dir
		end
		dir = dir:match("^(.*)/[^/]+$") or ""
	end
	return cwd
end

function M.alive(path)
	if #path >= 104 then
		return false
	end
	local fd = ffi.C.socket(1, 1, 0)
	if fd < 0 then
		return false
	end
	-- sockaddr_un differs on Darwin (length byte before family).
	local addr = ffi.new("uint8_t[110]")
	if ffi.os == "OSX" then
		addr[0] = 106
		addr[1] = 1
	else
		addr[0] = 1
	end
	ffi.copy(addr + 2, path, #path)
	local ok = ffi.C.connect(fd, addr, ffi.os == "OSX" and 106 or 110) == 0
	ffi.C.close(fd)
	return ok
end

function M.discover(project)
	project = M.canonical(project or M.project_dir())
	local root = "/tmp/jemach-" .. tonumber(ffi.C.getuid())
	local pipe = io.popen("find " .. M.quote(root) .. " -mindepth 1 -maxdepth 1 -type d -name 'session-*' 2>/dev/null")
	local matches = {}
	if not pipe then
		return matches
	end
	for dir in pipe:lines() do
		local f = io.open(dir .. "/project", "r")
		if f then
			local owner_project = f:read("*a")
			f:close()
			local socket = dir .. "/repl.sock"
			if owner_project == project and M.alive(socket) then
				matches[#matches + 1] = { socket = socket, state = dir .. "/state.json" }
			end
		end
	end
	pipe:close()
	table.sort(matches, function(a, b)
		return a.socket < b.socket
	end)
	return matches
end

function M.select(project)
	local matches = M.discover(project)
	if #matches == 1 then
		return matches[1]
	end
	local message = #matches == 0 and "No active jEMach session in this project. Run using jEMach in Julia."
		or "Multiple jEMach sessions in this project. Select one with jl-assist -s SOCKET:"
	for _, session in ipairs(matches) do
		message = message .. "\n  " .. session.socket
	end
	return nil, message
end

return M
