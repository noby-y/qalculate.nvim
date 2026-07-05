-- mutates `dest`, unlike vim.tbl_deep_extend which returns a new table
-- required so every module holding a reference to the config table observes the same values after `setup()` runs
local function tbl_deep_extend(dest, src)
	for k, v in pairs(src) do
		if type(v) == 'table' and type(dest[k]) == 'table' then
			tbl_deep_extend(dest[k], v)
		else
			dest[k] = v
		end
	end
end

return { tbl_deep_extend = tbl_deep_extend }
