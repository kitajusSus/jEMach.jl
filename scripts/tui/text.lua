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

local function utf8_pop(s)
	s = tostring(s or "")
	local n = #s
	if n == 0 then
		return ""
	end
	local i = n
	while i > 1 do
		local b = s:byte(i)
		if b < 128 or b >= 192 then
			break
		end
		i = i - 1
	end
	return s:sub(1, i - 1)
end

local function is_printable_key(k)
	if type(k) ~= "string" or k == "" then
		return false
	end
	if #k == 1 then
		local b = k:byte(1)
		return b >= 32 and b <= 126
	end
	return k:match("^[\194-\244][\128-\191]+$") ~= nil
end

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
	data = tostring(data or "")
	local out = {}
	local n = #data
	local i = 1
	while i <= n do
		local b1 = data:byte(i) or 0
		local b2 = data:byte(i + 1) or 0
		local b3 = data:byte(i + 2) or 0
		local rem = n - i + 1
		local c1 = math.floor(b1 / 4) + 1
		local c2 = ((b1 % 4) * 16 + math.floor(b2 / 16)) + 1
		local c3 = ((b2 % 16) * 4 + math.floor(b3 / 64)) + 1
		local c4 = (b3 % 64) + 1
		out[#out + 1] = B64_CHARS:sub(c1, c1)
		out[#out + 1] = B64_CHARS:sub(c2, c2)
		out[#out + 1] = (rem >= 2) and B64_CHARS:sub(c3, c3) or "="
		out[#out + 1] = (rem >= 3) and B64_CHARS:sub(c4, c4) or "="
		i = i + 3
	end
	return table.concat(out)
end

return {
	strip_ansi = strip_ansi,
	visible_len = visible_len,
	pad_right = pad_right,
	truncate_visible = truncate_visible,
	wrap_text = wrap_text,
	split_lines = split_lines,
	utf8_pop = utf8_pop,
	is_printable_key = is_printable_key,
	base64_encode = base64_encode,
}
