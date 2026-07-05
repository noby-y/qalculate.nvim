local process = require('qalc.process')
local parse = require('qalc.parse')
local complete = require('qalc.complete')

local M = {}

-- `function fname ...` -> fname; `variable vname ...` -> vname; otherwise the
-- first identifier on the line, covering the bare assignment-expression forms
-- `name := expr` / `name = expr` / `name(args) := expr` (man qalc's "Save
-- operator" section: e.g. `var1:=5`, `func1():=x+y`)
local function extract_name(line)
	local trimmed = vim.trim(line)

	local fname = trimmed:match('^function%s+([%w_]+)')
	if fname then
		return fname
	end

	local vname = trimmed:match('^variable%s+([%w_]+)')
	if vname then
		return vname
	end

	return trimmed:match('^([%w_]+)%s*%b()%s*:?=') or trimmed:match('^([%w_]+)%s*:?=')
end

local function current_line(bufnr)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
end

-- last buffer line whose extracted name matches (last, not first: if `name` is
-- redefined more than once, the last definition is the one actually in effect
-- by the time the buffer finishes evaluating)
local function find_defining_line(bufnr, name)
	local found = nil
	for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		if extract_name(line) == name then
			found = line
		end
	end
	return found
end

local function notify(msg, level)
	vim.notify(msg, level, { title = 'qalc' })
end

-- CRITICAL, confirmed empirically against qalc 5.11.0 -- and *not* what the
-- original design assumed: `save definitions` does not only persist the name
-- just `keep`-ed. In the same batch, it also sweeps up *every other*
-- `function`/`variable`-command definition currently in scope (fresh ones get
-- silently persisted too), and -- worse -- if the batch *redefines* a name that
-- is already permanent on disk without also re-`keep`ing it, that redefinition
-- wipes the permanent copy instead of leaving it alone. Resending the whole
-- buffer here (as originally planned) would therefore risk both leaking
-- unrelated temporary definitions to permanent storage and silently deleting
-- other, previously-saved definitions that happen to still have an un-kept
-- redefinition sitting in the buffer. Sending only the one defining line (never
-- the rest of the buffer) sidesteps both: confirmed empirically that
-- already-persisted, unrelated names are left untouched when they're simply
-- never mentioned in a batch. The accepted trade-off is that a definition
-- whose expression depends on another buffer-local (not-yet-saved) name won't
-- resolve that dependency when saved in isolation -- a visible, re-triggerable
-- failure rather than a silent one, which is the right side to err on.
function M.save(bufnr, name)
	if not require('qalc').is_attached(bufnr) then
		notify('qalc: buffer is not attached (see :QalcAttach)', vim.log.levels.ERROR)
		return
	end

	local defining_line, resolved_name
	if name then
		defining_line = find_defining_line(bufnr, name)
		resolved_name = name
	else
		defining_line = current_line(bufnr)
		resolved_name = extract_name(defining_line)
	end

	if not resolved_name or not defining_line then
		notify(
			'qalc: could not determine a name to save -- put the cursor on the defining line, or pass one explicitly',
			vim.log.levels.ERROR
		)
		return
	end

	local input, hints = parse.parse_input({ defining_line })
	local send_input = vim.list_extend({}, input)
	table.insert(send_input, 'keep ' .. resolved_name)
	table.insert(send_input, 'save definitions')

	process.send(bufnr, send_input, require('qalc').config, function(raw_lines)
		-- isolate just the keep/save output from the one defining line's own
		-- (usually empty) output
		local consumed = parse.parse_results(input, raw_lines, hints).next_raw_pos
		local tail = {}
		for i = consumed, #raw_lines do
			tail[#tail + 1] = raw_lines[i]
		end

		if #tail == 1 and tail[1] == 'definitions saved' then
			complete.reload(bufnr)
			notify('qalc: saved ' .. resolved_name, vim.log.levels.INFO)
		else
			notify(
				'qalc: failed to save ' .. resolved_name .. (#tail > 0 and (' -- ' .. table.concat(tail, ' ')) or ''),
				vim.log.levels.ERROR
			)
		end
	end)
end

function M.delete(bufnr, name)
	if not require('qalc').is_attached(bufnr) then
		notify('qalc: buffer is not attached (see :QalcAttach)', vim.log.levels.ERROR)
		return
	end

	name = name or extract_name(current_line(bufnr))
	if not name then
		notify(
			'qalc: could not determine a name to delete -- put the cursor on its line, or pass one explicitly',
			vim.log.levels.ERROR
		)
		return
	end

	-- unlike save, a permanent name needs no buffer content resent: `delete` +
	-- `save definitions` is a self-contained disk-facing round trip. A
	-- buffer-local temporary name has nothing on disk to remove in the first
	-- place -- removing its line from the buffer already drops it from
	-- completion on the next run.
	process.send(bufnr, { 'delete ' .. name, 'save definitions' }, require('qalc').config, function(raw_lines)
		if #raw_lines == 1 and raw_lines[1] == 'definitions saved' then
			complete.reload(bufnr)
			notify('qalc: deleted ' .. name, vim.log.levels.INFO)
		else
			notify(
				'qalc: failed to delete ' .. name .. (#raw_lines > 0 and (' -- ' .. table.concat(raw_lines, ' ')) or ''),
				vim.log.levels.ERROR
			)
		end
	end)
end

return M
