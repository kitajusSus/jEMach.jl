local ffi = require("ffi")
-- ---------------------------------------------------------------------------
-- FFI: non-blocking stdin read via select(2) + read(2) + sockets
-- ---------------------------------------------------------------------------
ffi.cdef(ffi.os == "OSX" and [[
  typedef int           suseconds_t;
]] or [[
  typedef long          suseconds_t;
]])

ffi.cdef([[
  typedef long          ssize_t;
  typedef unsigned long size_t;
  typedef long          time_t;

  typedef struct {
    time_t      tv_sec;
    suseconds_t tv_usec;
  } timeval_t;

  typedef struct { unsigned char bytes[128]; } fd_set_t;

  int     select(int, fd_set_t *, fd_set_t *, fd_set_t *, timeval_t *);
  ssize_t read  (int, void *, size_t);
  int     gettimeofday(timeval_t *tv, void *tz);


  struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
  };

  int     socket(int domain, int type, int protocol);
  int     connect(int sockfd, const void *addr, unsigned int addrlen);
  int     close(int fd);
  ssize_t write(int fd, const void *buf, size_t count);
  int     ioctl(int fd, unsigned long request, ...);
]])

ffi.cdef(ffi.os == "OSX" and [[
  struct sockaddr_un { unsigned char sun_len; unsigned char sun_family; char sun_path[104]; };
]] or [[
  struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
]])

local STDIN = 0
local STDOUT = 1
local TIOCGWINSZ = (ffi.os == "OSX") and 0x40087468 or 0x5413

local function fd_set_new()
	return ffi.new("fd_set_t")
end
local function fd_set_set(s, fd)
	assert(fd >= 0 and fd < 1024, "select descriptor out of range")
	local byte, mask = math.floor(fd / 8), 2 ^ (fd % 8)
	if s.bytes[byte] % (2 * mask) < mask then
		s.bytes[byte] = s.bytes[byte] + mask
	end
end
local function fd_set_isset(s, fd)
	assert(fd >= 0 and fd < 1024, "select descriptor out of range")
	local mask = 2 ^ (fd % 8)
	return s.bytes[math.floor(fd / 8)] % (2 * mask) >= mask
end

local winsize_buf = ffi.new("struct winsize")

local function get_terminal_size()
	-- Fast path: zero-fork ioctl(TIOCGWINSZ) on STDOUT or STDIN
	if ffi.C.ioctl(STDOUT, TIOCGWINSZ, winsize_buf) == 0 and winsize_buf.ws_row > 0 and winsize_buf.ws_col > 0 then
		return tonumber(winsize_buf.ws_row), tonumber(winsize_buf.ws_col)
	end
	if ffi.C.ioctl(STDIN, TIOCGWINSZ, winsize_buf) == 0 and winsize_buf.ws_row > 0 and winsize_buf.ws_col > 0 then
		return tonumber(winsize_buf.ws_row), tonumber(winsize_buf.ws_col)
	end
	-- Fallback to tput
	local handle = io.popen("tput lines && tput cols 2>/dev/null")
	if not handle then
		return 24, 80
	end
	local lines = tonumber(handle:read("*l")) or 24
	local cols = tonumber(handle:read("*l")) or 80
	handle:close()
	return lines, cols
end

local function raw_mode_on()
	os.execute("stty raw -echo 2>/dev/null")
end

local function raw_mode_off()
	os.execute("stty sane 2>/dev/null")
end

local function make_timeval(timeout_ms)
	local ms = tonumber(timeout_ms) or 0
	if ms < 0 then
		ms = 0
	end
	local total_usec = math.floor(ms * 1000 + 0.5)
	local sec = math.floor(total_usec / 1000000)
	local usec = total_usec - sec * 1000000
	return ffi.new("timeval_t", { tv_sec = sec, tv_usec = usec })
end

return {
	fd_set_new = fd_set_new,
	fd_set_set = fd_set_set,
	fd_set_isset = fd_set_isset,
	make_timeval = make_timeval,
	get_terminal_size = get_terminal_size,
	raw_mode_on = raw_mode_on,
	raw_mode_off = raw_mode_off,
}
