--[[
	WLAN Schedule on the device: an SSID brought down and up on the
	controller's schedule (unifi/schedule.lua for the wire and its meaning).

	ucihelper.apply_config stamps each scheduled WLAN's own wifi-iface with
	`openuf_schedule` (the schedule, encoded) and writes `disabled` for the
	moment of the push, marking a schedule-off section `openuf_sched_off=1`.
	That is all the state there is, and it lives in /etc/config/wireless, so
	a restart or a reboot resumes the schedule with no push.

	tick() runs from the inform loop once a minute, on the device's local
	time -- the timezone sysconf.lua takes from the controller (OpenWrt's
	musl reads /etc/TZ). A section whose state no longer matches the schedule
	gets `disabled` flipped and one `wifi reload` covers the lot. On 25.12
	that reload is incremental: hostapd.uc's iface_reload_config removes or
	adds just that BSS and leaves the radio and the other WLANs on it up
	(checked in the 25.12 hostapd.uc). An older stack restarts the radio.

	A WLAN the controller itself disabled (wireless.<n>.status) is never
	brought up: a section is only re-enabled when openUF's own mark says the
	schedule took it down. Teardown needs nothing here: a push without the
	schedule rebuilds the section without the stamp and without disabled.
]]--

local schedule = require("unifi.schedule")

local M = {}

M.PREFIX = "openuf_"
M._uci = nil
M._run_cmd = function(cmd) return os.execute(cmd) end
M._date = function() return os.date("*t") end

local function get_uci()
	if not M._uci then M._uci = require("uci") end
	return M._uci
end

-- Whether a decoded schedule has the WLAN off at local time t (os.date("*t")).
function M.off_now(sched, t)
	t = t or M._date()
	return not schedule.is_on(sched, t.wday, t.hour * 60 + t.min)
end

-- One pass. Returns the number of sections changed.
function M.tick(t)
	t = t or M._date()
	local cursor = get_uci().cursor()
	local changes = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if not (name and name:sub(1, #M.PREFIX) == M.PREFIX and s.openuf_schedule) then return end
		local sched = schedule.decode(s.openuf_schedule)
		if not sched then return end
		local off = M.off_now(sched, t)
		local ours = s.openuf_sched_off == "1"
		if off and s.disabled ~= "1" then
			changes[#changes + 1] = {name = name, disabled = "1", mark = "1", ssid = s.ssid}
		elseif not off and ours then
			changes[#changes + 1] = {name = name, disabled = "0", mark = nil, ssid = s.ssid}
		end
	end)
	for _, c in ipairs(changes) do
		cursor:set("wireless", c.name, "disabled", c.disabled)
		if c.mark then
			cursor:set("wireless", c.name, "openuf_sched_off", c.mark)
		else
			cursor:delete("wireless", c.name, "openuf_sched_off")
		end
		io.stderr:write(("openuf: WLAN schedule: %q %s\n"):format(tostring(c.ssid),
			c.disabled == "1" and "off" or "on"))
	end
	if #changes > 0 then
		cursor:commit("wireless")
		M._run_cmd("wifi reload >/dev/null 2>&1")
	end
	return #changes
end

return M
