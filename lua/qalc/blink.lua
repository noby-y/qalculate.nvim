-- blink.cmp completion source (§7.5): a thin adapter over qalc.complete's
-- two-tier cache.
--
-- This is deliberately a separate module from qalc.complete, not a `.source`
-- field on it: blink.cmp does `require(config.module).new(opts, config)` on
-- whatever module path you give it (see
-- blink.cmp/lua/blink/cmp/sources/lib/provider/init.lua), i.e. the *module
-- itself* must be the source class. qalc.complete's own API is a plain
-- bufnr-first module table (`get_completions(bufnr)`, `get_doc(bufnr, name,
-- cb)`, ...) used directly by init.lua/commands.lua; blink.cmp's Source
-- contract needs `self`-first methods of the very same names
-- (`self:get_completions(context, callback)`), which would collide with and
-- shadow qalc.complete's own if both lived on one table.
--
-- Point blink.cmp at this module, not qalc.complete:
--   sources.providers.qalc = { name = 'qalc', module = 'qalc.blink' }

local complete = require('qalc.complete')

local source = {}

function source.new()
	return source
end

function source:enabled()
	return require('qalc').is_attached(vim.api.nvim_get_current_buf())
end

function source:get_completions(_, callback)
	local bufnr = vim.api.nvim_get_current_buf()
	callback({
		is_incomplete_forward = false,
		is_incomplete_backward = false,
		items = vim.deepcopy(complete.get_completions(bufnr)),
	})
end

function source:resolve(item, callback)
	local bufnr = vim.api.nvim_get_current_buf()
	complete.get_doc(bufnr, item.label, function(doc)
		if doc then
			item = vim.deepcopy(item)
			item.documentation = { kind = 'markdown', value = doc }
		end
		callback(item)
	end)
end

return source
