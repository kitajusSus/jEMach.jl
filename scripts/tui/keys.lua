local function normalize_key(k)
	if not k then
		return nil
	end
	-- Application cursor keys (SS3)
	if k == "\27OA" then
		return "\27[A"
	end
	if k == "\27OB" then
		return "\27[B"
	end
	if k == "\27OC" then
		return "\27[C"
	end
	if k == "\27OD" then
		return "\27[D"
	end
	if k == "\27OM" then
		return "\r"
	end

	-- Kitty keyboard protocol / CSI-u sequences (\27[<codepoint>;<modifiers>u)
	local csi_u_code, csi_u_mod = k:match("^\27%[(%d+)[:%d]*;?(%d*)[:%d]*u$")
	if csi_u_code then
		local code = tonumber(csi_u_code)
		local mod = tonumber(csi_u_mod) or 1
		if code == 27 then
			return "\27"
		elseif code == 13 then
			return "\r"
		elseif code == 9 then
			return "\t"
		elseif code == 127 or code == 8 then
			return "\127"
		elseif code == 99 and (mod == 5 or mod == 6) then -- Ctrl+C in CSI-u
			return "\3"
		elseif code >= 32 and code <= 126 then
			if mod == 1 then
				return string.char(code)
			elseif mod == 2 then -- Shift in CSI-u (e.g. ?, J, K, D)
				if code >= 97 and code <= 122 then
					return string.char(code - 32)
				elseif code == 47 then
					return "?"
				else
					return string.char(code)
				end
			end
		end
	end

	-- Extended cursor keys with modifiers (\27[1;...A)
	local arrow_dir = k:match("^\27%[1;%d+([ABCD])$")
	if arrow_dir then
		return "\27[" .. arrow_dir
	end

	return k
end

local function queue_keys(raw, input_queue)
	local pos = 1
	local len = #raw
	while pos <= len do
		if raw:sub(pos, pos) == "\27" then
			local esc_seq = raw:match("^\27%[<[%d;]+[Mm]", pos)
				or raw:match("^\27%[[%d;]*[a-zA-Z~u]", pos)
				or raw:match("^\27O[a-zA-Z]", pos)
			if esc_seq then
				table.insert(input_queue, normalize_key(esc_seq))
				pos = pos + #esc_seq
			else
				table.insert(input_queue, "\27")
				pos = pos + 1
			end
		else
			table.insert(input_queue, raw:sub(pos, pos))
			pos = pos + 1
		end
	end
end

return { normalize = normalize_key, enqueue = queue_keys }
