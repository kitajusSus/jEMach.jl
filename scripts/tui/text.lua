local function strip_ansi(s)
	return tostring(s or ""):gsub("\27%[[%d;]*[a-zA-Z]", "")
end

local function visible_len(s)
	local clean = strip_ansi(s)
	local _, count = clean:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return count
end

local function pad_right(s, width)
	s = tostring(s or "")
	local vlen = visible_len(s)
	if vlen >= width then
		return s
	end
	return s .. string.rep(" ", width - vlen)
end

local function truncate_visible(s, max_w)
	s = tostring(s or "")
	if max_w <= 0 then
		return ""
	end
	local clean = strip_ansi(s)
	local vlen = visible_len(clean)
	if vlen <= max_w then
		return s
	end
	if max_w == 1 then
		return "…"
	end
	local cur_w = 0
	local res = {}
	for c in clean:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if cur_w >= max_w - 1 then
			table.insert(res, "…")
			break
		end
		table.insert(res, c)
		cur_w = cur_w + 1
	end
	return table.concat(res)
end

local function wrap_text(s, max_w)
	s = tostring(s or "")
	if max_w <= 1 then
		return { s }
	end
	local chars = {}
	for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(chars, c)
	end
	if #chars == 0 then
		return { "" }
	end
	local lines = {}
	local i = 1
	while i <= #chars do
		local j = math.min(#chars, i + max_w - 1)
		if j < #chars then
			local min_break = i + math.floor(max_w * 0.65)
			for k = j, min_break, -1 do
				if chars[k] == " " or chars[k] == "\t" then
					j = k
					break
				end
			end
		end
		local chunk = {}
		for k = i, j do
			table.insert(chunk, chars[k])
		end
		local line_str = table.concat(chunk)
		if j < #chars and (chars[j] == " " or chars[j] == "\t") then
			line_str = line_str:gsub("%s+$", "")
		end
		table.insert(lines, line_str)
		i = j + 1
	end
	return lines
end

local function split_lines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("(.-)\r?\n") do
		table.insert(lines, line)
	end
	return lines
end

return {
	strip_ansi = strip_ansi,
	visible_len = visible_len,
	pad_right = pad_right,
	truncate_visible = truncate_visible,
	wrap_text = wrap_text,
	split_lines = split_lines,
}
