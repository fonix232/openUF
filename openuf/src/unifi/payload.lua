--[[
	payload.lua -- pieces of the inform payload that follow UniFi's rules
	rather than the device's: the WiFi Experience estimate, the sys_stats
	block, the arrays cjson would otherwise encode as objects, and the host
	lists a port reports.
]]--

local cjson = require("cjson")

local M = {}

-- Best-effort proxy for the "WiFi Experience" score a real AP computes
-- on-device (proprietary/undocumented formula -- confirmed via decompiled
-- controller 10.4.57 that the controller itself does no computation: it
-- just reads "satisfaction" straight off the client doc, which is
-- populated verbatim from whatever the AP sent in that sta_table entry).
-- Community reports (community.ui.com) describe it as driven by signal
-- quality and tx-retry ratio -- e.g. a client with great signal but very
-- low PHY rate/high retries still scores low -- so this combines a
-- signal-quality score and a retry-quality score and takes the worse of
-- the two, matching that "worst factor wins" description. Not a measured
-- value; flagged the same way as capacity/throughput above.
-- signal: dBm (nil if iw reported none). retry_pct: 0-100.
-- Returns an integer 0-100, or nil if signal is unavailable.
function M.estimate_satisfaction(signal, retry_pct)
	if not signal then return nil end
	local SIGNAL_FLOOR, SIGNAL_CEIL = -85, -50
	local signal_score = (signal - SIGNAL_FLOOR) / (SIGNAL_CEIL - SIGNAL_FLOOR) * 100
	if signal_score < 0 then signal_score = 0 end
	if signal_score > 100 then signal_score = 100 end
	local retry_score = 100 - (retry_pct or 0)
	if retry_score < 0 then retry_score = 0 end
	local score = math.min(signal_score, retry_score)
	return math.floor(score)
end

-- ─── JSON payload builder ────────────────────────────────────────────────────

-- cjson encodes an empty Lua table as a JSON OBJECT ({}), but the payload's
-- list fields (vap_table, scan_radio_table, mac_table, ...) must serialize
-- as ARRAYS ([]) -- the controller's DTOs type them as lists, and {} for an
-- empty list is a wire-format ambiguity no decoded-side test could ever see.
-- empty_array_mt is feature-detected: a modern lua-cjson tags the table so
-- it encodes as []; an older target build silently keeps the old behavior
-- rather than erroring. Non-empty tables are unambiguous either way.
local _EMPTY_ARRAY_MT = type(cjson) == "table" and cjson.empty_array_mt or nil
function M.arr(t)
	if _EMPTY_ARRAY_MT and next(t) == nil then
		return setmetatable(t, _EMPTY_ARRAY_MT)
	end
	return t
end

-- Belt for arr()'s braces: the TARGET's lua-cjson (OpenWrt's 2.1.0-era build,
-- confirmed on the validation container) has neither empty_array_mt nor the
-- empty_array sentinel, so the metatable route degrades to {} exactly where
-- it matters most. This post-pass rewrites '"<field>":{}' to '"<field>":[]'
-- for the known list fields on the ENCODED string -- version-independent.
-- Safe against false positives: cjson escapes quotes inside string values,
-- so the unescaped '"field":{}' shape cannot occur inside one.
local _ARRAY_FIELDS = {
	"if_table", "radio_table", "radio_table_stats", "vap_table",
	"scan_radio_table", "port_table", "lldp_table",
	"sta_table", "mac_table", "scan_table",
}
function M.fix_empty_arrays(json_str)
	for _, f in ipairs(_ARRAY_FIELDS) do
		json_str = json_str:gsub('("' .. f .. '"):{}', '%1:[]')
	end
	return json_str
end

-- One port's `mac_table`: the wired hosts a source reports, minus the two sets
-- that are never wired clients of this AP -- its own netdev MACs, and the
-- stations currently associated to its radios (a wireless client bridged into
-- br-lan genuinely shows up in the bridge FDB and the switch ARL too).
-- `source` is sysinfo.mac_table(ifname, bridge, allow_tap) or
-- sysinfo.switch_mac_table(phys, arl), so it takes up to three arguments; a
-- failing source yields no hosts rather than aborting the payload.
--
-- `vlan` stamps every row with the VLAN the socket carries, and is what decides
-- which NETWORK the controller files these clients under. It walks the site's
-- layer-2 networks and keeps a reported host only where the network's VLAN id
-- equals the row's `vlan`, defaulting to 1:
--
--     if (network.getVlan() != host.getInt("vlan", 1)) continue;
--
-- (confirmed in the 10.6 controller's wired-client processor). Omitted, every
-- host defaults to 1 and lands in the untagged network no matter which socket
-- reported it -- so a client on a socket openUF assigned to a VLAN was filed
-- under the management LAN while its port, IP and the Ports view's own Native
-- VLAN column all said otherwise. It is also half of the controller's dedup key
-- for these rows (`mac` .. `vlan`), so one host reachable on two VLANs stays two
-- rows rather than collapsing into one.
--
-- Left nil for the management VLAN: the controller drops a `vlan` of 1 on
-- arrival, so sending it says nothing and costs bytes on every heartbeat.
function M.filter_hosts(source, a, b, c, vlan, self_macs, station_macs)
	local hosts = {}
	local ok, found = pcall(source, a, b, c)
	if not ok or type(found) ~= "table" then return hosts end
	for _, host in ipairs(found) do
		if not self_macs[host.mac] and not station_macs[host.mac] then
			-- `vlan` is one VLAN for the whole socket, or -- on a vlan-filtering
			-- bridge -- a mac -> vid map read off the FDB, where one trunk
			-- socket can carry hosts of several networks.
			local v = vlan
			if type(vlan) == "table" then
				v = vlan[tostring(host.mac):lower()]
				if v == 1 then v = nil end
			end
			hosts[#hosts + 1] = {
				mac      = host.mac,
				ip       = host.ip,
				hostname = host.hostname,
				age      = host.age,
				uptime   = host.uptime,
				vlan     = v,
			}
		end
	end
	return hosts
end

-- Pick the survey entry describing the channel the radio is actually on.
--
-- `iw dev <if> survey dump` emits one entry per channel the phy supports, in
-- the phy's own frequency order -- so the operating channel is wherever it
-- happens to fall (entry 11 of 13 for 2.4GHz ch11, entry 3 of 24 for 5GHz
-- ch44), essentially never first. Every other entry is a scan dwell holding
-- a few milliseconds of accumulated time, so deriving utilisation from
-- stats[1] divided a busy figure by a ~3 ms active time: confirmed live on
-- both APs, a genuinely 24%-busy 2.4GHz channel was reported to the
-- controller as 100% and a 1.9%-busy 5GHz channel as 75%, which is what made
-- the APs look like they were drowning in interference. The same wrong entry
-- also supplied the noise floor Minimum RSSI was (wrongly) converted with.
--
-- Falls back to the first entry when nothing is marked, which keeps drivers
-- (and test doubles) that omit the marker behaving exactly as before.
function M.in_use_survey(stats)
	if type(stats) ~= "table" then return nil end
	for _, s in ipairs(stats) do
		if s.in_use then return s end
	end
	return stats[1]
end

-- The sys_stats block: load averages as strings, memory in bytes.
-- loadavg: {"0.10", "0.20", "0.30"} or nil.
function M.sys_stats(meminfo, mem_used_kb, loadavg)
	local out = {
		mem_total = meminfo.total_kb * 1024,
		mem_used  = mem_used_kb * 1024,
	}
	if meminfo.buffers_kb then out.mem_buffer = meminfo.buffers_kb * 1024 end
	if loadavg then
		out.loadavg_1, out.loadavg_5, out.loadavg_15 = loadavg[1], loadavg[2], loadavg[3]
	end
	return out
end

return M
