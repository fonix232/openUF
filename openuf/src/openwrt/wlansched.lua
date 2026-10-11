--[[
	WLAN Schedule on the device: an SSID brought down and up on the
	controller's schedule (unifi/schedule.lua for the wire and its meaning).

	ucihelper.apply_config stamps each scheduled WLAN's own wifi-iface with
	`openuf_schedule` (the schedule, encoded) and writes `disabled` for the
	moment of the push, marking a schedule-off section `openuf_sched_off=1`.
	That is all the state there is, and it lives in /etc/config/wireless, so
	a restart or a reboot resumes the schedule with no push.

	tick() runs from the inform loop once a minute, on the device's local
	time -- the timezone sysconf.lua takes from the controller. OpenWrt's
	musl reads /etc/TZ (-> /tmp/TZ, which `/etc/init.d/system reload`
	rewrites) on every localtime() while TZ is not set in the environment,
	as it is not for a procd service, so a pushed timezone applies without a
	restart (checked in the 25.12 rootfs: one Lua process, /etc/TZ changed
	between two os.date calls, the second in the new zone). While the clock
	is implausible (schedule.sane_clock: NTP has not set it yet) the tick
	does nothing. A section whose state no longer matches the schedule
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

-- openUF's own wifi-iface sections, as ucihelper names them.
M.PREFIX = require("openwrt.ucihelper").PREFIX
M._uci = nil
M._run_cmd = function(cmd) return os.execute(cmd) end
M._date = function() return os.date("*t") end
M._now = os.time
M._clock_logged = false

local function get_uci()
	if not M._uci then M._uci = require("uci") end
	return M._uci
end

-- Whether a decoded schedule has the WLAN off at local time t (os.date("*t")).
function M.off_now(sched, t)
	t = t or M._date()
	return not schedule.is_on(sched, t.wday, t.hour * 60 + t.min)
end

-- One pass. Returns the number of sections changed and the names of those
-- brought back up (whose netdevs the reload is about to create).
function M.tick(t)
	if not schedule.sane_clock(M._now()) then
		if not M._clock_logged then
			M._clock_logged = true
			io.stderr:write("openuf: WLAN schedule: the clock is not set yet -- waiting\n")
		end
		return 0, {}
	end
	M._clock_logged = false
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
	local up = {}
	if #changes > 0 then
		cursor:commit("wireless")
		M._run_cmd("wifi reload >/dev/null 2>&1")
		for _, c in ipairs(changes) do
			if c.disabled == "0" then up[#up + 1] = c.name end
		end
	end
	return #changes, up
end

-- ─── One BSS off the air and back (guest selfrun, inform._guest_selfrun) ────

M._popen = function(cmd)
	local p = io.popen(cmd)
	if not p then return nil end
	local out = p:read("*a")
	p:close()
	return out
end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function valid_ifname(n)
	return type(n) == "string" and n:match("^[%w%-%._]+$") ~= nil and #n <= 15
end

-- IFF_UP from sysfs. nil when the netdev does not exist.
function M.is_up(ifname)
	if not valid_ifname(ifname) then return nil end
	local flags = tonumber(M._read_file("/sys/class/net/" .. ifname .. "/flags") or "")
	if not flags then return nil end
	return flags % 2 == 1
end

local function set_link(ifname, up)
	local rc = M._run_cmd("ip link set dev " .. ifname .. (up and " up" or " down") .. " 2>/dev/null")
	return rc == 0 or rc == true
end

-- The BSS's beacon, after its netdev came back up. hostapd (OpenWrt 25.12,
-- ath9k/ath10k/mt76, checked upstream on hardware 2026-10-11) does not act
-- on the link going down, so on the way up it still believes its beacon is
-- set and only updates it, which mac80211 refuses ("Failed to set beacon
-- parameters") since the netdev going down stopped the AP: the BSS stays up
-- but off the air. STOP_AP clears hostapd's beacon-set flag, so
-- UPDATE_BEACON starts the AP again. Both act on this BSS alone; both need
-- hostapd_cli (hostapd-utils).
local function restart_beacon(ifname)
	local cli = "hostapd_cli -i " .. ifname .. " "
	M._popen(cli .. "raw STOP_AP 2>/dev/null")
	return tostring(M._popen(cli .. "update_beacon 2>/dev/null") or ""):match("^OK") ~= nil
end

-- Take one BSS off the air (its netdev down) or put it back on (netdev up,
-- then restart_beacon). A BSS whose beacon does not restart goes down
-- again, so a caller that keeps it in its ledger retries the whole bring-up
-- rather than leaving an up netdev with no beacon. Returns true if the BSS
-- is now as asked.
function M.set_bss(ifname, up)
	if not valid_ifname(ifname) then return false end
	if not up then return set_link(ifname, false) end
	if not set_link(ifname, true) then return false end
	if restart_beacon(ifname) then return true end
	set_link(ifname, false)
	return false
end

return M
