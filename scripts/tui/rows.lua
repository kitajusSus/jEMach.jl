-- The view modules own their rows and rendering; this table keeps tab order in one place.
local views = {
	require("tui.views.workspace"),
	require("tui.views.history"),
	require("tui.views.procedures"),
	require("tui.views.packages"),
	require("tui.views.guide"),
}

local function build_display_rows(ctx)
	local q = (ctx.search_query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	return views[ctx.active_tab].build(ctx, q)
end

return { build = build_display_rows, views = views }
