-- turns raw `qalc -f -` stdout + the input lines that produced it into
-- { results = { [lnum]=lines[] }, diagnostics = { {lnum,severity,message}, ... } }
-- `lines[]` is usually one string, but can be more (see the multi-line-value
-- note in parse_results below).
--
-- NOTE ON DESIGN: this does NOT split stdout on blank lines into one-block-per-line
-- (the naive approach). Empirically (qalc 5.11.0), the blank line vspace inserts is
-- tied to "a value is about to be printed and something was already printed this
-- run" -- not to input-line boundaries. Two consecutive fully-erroring expressions,
-- for instance, put the blank line *inside* what would be the second expression's
-- own block (between its error: line and its result), not between the two
-- expressions. So instead this walks raw lines with a small state machine that
-- mirrors qalc's own emission rules: diagnostics are consumed greedily and
-- immediately, then at most one "value" line is consumed per input line, skipping
-- at most one separator blank first if one is pending.

local M = {}

local no_output_words = {
	'delete',
	'function',
	'variable',
	'save',
	'store',
	'keep',
	'unkeep',
}
local no_output_exact = {
	['MC'] = true,
	['MS'] = true,
	['M+'] = true,
	['M-'] = true,
}
local output_previous_words = {
	'set',
	'to',
	'convert',
	'assume',
	'base',
}
local output_previous_exact = {
	['approximate'] = true,
	['exact'] = true,
}

local blocked_exact = {
	quit = true,
	exit = true,
	mode = true,
	history = true,
	clear = true,
}
local blocked_words = { 'list', 'find', 'info' }

-- true if `line` is exactly `word` or starts with `word` followed by whitespace
-- (avoids `list` matching an identifier like `listenPort`)
local function starts_with_word(line, word)
	return line == word or line:sub(1, #word + 1) == (word .. ' ')
end

-- blank out commands that are meaningless (quit/exit) or expensive/pointless
-- (list/find/mode/history/info) as buffer content, plus bare `clear` (emits ANSI
-- screen-clear escapes over the pipe -- `clear history`/`clear stack` are left
-- alone, they don't). Returns a new array plus the 1-indexed line numbers blanked,
-- for a HINT diagnostic each.
function M.parse_input(input)
	local blanked = {}
	local hints = {}

	for i, line in ipairs(input) do
		local trimmed = vim.trim(line)
		local blocked = blocked_exact[trimmed] or false

		if not blocked then
			for _, word in ipairs(blocked_words) do
				if starts_with_word(trimmed, word) then
					blocked = true
					break
				end
			end
		end

		if blocked then
			blanked[i] = ''
			hints[#hints + 1] = i
		else
			blanked[i] = line
		end
	end

	return blanked, hints
end

local function classify_bucket(line)
	local trimmed = vim.trim(line)

	if trimmed == '' or trimmed:sub(1, 1) == '#' then
		return 'no_output'
	end
	if no_output_exact[trimmed] then
		return 'no_output'
	end
	for _, word in ipairs(no_output_words) do
		if starts_with_word(trimmed, word) then
			return 'no_output'
		end
	end
	-- `clear history`/`clear stack`: confirmed empirically to never produce output
	-- (unlike the rest of output_previous_words), regardless of prior result state
	if starts_with_word(trimmed, 'clear') then
		return 'no_output'
	end
	if output_previous_exact[trimmed] then
		return 'output_previous'
	end
	for _, word in ipairs(output_previous_words) do
		if starts_with_word(trimmed, word) then
			return 'output_previous'
		end
	end
	if trimmed:sub(1, 2) == '->' then
		return 'output_previous'
	end

	return 'normal'
end

-- byte index (and match width) of the first depth-0 `=` or `≈` in `line`, or nil.
-- Depth-tracked so `solve(x = 10) = 10` splits after the *second* `=`.
local function find_top_level_equals(line)
	local depth = 0
	local i = 1
	local len = #line

	while i <= len do
		local byte = line:sub(i, i)
		if byte == '(' or byte == '[' then
			depth = depth + 1
		elseif byte == ')' or byte == ']' then
			depth = depth - 1
		elseif depth == 0 and byte == '=' then
			return i, 1
		elseif depth == 0 and line:sub(i, i + 2) == '\226\137\136' then -- utf8 '≈' U+2248
			return i, 3
		end
		i = i + 1
	end

	return nil
end

local function is_value_line(line)
	return find_top_level_equals(line) ~= nil
end

-- like is_value_line, but never true for an explicit error:/warning: line even
-- on the (so-far unseen, but not provably impossible) chance one contains a
-- depth-0 `=` of its own -- used only to decide whether to keep extending an
-- already-started value block (§ multi-line values below), where the
-- consequence of a false positive (merging a diagnostic into the value) is
-- worse than the consequence of a false negative (ending the block one line
-- early, same as before this existed)
local function is_continuation_line(line)
	if line == '' or line:match('^error: ') or line:match('^warning: ') then
		return false
	end
	return is_value_line(line)
end

local function value_after_equals(line)
	local pos, width = find_top_level_equals(line)
	if not pos then
		return line
	end
	return vim.trim(line:sub(pos + width))
end

-- classifies one raw (non-blank, non-value) line as ERROR/WARN (explicit prefix) or
-- GENERIC (anything else -- "Illegal name.", "Unrecognized option.", "No
-- user-defined variable...", etc.). GENERIC messages from output_previous commands
-- are further split by prefix below: empirically, "Unrecognized ..." failures
-- (unknown option/assumption name) are still followed by a value slot (often
-- empty), while "Illegal ..." failures (recognized option, bad value) are a hard
-- stop, like error:/warning:. This distinction cannot be derived structurally --
-- it's a fixed, empirically-verified fact about libqalculate's CLI, so any
-- message that doesn't fit either learned pattern is treated as suppressing (the
-- safer default: it risks losing a real echoed value rather than misattributing
-- the *next* input line's own result).
local function classify_diagnostic(line)
	local err = line:match('^error: (.+)$')
	if err then
		return 'ERROR', err
	end
	local warn = line:match('^warning: (.+)$')
	if warn then
		return 'WARN', warn
	end
	return 'GENERIC', line
end

function M.parse_results(input_lines, raw_lines, hints)
	local results = {}
	local diagnostics = {}
	local pos = 1
	local n = #raw_lines
	local pending_separator = false
	local had_result = false

	for i, line in ipairs(input_lines) do
		local bucket = classify_bucket(line)

		if bucket ~= 'no_output' then
			local force_value = false
			local suppress_value = false

			while pos <= n and raw_lines[pos] ~= '' and not is_value_line(raw_lines[pos]) do
				local kind, message = classify_diagnostic(raw_lines[pos])
				diagnostics[#diagnostics + 1] = {
					lnum = i - 1,
					severity = (kind == 'ERROR') and vim.diagnostic.severity.ERROR or vim.diagnostic.severity.WARN,
					message = message,
				}
				if kind == 'GENERIC' then
					if message:match('^Unrecognized ') then
						force_value = true
					else
						suppress_value = true
					end
				end
				pos = pos + 1
			end

			local want_value = (bucket == 'normal')
				or (bucket == 'output_previous' and not suppress_value and (force_value or had_result))

			if want_value then
				if pending_separator and pos <= n and raw_lines[pos] == '' then
					pos = pos + 1
				end
				if pos <= n then
					local first = raw_lines[pos]
					pos = pos + 1

					if first ~= '' then
						local value_lines = { first }
						-- A value can itself span more than one raw line -- confirmed for
						-- equation-solving: `f(x) = x` prints the (possibly simplified)
						-- equation on one line and its solution(s) ("x = 1 or x = 0") on
						-- the next, with *no* blank line between them (vspace's blank only
						-- separates *different* inputs' results, per pending_separator
						-- above -- never appears inside one input's own block). So
						-- greedily keep consuming further non-blank, value-shaped lines
						-- here as part of the same block.
						while pos <= n and is_continuation_line(raw_lines[pos]) do
							value_lines[#value_lines + 1] = raw_lines[pos]
							pos = pos + 1
						end

						if #value_lines == 1 then
							-- single line: strip the echoed expression, keep just the value (the source buffer line already shows the expression itself)
							results[i] = { value_after_equals(first) }
						else
							-- multi-line: each line carries distinct information, no stripping needed
							results[i] = value_lines
						end

						had_result = true
						pending_separator = true
					else
						pending_separator = false
					end
				end
			end
		end
	end

	for _, lnum in ipairs(hints) do
		diagnostics[#diagnostics + 1] = {
			lnum = lnum - 1,
			severity = vim.diagnostic.severity.HINT,
			message = 'This command is designed for interactive use; it has been disabled in qalc.nvim.',
		}
	end

	-- one past the last raw line consumed for `input_lines` -- lets a caller that
	-- appended extra commands after the real buffer content (the `list` tier in
	-- §7.2, or a combined `info <name>` doc lookup in §7.4) find where its own
	-- appended output begins, without needing a marker to search for
	return { results = results, diagnostics = diagnostics, next_raw_pos = pos }
end

return M
