--[[
	airtime.lua -- the controller's Airtime Fairness switch (unifi/atf.lua),
	carried out on mac80211's airtime scheduler.

	The OpenWrt counterpart is not hostapd. mac80211 gives every station an
	equal airtime share (weight 256), charged from the TX and RX airtime the
	driver reports, and it is on by default on any driver that schedules
	through mac80211 TXQs (ath9k, ath10k, mt76) -- so "enabled" is the board's
	own default. The only switch is the per-phy debugfs file

	  /sys/kernel/debug/ieee80211/phyN/airtime_flags

	whose AIRTIME_TX (1) and AIRTIME_RX (2) bits select what is charged; 0
	charges nothing and the scheduler falls back to plain round-robin.
	hostapd's airtime_mode (UCI wifi-device airtime_mode) is not this switch:
	every one of its modes keeps the scheduler on and only sets per-BSS
	station weights.

	debugfs is live kernel state and resets to 3 on reboot, and the controller
	does not push again, so the pushed value is kept as st.atf_enabled and
	reapplied at startup (inform.lua's _reapply_airtime).
]]--

local M = {}

M.parse = require("unifi.atf").parse

M.DEBUGFS   = "/sys/kernel/debug/ieee80211"
M.FLAGS_ON  = "3"   -- AIRTIME_TX | AIRTIME_RX, mac80211's default
M.FLAGS_OFF = "0"

-- Injectable, matching the other modules' seams.
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

M._write_file = function(path, contents)
	local f = io.open(path, "w")
	if not f then return false end
	local ok = f:write(contents)
	-- debugfs reports a rejected value on close (the buffered write is
	-- flushed there), not on write.
	local closed = f:close()
	return ok ~= nil and closed ~= nil and closed ~= false
end

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Every phy's airtime_flags file, sorted.
function M.flag_files()
	local out = {}
	for line in M._run_cmd("ls -d " .. M.DEBUGFS .. "/phy*/airtime_flags"):gmatch("[^\n]+") do
		if line:match("^/sys/kernel/debug/ieee80211/phy%d+/airtime_flags$") then
			out[#out + 1] = line
		end
	end
	table.sort(out)
	return out
end

-- Cached: the phys and debugfs do not come and go while the daemon runs, and
-- the payload asks on every heartbeat. nil = not probed yet.
M._supported_cache = nil

-- Can this device switch airtime fairness? Claimed to the controller as
-- wifi_caps 0x20 (report.lua); without it the controller sends no atf block
-- at all. False without debugfs mounted or on a kernel built without
-- CONFIG_MAC80211_DEBUGFS.
function M.supported()
	if M._supported_cache ~= nil then return M._supported_cache end
	M._supported_cache = #M.flag_files() > 0
	return M._supported_cache
end

-- Set every phy on or off. Returns the number of phys whose flags read back
-- as requested, and the number of phys found.
function M.set_enabled(enabled)
	local want = enabled and M.FLAGS_ON or M.FLAGS_OFF
	local files = M.flag_files()
	local done = 0
	for _, path in ipairs(files) do
		if M._write_file(path, want) then
			-- Read back: the file lists the names of the set bits, and none
			-- of them when 0.
			local now = M._read_file(path) or ""
			local on = now:find("AIRTIME_TX", 1, true) ~= nil
				and now:find("AIRTIME_RX", 1, true) ~= nil
			local off = now:find("AIRTIME_", 1, true) == nil
			if (enabled and on) or (not enabled and off) then
				done = done + 1
			end
		end
	end
	if done < #files then
		io.stderr:write(("airtime: turning fairness %s: %d of %d phys read back as requested\n"):format(
			enabled and "on" or "off", done, #files))
	end
	return done, #files
end

return M
