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
-- The UI buckets it >=90 Excellent, >=70 Good, else Poor.
--
-- It is the worst of three terms, after the split commercial controllers
-- use (Aruba/Aerohive client health, Mist's coverage/throughput SLEs):
--  * dl: downlink airtime efficiency -- the airtime this client's frames
--    would take at its ceiling rate (sta_ceiling_mbps()) plus a fixed
--    per-frame cost, as a share of the airtime mac80211 says they took
--    (airtime_pct()). Every retry costs airtime whatever a driver calls it,
--    so this sees a failing link that rate control doesn't: on hardware a
--    -71 dBm client held MCS 7 while 89 % of attempts failed, lost 8-18 %
--    of pings and took 4x the airtime per frame of its neighbours. Until a
--    station has an airtime sample (or on a driver without tx duration)
--    the tx rate against its ceiling stands in (rate_pct()).
--  * ul: the uplink rate against the ceiling, at half weight (50-100): the
--    AP can't see the client's own retries, only the rate it settles on.
--    Judged only while the client really sends (M.SAT_UPLINK_MIN_PKTS).
--  * cov: SNR against the radio's noise floor, 5 dB -> 0, 20 dB -> 90,
--    25 dB -> 100 (Cisco's data-grade guideline is 20 dB; Meraki counts
--    <=15 dB as poor), smoothed per station so 1 dB of jitter doesn't flip
--    the bucket.
-- Power-save clients score lower on dl: frames sent while they doze are
-- re-sent, and that airtime is lost to everyone on the radio.
-- The iw retry/failed counters aren't used: they mean different things per
-- driver (mt76's tx failed counts failed attempts and can exceed packets;
-- ath10k's is always 0), and neither tracked ping loss on hardware (see
-- PROTOCOL-VALIDATION.md).

-- Weight of each new sample in the satisfaction terms' EWMAs.
M.RATE_EWMA_ALPHA = 0.2
-- Satisfaction tunables. Judgements, not calibrated against a real UniFi AP:
-- * the downlink airtime term is sampled once a window holds this many
--   frames, so a quiet client's few frames aren't a verdict;
M.SAT_AIRTIME_MIN_PKTS = 20
-- * the uplink rate is sampled only in an inform in which the client sent
--   this many frames: iw's rx bitrate is the LAST frame's rate, and a
--   near-idle client's odd frame (seen on hardware: a speaker sending 1-15
--   frames per 10 s, some at VHT MCS 2 among MCS 9) isn't its uplink;
M.SAT_UPLINK_MIN_PKTS = 20
-- * the ideal fixed cost of one frame on air (preamble, SIFS, ACK, backoff),
--   measured as ~110 us for small frames of clean 2.4 GHz clients;
M.SAT_FRAME_OVERHEAD_US = 110
-- * the noise floor is taken as at least this: drivers report floors no
--   receiver achieves (ath10k -106, ath9k -107), which would inflate SNR.
M.SAT_NOISE_FLOOR_MIN = -95

local function snr_score(snr)
	if snr <= 5 then return 0 end
	if snr <= 20 then return (snr - 5) * 6 end
	if snr <= 25 then return 90 + (snr - 20) * 2 end
	return 100
end

-- snr: dB (nil when signal is unknown), dl/ul: 0-100 or nil (unknown: the
-- term is skipped). Returns an integer 0-100, or nil without snr.
function M.estimate_satisfaction(snr, dl, ul)
	if not snr then return nil end
	local score = snr_score(snr)
	if dl and dl < score then score = dl end
	if ul and 50 + ul / 2 < score then score = 50 + ul / 2 end
	if score < 0 then score = 0 end
	return math.floor(score)
end

-- Relative data rate per spatial stream at 20 MHz, indexed by MCS + 1:
-- HT/VHT MCS 0-9 and HE MCS 0-11 (Mbit/s at long GI). Only ratios are used,
-- so GI cancels out.
local VHT_MCS_RATE = {6.5, 13, 19.5, 26, 39, 52, 58.5, 65, 78, 86.7}
local HE_MCS_RATE = {8.6, 17.2, 25.8, 34.4, 51.6, 68.8, 77.4, 86, 103.2, 114.7, 129, 143.4}
-- Data subcarriers per channel width, which is what a wider channel scales.
local WIDTH_SUBCARRIERS = {[20] = 52, [40] = 108, [80] = 234, [160] = 468}

-- The station's ceiling in Mbit/s (long GI): its association caps
-- ({mode = "ht"/"vht"/"he", nss, max_mcs, width}, the device's record of
-- what the station negotiated) capped by the AP's own stream count and live
-- channel width, at one MCS below the top. Rate control only probes the top
-- MCS and keeps stepping between it and the next, so a ceiling at the top
-- made a -48 dBm client alternating VHT MCS 8/9 swing across the
-- Good/Excellent line on every sample. nil without caps.
function M.sta_ceiling_mbps(caps, ap_nss, ap_width)
	if not caps then return nil end
	local ceil = (caps.mode == "he" and HE_MCS_RATE or VHT_MCS_RATE)[caps.max_mcs]
	local nss = caps.nss
	if ap_nss and ap_nss < nss then nss = ap_nss end
	local width = caps.width
	if ap_width and ap_width < width then width = ap_width end
	local sc = WIDTH_SUBCARRIERS[width]
	if not (ceil and sc) then return nil end
	return ceil * nss * sc / WIDTH_SUBCARRIERS[20]
end

-- One direction's rate (a station's generation, MCS, NSS and width for tx
-- or rx) as a percentage of ceil_mbps. nil when either side is unknown: a
-- legacy rate, no ceiling, or an EHT rate (no table here).
local function rate_pct(gen, mcs, nss, width, ceil_mbps)
	if not (ceil_mbps and mcs) then return nil end
	local rate
	if gen == "ax" then
		rate = HE_MCS_RATE[mcs + 1]
	elseif gen == "ac" then
		rate = VHT_MCS_RATE[mcs + 1]
	elseif gen == "n" then
		-- HT MCS indexes run on across streams: MCS 15 is MCS 7 on two.
		rate = VHT_MCS_RATE[mcs % 8 + 1]
	end
	local sc = WIDTH_SUBCARRIERS[width or 20]
	if not (rate and sc) then return nil end
	local pct = rate * (nss or 1) * sc / WIDTH_SUBCARRIERS[20] * 100 / ceil_mbps
	if pct > 100 then pct = 100 end
	return pct
end

-- Downlink airtime efficiency over one window of pkts frames and bytes
-- bytes that took dur_us of airtime: the ideal airtime (a fixed cost per
-- frame plus the payload at ceil_mbps) as a percentage of the actual,
-- capped at 100. Aggregated traffic beats the per-frame cost and caps out,
-- so the term only bites on links that spend airtime they shouldn't.
local function airtime_pct(pkts, bytes, dur_us, ceil_mbps)
	if not ceil_mbps or dur_us <= 0 then return nil end
	local ideal = pkts * M.SAT_FRAME_OVERHEAD_US + bytes * 8 / ceil_mbps
	local pct = ideal * 100 / dur_us
	if pct > 100 then pct = 100 end
	return pct
end

-- Each term is smoothed, since one sample swings with each rate-control
-- step; a sample without data keeps the last value.
local function ewma(old, new)
	if not new then return old end
	return old and old + M.RATE_EWMA_ALPHA * (new - old) or new
end

-- One heartbeat's satisfaction for one station. prev: the state this
-- returned for the station last time, or nil. sta: its station-dump entry
-- (signal, lifetime tx_packets/tx_bytes/tx_duration/rx_packets, and the
-- tx_/rx_ generation, mcs, nss and width of the last rate). ceil_mbps:
-- sta_ceiling_mbps(), or nil. noise: the radio's noise floor in dBm, or
-- nil. Returns the state to keep for the next call, and the score (nil
-- without a signal).
function M.satisfaction(prev, sta, ceil_mbps, noise)
	prev = prev or {}
	local rate_ewma = ewma(prev.rate_ewma, rate_pct(sta.tx_generation,
		sta.tx_mcs, sta.tx_nss, sta.tx_width, ceil_mbps))
	-- Uplink: only while the client sends enough frames for the last one's
	-- rate to stand for its uplink.
	local ul_ewma = prev.ul_ewma
	if prev.rx_packets
		and (sta.rx_packets or 0) - prev.rx_packets >= M.SAT_UPLINK_MIN_PKTS then
		ul_ewma = ewma(ul_ewma, rate_pct(sta.rx_generation, sta.rx_mcs,
			sta.rx_nss, sta.rx_width, ceil_mbps))
	end
	-- Downlink airtime: a window from the base counters, sampled once it
	-- holds SAT_AIRTIME_MIN_PKTS frames. A counter going backwards (a new
	-- association) restarts it.
	local air_ewma = prev.air_ewma
	local air_pkts, air_bytes, air_dur = prev.air_pkts, prev.air_bytes, prev.air_dur
	local tp, tb, td = sta.tx_packets, sta.tx_bytes, sta.tx_duration
	if not (tp and tb and td) then
		air_pkts, air_bytes, air_dur = nil, nil, nil
	elseif not air_pkts or tp < air_pkts or tb < air_bytes or td < air_dur then
		air_pkts, air_bytes, air_dur = tp, tb, td
	elseif tp - air_pkts >= M.SAT_AIRTIME_MIN_PKTS then
		air_ewma = ewma(air_ewma, airtime_pct(tp - air_pkts, tb - air_bytes,
			td - air_dur, ceil_mbps))
		air_pkts, air_bytes, air_dur = tp, tb, td
	end
	-- Coverage: SNR, noise floored at SAT_NOISE_FLOOR_MIN.
	if not noise or noise == 0 or noise < M.SAT_NOISE_FLOOR_MIN then
		noise = M.SAT_NOISE_FLOOR_MIN
	end
	local snr_ewma = ewma(prev.snr_ewma, sta.signal and sta.signal - noise)
	local state = {
		rx_packets = sta.rx_packets,
		rate_ewma  = rate_ewma,
		ul_ewma    = ul_ewma,
		air_ewma   = air_ewma,
		air_pkts   = air_pkts,
		air_bytes  = air_bytes,
		air_dur    = air_dur,
		snr_ewma   = snr_ewma,
	}
	return state, M.estimate_satisfaction(sta.signal and snr_ewma,
		air_ewma or rate_ewma, ul_ewma)
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
