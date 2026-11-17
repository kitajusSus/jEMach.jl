-- Run from any directory: luajit /path/to/jEMach/test/tui.lua
local root = assert(arg[0]:match("^(.*)/test/[^/]+$"))
package.path = root .. "/scripts/?.lua;" .. package.path
local json = require("tui.json")
local text = require("tui.text")
local keys = require("tui.keys")
local rows = require("tui.rows")
local preview = require("tui.preview")
local sessions = require("tui.sessions")
local platform = require("tui.platform")
local count = 0
local function check(value, message)
	count = count + 1
	assert(value, message or ("assertion " .. count))
end

local decoded = json.decode([[{"x":"\u017c\u00f3\u0142\u0107 \ud83d\ude00","n":-1.25e2,"a":[false,null,true]}]])
check(decoded.x == "żółć 😀")
check(decoded.n == -125)
check(#decoded.a == 3 and decoded.a[1] == false and decoded.a[2] == json.null)
for _, bad in ipairs({
	'{"x":"unterminated}',
	'{"x":true garbage}',
	'{"x":01}',
	'{"x":1.}',
	'{"x":1.e2}',
	'{"x":+1}',
	"[1,]",
	'{"x":"\\q"}',
	'{"x":"\\ud800"}',
	'{"x":"\\udc00"}',
	"{} trailing",
	"[1e9999]",
	'{"x":tru}',
}) do
	check(not pcall(json.decode, bad), "accepted malformed JSON: " .. bad)
end
local controls = '\0\1\b\f\n\r\t"\\ż😀'
check(json.decode('"' .. json.escape(controls) .. '"') == controls)
check(text.truncate_visible("żółć", 3) == "żó…")
check(text.visible_len("\27[31mżółć\27[0m") == 4)
check(keys.normalize("\27[106;2u") == "J")
check(keys.normalize("\27OA") == "\27[A")
local queue = {}
keys.enqueue("j\27[B\27[99;5u", queue)
check(#queue == 3 and queue[2] == "\27[B" and queue[3] == "\3")
local fds = platform.fd_set_new()
for _, fd in ipairs({ 0, 52, 53, 62, 63, 64, 1023 }) do
	platform.fd_set_set(fds, fd)
	platform.fd_set_set(fds, fd) -- setting twice must be idempotent
end
for _, fd in ipairs({ 0, 52, 53, 62, 63, 64, 1023 }) do
	check(platform.fd_set_isset(fds, fd))
end
check(not platform.fd_set_isset(fds, 54))
check(not pcall(platform.fd_set_set, fds, 1024))

-- Fail on accidental references to old lexical state after module extraction.
setmetatable(_G, {
	__index = function(_, key)
		error("unexpected global: " .. key)
	end,
})
local ctx = {
	active_tab = 1,
	search_query = "",
	hidden = {},
	collapsed = {},
	initialized_items = {},
	initialized_modules = {},
	history_selected = {},
	history_prev_collapsed = true,
}
ctx.state = {
	columns = {
		names = { "x", "arr", "1" },
		kinds = { "variable", "variable", "variable" },
		types = { "Int64", "Vector", "Int64" },
		values = { "42", "[1]", "1" },
		exprs = { "x", "arr", "arr[1]" },
		modules = { "Main", "Main", "Main" },
		depths = { 0, 0, 1 },
		has_children = { false, true, false },
	},
}
ctx.initialized_modules.Main = true
local built = rows(ctx)
check(#built == 3 and built[2].name == "x" and built[3].collapsed)
ctx.collapsed["Main/arr"] = false
check(#rows(ctx) == 4)
ctx.search_query = "42"
check(#rows(ctx) == 2 and rows(ctx)[2].name == "x")
ctx.search_query = ""
ctx.active_tab = 2
ctx.state.history = { "old()", "new()" }
ctx.state.history_prev_count = 1
built = rows(ctx)
check(built[1].kind == "hist_section" and built[1].collapsed)
check(built[#built].cmd == "new()")
ctx.history_prev_collapsed = false
check(rows(ctx)[2].cmd == "old()")
ctx.active_tab = 3
ctx.state.procedures = {
	{
		name = "f",
		code = 'f() = error("oops")',
		signature = "f()",
		status = "error",
		last_error = "oops",
		last_error_detail = "trace",
		last_error_line = 1,
	},
}
built = rows(ctx)
check(built[1].kind == "procedure")
for _, compact in ipairs({ true, false }) do
	local rendered = table.concat(preview.build(built[1], 80, compact, ctx.state), "\n")
	check(rendered:find("oops", 1, true) ~= nil)
end
ctx.state.failed_commands = { { id = 1, cmd = "bad()", error = "oops", error_detail = "trace", error_line = 1 } }
ctx.proc_errors_view = true
local failed = rows(ctx)[1]
check(failed.kind == "failed_cmd")
check(#preview.build(failed, 40, false, ctx.state) > 0)
check(
	table
		.concat(preview.build({ kind = "history", cmd = "bad()", status = "error" }, 80, false, ctx.state), "\n")
		:find("trace", 1, true)
)
ctx.active_tab = 4
ctx.state.packages = { { name = "Random", version = "1" } }
check(rows(ctx)[1].name == "Random")
ctx.active_tab = 5
check(rows(ctx)[1].kind == "guide_hdr")
ctx.search_query = "impossible-search-term"
check(rows(ctx)[1].kind == "empty_search")
check(sessions.canonical(".") ~= ".")
io.write("TUI: " .. count .. " assertions passed\n")
