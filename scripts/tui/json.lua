-- JSON codec shared by state ingestion, RPC and session discovery.
local M = { null = {} }

local function utf8(cp)
	if cp < 0x80 then
		return string.char(cp)
	end
	if cp < 0x800 then
		return string.char(0xc0 + math.floor(cp / 64), 0x80 + cp % 64)
	end
	if cp < 0x10000 then
		return string.char(0xe0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
	end
	return string.char(
		0xf0 + math.floor(cp / 262144),
		0x80 + math.floor(cp / 4096) % 64,
		0x80 + math.floor(cp / 64) % 64,
		0x80 + cp % 64
	)
end

function M.escape(value)
	return (
		tostring(value or ""):gsub('[%z\1-\31\\"]', function(c)
			return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" })[c]
				or string.format("\\u%04x", c:byte())
		end)
	)
end

function M.decode(s)
	local pos = 1
	local function ws()
		local _, last = s:find("^[ \t\r\n]*", pos)
		pos = (last or pos - 1) + 1
	end
	local function hex4()
		local hex = s:sub(pos, pos + 3)
		assert(#hex == 4 and hex:match("^%x%x%x%x$"), "invalid Unicode escape")
		pos = pos + 4
		return tonumber(hex, 16)
	end
	local function str()
		assert(s:sub(pos, pos) == '"', "expected JSON string")
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			pos = pos + 1
			if c == '"' then
				return table.concat(out)
			end
			if c == "\\" then
				local esc = s:sub(pos, pos)
				pos = pos + 1
				if esc == "u" then
					local cp = hex4()
					if cp >= 0xd800 and cp <= 0xdbff then
						assert(s:sub(pos, pos + 1) == "\\u", "missing low surrogate")
						pos = pos + 2
						local low = hex4()
						assert(low >= 0xdc00 and low <= 0xdfff, "invalid low surrogate")
						cp = 0x10000 + (cp - 0xd800) * 1024 + low - 0xdc00
					else
						assert(cp < 0xdc00 or cp > 0xdfff, "unpaired low surrogate")
					end
					out[#out + 1] = utf8(cp)
				else
					local decoded = ({
						['"'] = '"',
						["\\"] = "\\",
						["/"] = "/",
						n = "\n",
						r = "\r",
						t = "\t",
						b = "\b",
						f = "\f",
					})[esc]
					assert(decoded, "invalid JSON escape")
					out[#out + 1] = decoded
				end
			else
				assert(c:byte() >= 32, "unescaped control character")
				out[#out + 1] = c
			end
		end
		error("unterminated JSON string")
	end
	local value
	value = function(depth)
		assert(depth < 128, "JSON nesting limit exceeded")
		ws()
		local c = s:sub(pos, pos)
		if c == '"' then
			return str()
		end
		if c == "{" or c == "[" then
			local object = c == "{"
			local close = object and "}" or "]"
			local out = {}
			pos = pos + 1
			ws()
			if s:sub(pos, pos) == close then
				pos = pos + 1
				return out
			end
			while true do
				ws()
				local key
				if object then
					key = str()
					ws()
					assert(s:sub(pos, pos) == ":", "expected colon")
					pos = pos + 1
				else
					key = #out + 1
				end
				out[key] = value(depth + 1)
				ws()
				c = s:sub(pos, pos)
				pos = pos + 1
				if c == close then
					return out
				end
				assert(c == ",", "expected comma or closing delimiter")
			end
		end
		for literal, decoded in pairs({ ["true"] = true, ["false"] = false, ["null"] = M.null }) do
			if s:sub(pos, pos + #literal - 1) == literal then
				pos = pos + #literal
				return decoded
			end
		end
		local token = s:match("^%-?%d+%.?%d*[eE][+%-]?%d+", pos)
			or s:match("^%-?%d+%.%d+", pos)
			or s:match("^%-?%d+", pos)
		assert(token, "invalid JSON value at " .. pos)
		assert(not token:match("^%-?0%d") and not token:match("%.%D"), "invalid JSON number")
		pos = pos + #token
		local number = tonumber(token)
		assert(number and number ~= math.huge and number ~= -math.huge, "JSON number out of range")
		return number
	end
	local result = value(0)
	ws()
	assert(pos > #s, "trailing JSON input")
	return result
end

return M
