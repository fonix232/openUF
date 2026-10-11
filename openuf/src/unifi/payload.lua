--[[
	payload.lua -- pieces of the inform payload that follow UniFi's rules
	rather than the device's: the sys_stats block, the spectrum_table
	layout, the arrays cjson would otherwise encode as objects, and the host
	lists a port reports. (WiFi Experience is unifi/satisfaction.lua.)
]]--

local cjson = require("cjson")

local M = {}

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
-- One pass over the payload, not one per field (each gsub copied the whole
-- encoded string), and a plain find for the '":{}' itself rather than a
-- pattern tried at every quote (upstream: ~1800 quotes, 19 ms on an Archer C5).
local _ARRAY_FIELDS = {
	if_table = '"if_table":[]', radio_table = '"radio_table":[]',
	radio_table_stats = '"radio_table_stats":[]', vap_table = '"vap_table":[]',
	scan_radio_table = '"scan_radio_table":[]', port_table = '"port_table":[]',
	lldp_table = '"lldp_table":[]', sta_table = '"sta_table":[]',
	mac_table = '"mac_table":[]', scan_table = '"scan_table":[]',
}
function M.fix_empty_arrays(json_str)
	local out, from, at = nil, 1, 1
	while true do
		local s = json_str:find('":{}', at, true)
		if not s then break end
		-- The field name ends at s-1; the longest listed one is 17 bytes.
		local name = json_str:sub(math.max(1, s - 24), s - 1):match('"([%w_]+)$')
		local repl = name and _ARRAY_FIELDS[name]
		if repl then
			out = out or {}
			out[#out + 1] = json_str:sub(from, s - #name - 2)
			out[#out + 1] = repl
			from = s + 4
		end
		at = s + 4
	end
	if not out then return json_str end
	out[#out + 1] = json_str:sub(from)
	return table.concat(out)
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

-- Channel utilisation (cu_total/cu_self_rx/cu_self_tx, percent) over the
-- time since the previous inform, not since the radio came up (upstream
-- facf986).
--
-- The survey counters accumulate from bring-up, so busy/active is a lifetime
-- average: an 11-hour-old 2.4 GHz radio kept reporting 25% whatever the air
-- was doing now. A UniFi AP reports the last ~1 s. Its driver (umac.ko,
-- ieee80211_beacon_chanutil_update2) diffs the MIB rx_clear/rx_frame/
-- tx_frame/cycle counters every 10 beacon intervals and stores each as
-- round(delta * 100 / cycle_delta). Firmware-confirmed for 4.0.15. The
-- window here is one inform interval: the nearest sample openUF has.
--
-- prev: what this returned as the radio's state last time (nil the first
-- time); s: the in-use survey entry. The first reading, a channel change, or
-- counters that went backwards (the radio restarted) fall back to the
-- counters as they stand, which is then everything since that restart. A
-- reading with no new active time repeats the previous result rather than
-- inventing 0%. Returns the new state and the three percentages.
function M.windowed_cu(prev, s)
	local now = {
		freq   = s.freq,
		active = s.channel_time or 0,
		busy   = s.channel_time_busy or 0,
		rx     = s.channel_time_rx or 0,
		tx     = s.channel_time_tx or 0,
	}
	local d = now
	if prev and prev.freq == now.freq and now.active >= prev.active
	   and now.busy >= prev.busy and now.rx >= prev.rx and now.tx >= prev.tx then
		if now.active == prev.active then
			now.out = prev.out
			return now, prev.out[1], prev.out[2], prev.out[3]
		end
		d = {
			active = now.active - prev.active,
			busy   = now.busy - prev.busy,
			rx     = now.rx - prev.rx,
			tx     = now.tx - prev.tx,
		}
	end
	local function pct(x)
		if d.active <= 0 then return 0 end
		return math.min(100, math.floor(x * 100 / d.active + 0.5))
	end
	now.out = {pct(d.busy), pct(d.rx), pct(d.tx)}
	return now, now.out[1], now.out[2], now.out[3]
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

-- A radio's spectrum_table as real UAPs send it: one entry per (channel,
-- width). The Environment chart averages the entries whose width equals the
-- chart's over each bonded block's 20 MHz channels, so every 20 MHz survey
-- row is listed at 20 and 40 MHz on 2.4 GHz, 20/40/80 elsewhere, and up to
-- the radio's configured width when that is wider (upstream a684980, seen
-- charting on a real UCG Ultra). rows: {channel, center_freq, utilization,
-- interference}; band: "ng"/"na"/"6e"; cfg_width: MHz.
function M.spectrum_table(rows, band, cfg_width)
	local widths = {20, 40}
	if band ~= "ng" then widths[#widths + 1] = 80 end
	while widths[#widths] < (cfg_width or 20) do widths[#widths + 1] = widths[#widths] * 2 end
	local out = {}
	for _, r in ipairs(rows or {}) do
		for _, w in ipairs(widths) do
			out[#out + 1] = {channel = r.channel, center_freq = r.center_freq, width = w,
				utilization = r.utilization, interference = r.interference}
		end
	end
	return out
end

return M
