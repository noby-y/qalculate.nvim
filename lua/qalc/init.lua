local process = require('qalc.process')
local display = require('qalc.display')
local parser = require('qalc.parse')

local M = {}

-- scopes extmarks and diagnostics so we never touch other plugins'
local namespace = vim.api.nvim_create_namespace('qalc')

M.config = {
	cmd_args = {}, -- extra `-set "..."` options, e.g. { 'angle deg' }
	bufname = nil, -- default name for a new `:Qalc` buffer (nil = unnamed)
	set_ft = 'config', -- filetype applied to attached buffers ('' disables)
	attach_extension = '*.qalc', -- autocmd pattern for auto-attach ('' disables)
	yank_default_register = '+',
	sign = '→',
	highlights = { sign = '@conceal', result = '@string' },
	diagnostics_config = nil, -- passed to vim.diagnostic.config(cfg, namespace)
}

local default_diagnostics_config = {
	virtual_text = true,
	underline = false,
	signs = true,
	severity_sort = true,
}

local function apply_diagnostics_config()
	vim.diagnostic.config(M.config.diagnostics_config or default_diagnostics_config, namespace)
end

apply_diagnostics_config()

function M.setup(new_config)
	require('qalc.util').tbl_deep_extend(M.config, new_config or {})
	apply_diagnostics_config()
end

-- bufnr -> true while attached. used by is_attached()
local attached = {}
-- bufnr -> true once detach() has been requested. the on_lines callback checks
-- this itself and returns true instead of running again, since nvim_buf_attach has no other way to cancel a callback
local should_detach = {}

local function run(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local input, hints = parser.parse_input(lines)

	-- the completion module's per-buffer invocation as a trailing `list` command
	local send_input = vim.list_extend({}, input)
	table.insert(send_input, 'list')

	process.run(bufnr, send_input, M.config, function(raw_lines)
		if should_detach[bufnr] then
			return
		end

		local parsed = parser.parse_results(input, raw_lines, hints)
		display.update.all(namespace, bufnr, M.config, parsed)

		local complete = require('qalc.complete')
		complete.load()
		complete.update_user(bufnr, raw_lines)
	end)
end

-- idempotent: attaching an already-attached buffer is a no-op
function M.attach(bufnr)
	if attached[bufnr] then
		return
	end

	vim.fn.bufload(bufnr)
	should_detach[bufnr] = nil

	local function on_change()
		if should_detach[bufnr] then
			return true
		end
		run(bufnr)
	end

	on_change()
	vim.api.nvim_buf_attach(bufnr, false, { on_lines = on_change })

	if M.config.set_ft ~= nil and M.config.set_ft ~= '' then
		vim.bo[bufnr].filetype = M.config.set_ft
	end

	attached[bufnr] = true
end

function M.detach(bufnr)
	if not attached[bufnr] then
		return
	end

	should_detach[bufnr] = true
	attached[bufnr] = nil

	display.clear.all(namespace, bufnr)
	process.stop(bufnr)
	require('qalc.complete').clear_buffer(bufnr)
end

function M.reattach(bufnr)
	M.detach(bufnr)
	M.attach(bufnr)
end

function M.is_attached(bufnr)
	return attached[bufnr] == true
end

-- opens (or reuses, for `!`) a buffer and attaches qalc to it
function M.new_buf(name, scratch)
	local target = name
	if target == nil or target == '' then
		target = M.config.bufname
	end

	local cmd = (target ~= nil and target ~= '') and ('edit ' .. vim.fn.fnameescape(target)) or 'enew'
	if scratch then
		cmd = cmd .. ' | setlocal buftype=nofile bufhidden=hide noswapfile'
	end

	vim.cmd(cmd)
end

function M.yank(bufnr, register)
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local value = display.vtexts[bufnr] and display.vtexts[bufnr][lnum]
	if value ~= nil then
		vim.fn.setreg(register, value)
	end
end

return M
