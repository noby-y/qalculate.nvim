-- two-tier completion cache (global/builtin + per-buffer user-defined) and the
-- blink.cmp completion source built on top of it

local process = require('qalc.process')
local parse = require('qalc.parse')

local M = {}

-- blink.cmp's CompletionItemKind values, hardcoded rather than required from
-- blink.cmp: this module only needs to *shape* data to blink's contract, and
-- blink.cmp is the one that requires *this* module (via the user's own
-- `sources.providers.qalc = { module = 'qalc.complete' }`), never the reverse --
-- so there is no runtime dependency on blink.cmp being installed at all.
local KIND = { Function = 3, Variable = 6, Unit = 11 }

local function qalc_config()
	return require('qalc').config
end

-- ---------------------------------------------------------------------------
-- global/builtin tier (§7.1): four one-shot `qalc --list-*` invocations,
-- independent of any buffer's evaluation job. Loaded once per session (already
-- includes anything permanently kept+saved by the user, interleaved with true
-- builtins) and cached indefinitely until reload() (§7.4/§8).
-- ---------------------------------------------------------------------------

local global_items -- nil until first load() completes
local global_by_name -- name -> kind, nil until loaded
local global_doc_cache = {} -- name -> doc string
local loading = false

local function run_argv(args, callback)
	local stdout_lines = {}
	vim.fn.jobstart(args, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if data then
				stdout_lines = data
			end
		end,
		on_exit = function()
			if stdout_lines[#stdout_lines] == '' then
				table.remove(stdout_lines)
			end
			callback(stdout_lines)
		end,
	})
end

-- tab-separated, alias-slash-separated columnar format (confirmed §9/§10): one
-- or two names per line, each possibly a `/`-separated alias list
local function parse_list_flag_output(lines, kind, items, by_name)
	for _, line in ipairs(lines) do
		if line ~= '' then
			for _, cell in ipairs(vim.split(line, '\t+')) do
				if cell ~= '' then
					for _, alias in ipairs(vim.split(cell, ' / ', { plain = true })) do
						if alias ~= '' and not by_name[alias] then
							items[#items + 1] = { label = alias, kind = kind }
							by_name[alias] = kind
						end
					end
				end
			end
		end
	end
end

function M.load()
	if global_items or loading then
		return
	end
	loading = true

	local specs = {
		{ flag = '--list-functions', kind = KIND.Function },
		{ flag = '--list-variables', kind = KIND.Variable },
		{ flag = '--list-units', kind = KIND.Unit },
		{ flag = '--list-prefixes', kind = KIND.Unit },
	}

	local items = {}
	local by_name = {}
	local remaining = #specs

	for _, spec in ipairs(specs) do
		run_argv({ 'qalc', spec.flag }, function(lines)
			parse_list_flag_output(lines, spec.kind, items, by_name)
			remaining = remaining - 1
			if remaining == 0 then
				global_items = items
				global_by_name = by_name
				loading = false
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- user-defined tier (§7.2): re-derived from the trailing `list` output after
-- every buffer evaluation run (appended by init.lua's run(), not a separate
-- process)
-- ---------------------------------------------------------------------------

-- user_items[bufnr] = { items = {label,kind}[], by_name = { [name]=kind } }
local user_items = {}
local user_doc_cache = {} -- user_doc_cache[bufnr] = { name=, changedtick=, doc= }

local function parse_user_list(raw_lines)
	local items = {}
	local by_name = {}

	local i, n = 1, #raw_lines
	while i <= n and raw_lines[i] ~= 'Variables:' and raw_lines[i] ~= 'Functions:' do
		i = i + 1
	end

	if raw_lines[i] == 'Variables:' then
		i = i + 2 -- skip "Variables:" and the "Name...Value" header row
		while raw_lines[i] and raw_lines[i] ~= '' do
			local name = vim.split(raw_lines[i], '\t+')[1]
			if name and name ~= '' then
				items[#items + 1] = { label = name, kind = KIND.Variable }
				by_name[name] = KIND.Variable
			end
			i = i + 1
		end
		i = i + 1 -- skip the blank line closing the Variables block
	end

	if raw_lines[i] == 'Functions:' then
		i = i + 1
		while raw_lines[i] and raw_lines[i] ~= '' do
			items[#items + 1] = { label = raw_lines[i], kind = KIND.Function }
			by_name[raw_lines[i]] = KIND.Function
			i = i + 1
		end
	end

	return items, by_name
end

function M.update_user(bufnr, raw_lines)
	local items, by_name = parse_user_list(raw_lines)
	user_items[bufnr] = { items = items, by_name = by_name }
end

function M.clear_buffer(bufnr)
	user_items[bufnr] = nil
	user_doc_cache[bufnr] = nil
end

-- called after :QalcSave/:QalcDelete: the saved/deleted name graduating to/from
-- the global tier changes which doc-lookup path applies to it, and the global
-- --list-* tier itself is now stale (it was snapshotted before this change)
function M.reload(bufnr)
	user_items[bufnr] = nil
	user_doc_cache[bufnr] = nil
	global_items = nil
	global_by_name = nil
	global_doc_cache = {}
	M.load()
end

-- ---------------------------------------------------------------------------
-- §7.3 merge/priority
-- ---------------------------------------------------------------------------

function M.get_completions(bufnr)
	local merged = {}
	local seen = {}

	local user = user_items[bufnr]
	if user then
		for _, item in ipairs(user.items) do
			if not seen[item.label] then
				seen[item.label] = true
				merged[#merged + 1] = item
			end
		end
	end

	if global_items then
		for _, item in ipairs(global_items) do
			if not seen[item.label] then
				seen[item.label] = true
				merged[#merged + 1] = item
			end
		end
	end

	return merged
end

-- ---------------------------------------------------------------------------
-- markdown formatting for `info` output (for blink.cmp hover docs). `info`'s
-- own convention (confirmed against qalc 5.11.0): a blank line always
-- separates distinct fields/sections, or distinct entities when a name
-- resolves to more than one (e.g. "c" is both a variable and a prefix, shown
-- as two blank-line-separated blocks).
-- ---------------------------------------------------------------------------

local function paragraphs(raw)
	local paras = {}
	local current = {}
	for _, line in ipairs(raw) do
		if vim.trim(line) == '' then
			if #current > 0 then
				paras[#paras + 1] = current
				current = {}
			end
		else
			current[#current + 1] = line
		end
	end
	if #current > 0 then
		paras[#paras + 1] = current
	end
	return paras
end

local function join_para(p)
	return table.concat(p, ' ')
end

-- collapses a field line's tab-padded columns ("Names:\t\t\tm / meter") down
-- to a single space, without touching the wording
local function collapse_line(line)
	return (line:gsub('%s+', ' '))
end

-- Variable/unit/prefix `info` output has no blank line separating its own
-- fields (Names/Value/...) from the entity header -- it all lands in one
-- paragraph, one field per raw line, unlike function info where each
-- paragraph is a distinct section.
local function format_fields(paras)
	local out = {}
	for i, p in ipairs(paras) do
		if i > 1 then
			out[#out + 1] = ''
		end
		out[#out + 1] = '**' .. collapse_line(p[1]) .. '**'
		for j = 2, #p do
			out[#out + 1] = '- ' .. collapse_line(p[j])
		end
	end
	return table.concat(out, '\n')
end

-- Function info gets a bold title, a fenced signature block, and an
-- **Arguments** list; the Arguments section is the one part that must stay
-- one-line-per-argument rather than being flattened into prose like the
-- description/example paragraphs around it. Variable/unit/prefix info instead
-- goes through format_fields() to keep its field-per-line structure intact.
local function format_info(raw)
	local paras = paragraphs(raw)
	if #paras == 0 then
		return nil
	end

	if not paras[1][1]:match('^Function:') then
		return format_fields(paras)
	end

	local out = { '**' .. join_para(paras[1]) .. '**' }
	if paras[2] then
		out[#out + 1] = '```'
		out[#out + 1] = join_para(paras[2])
		out[#out + 1] = '```'
	end
	for i = 3, #paras do
		local p = paras[i]
		if p[1] == 'Arguments' then
			out[#out + 1] = '**Arguments**'
			for j = 2, #p do
				out[#out + 1] = '- ' .. p[j]
			end
		else
			out[#out + 1] = join_para(p)
		end
	end
	return table.concat(out, '\n')
end

-- ---------------------------------------------------------------------------
-- §7.4 docs (`info name`), two paths depending on which tier `name` resolves
-- from
-- ---------------------------------------------------------------------------

function M.get_doc(bufnr, name, callback)
	local user = user_items[bufnr]
	local is_buffer_local = user and user.by_name[name] ~= nil

	if not is_buffer_local then
		local cached = global_doc_cache[name]
		if cached ~= nil then
			callback(cached or nil) -- cached `false` means "looked up, no doc"
			return
		end
		if not (global_by_name and global_by_name[name]) then
			callback(nil)
			return
		end
		process.send(bufnr, { 'info ' .. name }, qalc_config(), function(raw_lines)
			local doc = format_info(raw_lines)
			global_doc_cache[name] = doc or false
			callback(doc)
		end)
		return
	end

	-- buffer-local temporary definition: a fresh process has never seen it, so
	-- `info <name>` alone would just report "not a valid ... unit" -- resend the
	-- buffer's content first (same trick :QalcSave needs, §8) so `info` sees it.
	-- Cached by changedtick since the defining line(s) can themselves change on
	-- the very next edit.
	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = user_doc_cache[bufnr]
	if cached and cached.name == name and cached.changedtick == changedtick then
		callback(cached.doc)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local input, hints = parse.parse_input(lines)
	local send_input = vim.list_extend({}, input)
	table.insert(send_input, 'info ' .. name)

	process.send(bufnr, send_input, qalc_config(), function(raw_lines)
		-- `info`'s own output has no unique marker to search for (unlike `list`'s
		-- "Variables:"/"Functions:"), so re-derive exactly how many raw lines the
		-- buffer's own content consumed and take everything after as the doc
		local consumed = parse.parse_results(input, raw_lines, hints).next_raw_pos
		local doc_lines = {}
		for i = consumed, #raw_lines do
			doc_lines[#doc_lines + 1] = raw_lines[i]
		end
		local doc = format_info(doc_lines)

		user_doc_cache[bufnr] = { name = name, changedtick = changedtick, doc = doc }
		callback(doc)
	end)
end

return M
