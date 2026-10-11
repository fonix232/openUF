--[[
	system.lua -- the controller's system settings out of system_cfg: the
	site timezone, its NTP servers and its scheduled jobs (cron.*), with the
	validation every value passes before openwrt/sysconf.lua writes it into
	UCI or a crontab.
]]--

local M = {}

-- ─── Validation ──────────────────────────────────────────────────────────────
-- Everything here is spliced into UCI or a crontab that crond runs as root.

-- A POSIX TZ string: "IST-5:30", "CET-1CEST,M3.5.0,M10.5.0/3", "<+0530>-5:30".
function M.is_valid_tz(s)
	return type(s) == "string" and #s > 0 and #s <= 64
		and s:match("^[%w%+%-:,/%.<>]+$") ~= nil
end

-- A hostname or IPv4 literal.
function M.is_valid_server(s)
	return type(s) == "string" and #s > 0 and #s <= 253
		and s:match("^[%w%.%-]+$") ~= nil and not s:match("^[%.%-]")
end

-- Five crontab fields of digits, '*', ',', '-', '/'.
function M.is_valid_schedule(s)
	if type(s) ~= "string" then return false end
	local n = 0
	for field in s:gmatch("%S+") do
		n = n + 1
		if not field:match("^[%d%*,%-/]+$") then return false end
	end
	return n == 5
end

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- The three blocks out of a system_cfg blob. Each is nil when the blob does
-- not carry it (a partial push), so apply() touches only what was pushed.
-- Returns nil when none of the three is present at all.
---@param sys_raw string  system_cfg
---@return SystemSettings?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local tz, ntp, cron = nil, nil, nil
	local ntp_rows, cron_rows = {}, {}
	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k then
			if k == "system.timezone" or (k == "locale.timezone" and tz == nil) then
				if v ~= "" then tz = v end
			elseif k == "ntpclient.status" then
				ntp = ntp or {servers = {}}
				ntp.enabled = (v == "enabled")
			else
				local i, key = k:match("^ntpclient%.(%d+)%.(.+)$")
				if i then
					ntp = ntp or {servers = {}}
					i = tonumber(i)
					ntp_rows[i] = ntp_rows[i] or {}
					ntp_rows[i][key] = v
				elseif k == "cron.status" then
					cron = cron or {jobs = {}}
					cron.enabled = (v == "enabled")
				else
					local c, rest = k:match("^cron%.(%d+)%.(.+)$")
					if c then
						cron = cron or {jobs = {}}
						c = tonumber(c)
						cron_rows[c] = cron_rows[c] or {jobs = {}}
						local j, jkey = rest:match("^job%.(%d+)%.(.+)$")
						if j then
							j = tonumber(j)
							cron_rows[c].jobs[j] = cron_rows[c].jobs[j] or {}
							cron_rows[c].jobs[j][jkey] = v
						else
							cron_rows[c][rest] = v
						end
					end
				end
			end
		end
	end
	if ntp then
		-- Indices are slot numbers; keep the controller's order.
		local idx = {}
		for i in pairs(ntp_rows) do idx[#idx + 1] = i end
		table.sort(idx)
		for _, i in ipairs(idx) do
			local r = ntp_rows[i]
			if r.status ~= "disabled" and M.is_valid_server(r.server) then
				ntp.servers[#ntp.servers + 1] = r.server
			elseif r.server and r.server ~= "" and r.status ~= "disabled" then
				io.stderr:write("sysconf: ignoring malformed NTP server " .. ("%q"):format(r.server) .. "\n")
			end
		end
		if ntp.enabled == nil then ntp.enabled = (#ntp.servers > 0) end
	end
	if cron then
		local cidx = {}
		for c in pairs(cron_rows) do cidx[#cidx + 1] = c end
		table.sort(cidx)
		for _, c in ipairs(cidx) do
			local tab = cron_rows[c]
			local jidx = {}
			for j in pairs(tab.jobs) do jidx[#jidx + 1] = j end
			table.sort(jidx)
			for _, j in ipairs(jidx) do
				local job = tab.jobs[j]
				cron.jobs[#cron.jobs + 1] = {
					schedule = job.schedule,
					cmd      = job.cmd,
					user     = tab.user,
					enabled  = (tab.status ~= "disabled") and (job.status ~= "disabled"),
				}
			end
		end
		if cron.enabled == nil then cron.enabled = (#cron.jobs > 0) end
	end
	if tz == nil and ntp == nil and cron == nil then return nil end
	return {timezone = tz, ntp = ntp, cron = cron}
end

return M
