local qalc = require('qalc')

vim.api.nvim_create_user_command('Qalc', function(opts)
	qalc.new_buf(opts.args, opts.bang)
	qalc.attach(vim.api.nvim_get_current_buf())
end, { nargs = '?', bang = true })

vim.api.nvim_create_user_command('QalcAttach', function()
	qalc.attach(vim.api.nvim_get_current_buf())
end, { nargs = 0 })

vim.api.nvim_create_user_command('QalcDetach', function()
	qalc.detach(vim.api.nvim_get_current_buf())
end, { nargs = 0 })

vim.api.nvim_create_user_command('QalcReattach', function()
	qalc.reattach(vim.api.nvim_get_current_buf())
end, { nargs = 0 })

vim.api.nvim_create_user_command('QalcYank', function(opts)
	local register = (opts.args ~= '' and opts.args) or qalc.config.yank_default_register
	qalc.yank(vim.api.nvim_get_current_buf(), register)
end, { nargs = '?' })

vim.api.nvim_create_user_command('QalcSave', function(opts)
	require('qalc.commands').save(vim.api.nvim_get_current_buf(), opts.args ~= '' and opts.args or nil)
end, { nargs = '?' })

vim.api.nvim_create_user_command('QalcDelete', function(opts)
	require('qalc.commands').delete(vim.api.nvim_get_current_buf(), opts.args ~= '' and opts.args or nil)
end, { nargs = '?' })

if qalc.config.attach_extension ~= nil and qalc.config.attach_extension ~= '' then
	vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter', 'BufRead' }, {
		pattern = qalc.config.attach_extension,
		callback = function(ev)
			qalc.attach(ev.buf)
		end,
	})
end
