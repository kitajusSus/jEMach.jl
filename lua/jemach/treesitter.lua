local M = {}
local config = require("jemach.config")

function M.detect_julia_block()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row, col = cursor[1] - 1, cursor[2]

	-- Sprawdźmy czy mamy włączone podświetlanie składni przez tree-sittera dla języka julia
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "julia")
	if not ok or not parser then
		vim.notify("⚠️ Tree-sitter parser for Julia is not available. Using line-by-line fallback.", vim.log.levels.WARN)
		return M.fallback_detect_block()
	end

	local tree = parser:parse()[1]
	local root = tree:root()

	-- Znajdźmy najbardziej szczegółowy węzeł (node) pod kursorem
	local node = root:named_descendant_for_range(row, col, row, col)
	if not node then
		return nil, nil
	end

	-- Typy węzłów uznawane za "bloki najwyższego poziomu" (top-level blocks) w Julii
	local block_types = {
		function_definition = true,
		macro_definition = true,
		module_definition = true,
		struct_definition = true,
		for_statement = true,
		while_statement = true,
		if_statement = true,
		try_statement = true,
		let_statement = true,
		quote_statement = true,
		compound_statement = true, -- begin ... end
	}

	local target_node = nil
	local current = node

	-- Idziemy w górę drzewa składniowego, by znaleźć najbardziej ZEWNĘTRZNY blok
	while current do
		if block_types[current:type()] then
			target_node = current
		end
		current = current:parent()
	end

	-- Jeśli nie znaleźliśmy bloku, spróbujmy mniejsze wyrażenie, np. pojedyncze przypisanie
	if not target_node then
		current = node
		while current do
			local type = current:type()
			if type == "assignment" or type == "call_expression" or type == "macrocall_expression" then
				target_node = current
			end
			current = current:parent()
		end
	end

	if target_node then
		local start_row, _, end_row, _ = target_node:range()
		-- tree-sitter range zwraca index od 0 do row - 1. end_row wskazuje linię tuż za blokiem,
		-- lub ostatnią linijkę. Konwersja na 1-based indexing do linii w Neovimie:
		return start_row + 1, end_row + 1
	end

	return nil, nil
end

-- Ten sam kod co był w starym `init.lua`, jako fallback jeśli np. nie ma parsera
function M.fallback_detect_block()
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	local block_patterns = {
		{ start = "^%s*function%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*macro%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*module%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*struct%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*mutable%s+struct%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*begin%s*$", end_pat = "^%s*end%s*$" },
		{ start = "^%s*quote%s*$", end_pat = "^%s*end%s*$" },
		{ start = "^%s*let%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*for%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*while%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*if%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*try%s*$", end_pat = "^%s*end%s*$" },
	}

	for _, pattern in ipairs(block_patterns) do
		local start_line = nil
		local end_line = nil
		local depth = 0

		for i = current_line, 1, -1 do
			if lines[i]:match(pattern.start) then
				start_line = i
				break
			end
		end

		if start_line then
			depth = 1
			for i = start_line + 1, #lines do
				if lines[i]:match(pattern.start) then
					depth = depth + 1
				elseif lines[i]:match(pattern.end_pat) then
					depth = depth - 1
					if depth == 0 then
						end_line = i
						break
					end
				end
			end

			if end_line then
				return start_line, end_line
			end
		end
	end

	return nil, nil
end

function M.get_code_to_send()
	local mode = vim.api.nvim_get_mode().mode

	if mode == "v" or mode == "V" then
		local _, start_row, start_col, _ = unpack(vim.fn.getpos("'<"))
		local _, end_row, end_col, _ = unpack(vim.fn.getpos("'>"))
		local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)

		if #lines == 0 then
			return ""
		end

		if mode == "V" then
			return table.concat(lines, "\n")
		end

		if #lines == 1 then
			lines[1] = string.sub(lines[1], start_col, end_col)
		else
			lines[1] = string.sub(lines[1], start_col)
			lines[#lines] = string.sub(lines[#lines], 1, end_col)
		end
		return table.concat(lines, "\n")
	else
		if config.options.smart_block_detection then
			local start_line, end_line = M.detect_julia_block()
			if start_line and end_line then
				local block_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
				vim.notify(string.format("📦 Block (lines %d-%d)", start_line, end_line), vim.log.levels.INFO)
				return table.concat(block_lines, "\n")
			end
		end
		return vim.api.nvim_get_current_line()
	end
end

return M
