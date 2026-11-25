-- Run from any directory: luajit /path/to/jEMach/test/tui.lua
local root = assert(arg[0]:match("^(.*)/test/[^/]+$"))
package.path = root .. "/scripts/?.lua;" .. package.path
local json = require("tui.json")
local text = require("tui.text")
local keys = require("tui.keys")
local row_views = require("tui.rows")
local rows, views = row_views.build, row_views.views
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
check(keys.normalize("\27[963u") == "σ")
check(keys.normalize("\27[117;5u") == "\21")
check(keys.normalize("\27OA") == "\27[A")
local queue = {}
keys.enqueue("j\27[B\27[99;5użσ", queue)
check(#queue == 5 and queue[2] == "\27[B" and queue[3] == "\3" and queue[4] == "ż" and queue[5] == "σ")
check(text.utf8_pop("zażółć") == "zażół")
check(text.utf8_pop("σ") == "")
check(text.is_printable_key("ż") and text.is_printable_key("A") and not text.is_printable_key("\27"))
check(text.base64_encode("Man") == "TWFu" and text.base64_encode("ab") == "YWI=")
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
		sizes = { 8, 800, 8 },
		has_children = { false, true, false },
	},
}
ctx.initialized_modules.Main = true
local built = rows(ctx)
check(#built == 3 and built[2].name == "x" and built[3].collapsed)
ctx.workspace_sort = "size"
local sorted_ws = rows(ctx)
check(sorted_ws[2].name == "arr" and sorted_ws[3].name == "x")
ctx.workspace_sort = "default"
ctx.collapsed["Main/arr"] = false
check(#rows(ctx) == 4)
-- Test Workspace 2D slice inspector preview (without numeric diagnostic stats or sparklines)
ctx.state.inspector = {
	ok = true,
	expr = "arr",
	mod = "Main",
	kind = "matrix",
	type = "Matrix{Float64}",
	dims = "2×2",
	size_bytes = 32,
	row = 1,
	col = 1,
	total_rows = 2,
	total_cols = 2,
	headers = { "ROW \\ COL", "[:, 1]", "[:, 2]" },
	rows = { { "[1, :]", "1.5", "2.5" }, { "[2, :]", "3.5", "4.5" } },
}
local slice_preview = text.strip_ansi(table.concat(preview.build(built[3], 80, false, ctx.state), "\n"))
check(slice_preview:find("Rows 1–2 of 2", 1, true) ~= nil and slice_preview:find("4.5", 1, true) ~= nil)
check(slice_preview:find("NaN", 1, true) == nil)
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
	{
		name = "fast_fn",
		code = "fast_fn(x) = 2x",
		signature = "fast_fn(x)",
		status = "ok",
		origin = "modified",
		generation = 2,
		prev_gen = 1,
		prev_time_ms = 10.0,
		time_ms = 4.0,
		bench_samples = 7,
		min_time_ms = 3.8,
		max_time_ms = 4.5,
		alloc_bytes = 0,
	},
}
built = rows(ctx)
check(built[1].kind == "procedure" and #built == 2)
local bench_prev = text.strip_ansi(table.concat(preview.build(built[2], 80, false, ctx.state), "\n"))
check(bench_prev:find("-60.0% vs v1", 1, true) ~= nil and bench_prev:find("median of 7", 1, true) ~= nil)
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
check(rows(ctx)[1].kind == "empty_plots")
ctx.state.plots = { { id = 1, title = "plot(sin)", timestamp = "12:00:00", path = "/tmp/nonexistent_plot.png", width = 800, height = 600, bytes = 4096 } }
check(rows(ctx)[1].kind == "plot" and rows(ctx)[1].width == 800)
local plot_out, plot_hb = {}, {}
local plot_split = views[5].render_split({
	out_buf = plot_out, display_rows = rows(ctx), row_hitboxes = plot_hb,
	term_rows = 24, term_cols = 100, header_rows = 4, content_rows = 18,
	total = 1, cursor = 1, compute_win_start = function() return 1 end, backend = "standalone",
})
check(plot_split > 4 and text.strip_ansi(table.concat(plot_out)):find("plot(sin)", 1, true) ~= nil)
local empty_plots_out = {}
check(views[5].render_empty(empty_plots_out, 5, 100) > 5)
ctx.active_tab = 6
check(rows(ctx)[1].kind == "guide_hdr")
ctx.search_query = "impossible-search-term"
check(rows(ctx)[1].kind == "empty_search")
check(sessions.canonical(".") ~= ".")

-- Exercise each view's rendering in isolation, with unexpected globals rejected.
local headers = { "NAME", "COMMAND", "FUNCTION", "PACKAGE", "PLOT", "DESCRIPTION" }
for i, view in ipairs(views) do
	local header = view.header(100, {}, false)
	check(text.strip_ansi(header):find(headers[i], 1, true), "missing header for tab " .. i)
end
local failed_header, failed_hitbox = views[3].header(100, { {} }, true)
check(text.strip_ansi(failed_header):find("FAILED COMMAND", 1, true) and failed_hitbox.x2 == 100)

local function rendered(view, row, selected, options)
	local out = {}
	view.render_row(out, row, selected, 100, options or {})
	return text.strip_ansi(table.concat(out))
end
ctx.search_query = ""
ctx.active_tab = 1
built = rows(ctx)
check(rendered(views[1], built[1], true, { col_cursor = 1 }):find("Main", 1, true))
check(rendered(views[1], built[2], true, { col_cursor = 2 }):find("42", 1, true))
ctx.active_tab = 2
ctx.history_selected[2] = true
built = rows(ctx)
check(rendered(views[2], built[#built], true, { history_selected = ctx.history_selected }):find("[✓]", 1, true))
ctx.active_tab = 4
check(rendered(views[4], rows(ctx)[1], true):find("Random", 1, true))
ctx.active_tab = 6
check(rendered(views[6], rows(ctx)[1], false):find("Julia", 1, true))

ctx.active_tab = 3
ctx.proc_errors_view = false
built = rows(ctx)
local split_output, hitboxes = {}, {}
local scroll, key, split_row = views[3].render_split({
	out_buf = split_output, display_rows = built, row_hitboxes = hitboxes,
	term_rows = 24, term_cols = 100, header_rows = 4, content_rows = 18,
	total = #built, cursor = 1, preview_scroll = 999, preview_key = "p:f",
	compute_win_start = function() return 1 end, state = ctx.state,
})
check(key == "p:f" and scroll >= 0 and scroll < 999)
check(split_row > 4 and hitboxes[5] == 1)
check(text.strip_ansi(table.concat(split_output)):find("oops", 1, true))
ctx.proc_errors_view = true
built = rows(ctx)
split_output, hitboxes = {}, {}
scroll, key, split_row = views[3].render_split({
	out_buf = split_output, display_rows = built, row_hitboxes = hitboxes,
	term_rows = 24, term_cols = 60, header_rows = 4, content_rows = 18,
	total = #built, cursor = 1, preview_scroll = 12, preview_key = "p:f",
	compute_win_start = function() return 1 end, state = ctx.state,
})
check(key == "f:1" and scroll == 0 and hitboxes[5] == 1)
check(text.strip_ansi(table.concat(split_output)):find("bad()", 1, true))
local empty_output = {}
check(views[3].render_empty(empty_output, 5, 100) == 10)
check(text.strip_ansi(table.concat(empty_output)):find("Quick Start", 1, true))
io.write("TUI: " .. count .. " assertions passed\n")
