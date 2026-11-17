local theme = require("tui.theme")
local BOLD = theme.BOLD
local ITALIC = theme.ITALIC
local RESET = theme.RESET
local FG_CYAN = theme.FG_CYAN
local FG_AQUA = theme.FG_AQUA
local FG_GREEN = theme.FG_GREEN
local FG_YELLOW = theme.FG_YELLOW
local FG_ORANGE = theme.FG_ORANGE
local FG_PURPLE = theme.FG_PURPLE
local FG_WHITE = theme.FG_WHITE
local FG_LIGHT_GRAY = theme.FG_LIGHT_GRAY
local FG_GRAY = theme.FG_GRAY
local JL_KEYWORDS = {
	["function"] = true,
	["end"] = true,
	["return"] = true,
	["if"] = true,
	["else"] = true,
	["elseif"] = true,
	["for"] = true,
	["while"] = true,
	["in"] = true,
	["let"] = true,
	["begin"] = true,
	["try"] = true,
	["catch"] = true,
	["finally"] = true,
	["using"] = true,
	["import"] = true,
	["export"] = true,
	["struct"] = true,
	["mutable"] = true,
	["const"] = true,
	["global"] = true,
	["local"] = true,
	["macro"] = true,
	["module"] = true,
	["baremodule"] = true,
	["quote"] = true,
	["do"] = true,
}
local JL_TYPES = {
	["Int"] = true,
	["Int64"] = true,
	["Int32"] = true,
	["Int16"] = true,
	["Int8"] = true,
	["UInt"] = true,
	["UInt64"] = true,
	["UInt32"] = true,
	["UInt16"] = true,
	["UInt8"] = true,
	["Float64"] = true,
	["Float32"] = true,
	["String"] = true,
	["Char"] = true,
	["Vector"] = true,
	["Matrix"] = true,
	["Array"] = true,
	["DataFrame"] = true,
	["Bool"] = true,
	["Dict"] = true,
	["Set"] = true,
	["Symbol"] = true,
	["Any"] = true,
	["Nothing"] = true,
	["Missing"] = true,
	["Tuple"] = true,
	["NamedTuple"] = true,
	["Union"] = true,
	["Number"] = true,
	["Real"] = true,
	["Integer"] = true,
	["Ref"] = true,
}
local JL_LITERALS = {
	["true"] = true,
	["false"] = true,
	["nothing"] = true,
	["missing"] = true,
	["undef"] = true,
}

local function highlight_julia_line(line)
	local out = {}
	local pos = 1
	local len = #line

	while pos <= len do
		local c = line:sub(pos, pos)
		if c == "#" then
			table.insert(out, FG_GRAY .. ITALIC .. line:sub(pos) .. RESET)
			break
		elseif c == '"' or c == "'" then
			local quote = c
			local end_pos = pos + 1
			while end_pos <= len do
				local ch = line:sub(end_pos, end_pos)
				if ch == "\\" then
					end_pos = end_pos + 2
				elseif ch == quote then
					end_pos = end_pos + 1
					break
				else
					end_pos = end_pos + 1
				end
			end
			table.insert(out, FG_GREEN .. line:sub(pos, end_pos - 1) .. RESET)
			pos = end_pos
		elseif c == ":" and pos < len and line:sub(pos + 1, pos + 1):match("[%a_]") then
			local sym_end = pos + 1
			while sym_end <= len and line:sub(sym_end, sym_end):match("[%w_!]") do
				sym_end = sym_end + 1
			end
			table.insert(out, FG_AQUA .. line:sub(pos, sym_end - 1) .. RESET)
			pos = sym_end
		elseif c == "@" and pos < len and line:sub(pos + 1, pos + 1):match("[%a_]") then
			local mac_end = pos + 1
			while mac_end <= len and line:sub(mac_end, mac_end):match("[%w_!]") do
				mac_end = mac_end + 1
			end
			table.insert(out, FG_PURPLE .. line:sub(pos, mac_end - 1) .. RESET)
			pos = mac_end
		elseif c:match("[%a_]") then
			local word_end = pos + 1
			while word_end <= len and line:sub(word_end, word_end):match("[%w_!]") do
				word_end = word_end + 1
			end
			local w = line:sub(pos, word_end - 1)
			if JL_KEYWORDS[w] then
				table.insert(out, BOLD .. FG_PURPLE .. w .. RESET)
			elseif JL_TYPES[w] then
				table.insert(out, BOLD .. FG_CYAN .. w .. RESET)
			elseif JL_LITERALS[w] then
				table.insert(out, FG_ORANGE .. w .. RESET)
			else
				table.insert(out, FG_WHITE .. w .. RESET)
			end
			pos = word_end
		elseif c:match("%d") then
			local num_end = pos + 1
			while num_end <= len and line:sub(num_end, num_end):match("[%d%.eExXa-fA-F_]") do
				num_end = num_end + 1
			end
			table.insert(out, FG_YELLOW .. line:sub(pos, num_end - 1) .. RESET)
			pos = num_end
		elseif c:match("[%[%]%{%}%(%),;]") then
			table.insert(out, FG_LIGHT_GRAY .. c .. RESET)
			pos = pos + 1
		elseif c:match("[%+%-*%/%^=<>!&|~]") then
			table.insert(out, FG_AQUA .. c .. RESET)
			pos = pos + 1
		else
			table.insert(out, c)
			pos = pos + 1
		end
	end
	return table.concat(out)
end

return highlight_julia_line
