-- spawns/kills the one-shot `qalc -f -` job used for every invocation (buffer
-- evaluation and one-off batches alike)

local M = {}

-- one in-flight job per bufnr per purpose; `run` (buffer evaluation) and `send`
-- (one-off batches: QalcSave/QalcDelete, doc lookups) never cancel each other
local run_jobs = {}
local send_jobs = {}

-- forced *after* the user's own cmd_args so they always win, same rationale as
-- `vertical space on`. Confirmed empirically: qalculate's own default config has
-- `save definitions on exit = yes` -- without forcing it off here, every
-- throwaway temporary variable/function typed into a scratch buffer would get
-- silently written to the user's permanent
-- ~/.local/share/qalculate/definitions/*.xml the moment this one-shot process
-- exits, on *any* system where the user hasn't already disabled that qalculate
-- default themselves. `save mode`/`save config` are forced off too as
-- belt-and-suspenders (not proven to leak in batch mode, but free to disable).
-- The explicit `keep <name>` + `save definitions` that :QalcSave sends (§8) is a
-- separate, direct command and still works normally with all three off.
local forced_args = {
	'vertical space on',
	'save definitions no',
	'save mode no',
	'save config no',
}

local function build_cmd(config)
	local cmd = { 'qalc', '-f', '-' }
	for _, arg in ipairs(config.cmd_args or {}) do
		table.insert(cmd, '-set')
		table.insert(cmd, arg)
	end
	for _, arg in ipairs(forced_args) do
		table.insert(cmd, '-set')
		table.insert(cmd, arg)
	end
	return cmd
end

-- starts `qalc -f -`, feeds it `lines` over stdin, and calls `on_exit(stdout_lines)`
-- once the process exits. `stdout_lines` is the flat array of raw output lines with
-- the trailing empty element (artifact of jobstart's line-splitting of a
-- newline-terminated stream) already stripped.
local function start(lines, config, on_exit)
	local stdout_lines = {}

	local jobid = vim.fn.jobstart(build_cmd(config), {
		pty = false,
		stdout_buffered = true,
		on_stdout = function(_, data, _)
			if data then
				stdout_lines = data
			end
		end,
		on_exit = function()
			if stdout_lines[#stdout_lines] == '' then
				table.remove(stdout_lines)
			end
			on_exit(stdout_lines)
		end,
	})

	if jobid <= 0 then
		on_exit({})
		return jobid
	end

	vim.fn.chansend(jobid, table.concat(lines, '\n') .. '\n')
	vim.fn.chanclose(jobid, 'stdin')

	return jobid
end

-- spawns `qalc -f -` over the whole buffer, killing any prior evaluation job for
-- `bufnr`. `on_done(namespace, bufnr, stdout_lines)` fires only for the job that is
-- current at the time it exits -- a killed job's callback never fires, so a slow,
-- already-superseded run can't clobber a fresher one that finished first.
function M.run(namespace, bufnr, input, config, on_done)
	if run_jobs[bufnr] then
		vim.fn.jobstop(run_jobs[bufnr])
	end

	local jobid
	jobid = start(input, config, function(stdout_lines)
		if run_jobs[bufnr] ~= jobid then
			return
		end
		run_jobs[bufnr] = nil
		on_done(namespace, bufnr, stdout_lines)
	end)

	run_jobs[bufnr] = jobid
end

-- one-off batch for anything that isn't "evaluate the whole buffer": completion doc
-- lookups and :QalcSave/:QalcDelete. Independent of `run`'s job slot, but a second
-- `send` for the same bufnr still supersedes the first (same killed-job-never-fires
-- guarantee as `run`).
function M.send(bufnr, cmds, config, callback)
	if send_jobs[bufnr] then
		vim.fn.jobstop(send_jobs[bufnr])
	end

	local jobid
	jobid = start(cmds, config, function(stdout_lines)
		if send_jobs[bufnr] ~= jobid then
			return
		end
		send_jobs[bufnr] = nil
		callback(stdout_lines)
	end)

	send_jobs[bufnr] = jobid
end

function M.stop(bufnr)
	if run_jobs[bufnr] then
		vim.fn.jobstop(run_jobs[bufnr])
		run_jobs[bufnr] = nil
	end
	if send_jobs[bufnr] then
		vim.fn.jobstop(send_jobs[bufnr])
		send_jobs[bufnr] = nil
	end
end

return M
