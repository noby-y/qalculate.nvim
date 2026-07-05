-- renders parsed results as virt_lines and diagnostics as virtual text -- two
-- independent layers, both keyed by the plugin's own namespace, so results (below
-- the source line) and diagnostics (inline on it) never collide even when both
-- fire for the same line

local M = {}

-- vtexts[bufnr][lnum] = last-rendered result string (1-indexed lnum; a
-- multi-line result is newline-joined here so :QalcYank pastes it as one
-- multi-line paste). Kept around, not just rendered, so :QalcYank can read
-- back the value without re-querying qalc.
M.vtexts = {}

local function clear_results(namespace, bufnr)
	M.vtexts[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

local function clear_diagnostics(namespace, bufnr)
	vim.diagnostic.reset(namespace, bufnr)
end

local function clear_all(namespace, bufnr)
	clear_results(namespace, bufnr)
	clear_diagnostics(namespace, bufnr)
end

local function update_results(namespace, bufnr, config, results)
	clear_results(namespace, bufnr)
	M.vtexts[bufnr] = {}

	for lnum, lines in pairs(results) do
		M.vtexts[bufnr][lnum] = table.concat(lines, '\n')

		-- one virt_line per raw line in the block (e.g. an equation's restated
		-- form plus its solution(s)); the sign only marks the first, since it's
		-- what ties the whole block back to the source line
		local virt_lines = {}
		for i, text in ipairs(lines) do
			virt_lines[i] = (i == 1)
					and { { config.sign .. ' ', config.highlights.sign }, { text, config.highlights.result } }
				or { { text, config.highlights.result } }
		end

		vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum - 1, 0, {
			virt_lines = virt_lines,
			-- a huge exact-integer/precision result must soft-wrap in the window rather
			-- than being truncated
			virt_lines_overflow = 'wrap',
		})
	end
end

local function update_diagnostics(namespace, bufnr, diagnostics)
	local items = {}

	for i, d in ipairs(diagnostics) do
		items[i] = {
			lnum = d.lnum,
			col = 0,
			severity = d.severity,
			message = d.message,
			source = 'qalc',
		}
	end

	vim.diagnostic.set(namespace, bufnr, items)
end

local function update_all(namespace, bufnr, config, parsed)
	update_results(namespace, bufnr, config, parsed.results)
	update_diagnostics(namespace, bufnr, parsed.diagnostics)
end

M.clear = {
	all = clear_all,
	results = clear_results,
	diagnostics = clear_diagnostics,
}

M.update = {
	all = update_all,
	results = update_results,
	diagnostics = update_diagnostics,
}

return M
