--[[
	Client-assisted RF environment enrichment (802.11k beacon reports).

	WHY THIS EXISTS

	scan_radio_table (see inform.lua) is built from `iw dev <if> scan dump`,
	the kernel's PASSIVE BSS cache. That cache is filled from beacons the radio
	overhears on the channel it is already serving, so the Environment tab only
	ever shows near-channel neighbours: measured on an AX3000T, 6 BSSes on a
	2.4 GHz radio parked on ch 11, and exactly 1 on a 5 GHz radio on ch 44 --
	its own. openUF will not dwell off-channel behind a client's back to fix
	that; a real off-channel sweep on the same board cost 12% packet loss to an
	associated client for the ~3 s it ran.

	Ubiquiti does not solve this for free either. Their own docs describe three
	paths: a manual "Airtime Scan"/RF Scan that "may interrupt client
	connectivity while in progress", a dedicated Scanning Radio on the models
	that ship a third radio, and Channel AI, which "scans the surrounding
	wireless environment using neighbor reports and automated RRM scans".

	This module implements that last path, and only that one. In an 802.11k
	beacon measurement the CLIENT leaves the channel, scans, and reports what
	it saw; the AP never stops serving. It is the one enrichment that costs the
	AP nothing.

	WHAT IT ACTUALLY BUYS, measured live 2026-09-02

	A single beacon request to one capable client returned 15 BSSes at once,
	across 2.4 GHz channels 1/3/4/6/7/9/10/11 AND 5 GHz channels 36/44/48 --
	from a client associated on a 5 GHz radio. One client's report therefore
	enriches BOTH radios, which is why merge_into() keys on the reported
	channel's band rather than on the interface the request went out of.

	AND WHAT IT DOES NOT

	Support is a client-by-client lottery, so this can only ever supplement the
	passive cache, never replace it. Of 13 real clients surveyed across two
	APs: 9 advertised no 802.11k at all (rrm=0), 3 advertised beacon-active +
	beacon-passive and answered in full, and 1 advertised beacon-table only,
	acknowledged the request at the MAC layer (BEACON-REQ-TX-STATUS ack=1) and
	then never sent a report. Beacon-table alone is therefore NOT treated as
	capable here -- see capable_stations().

	hostapd hands a report over twice. Its ubus notification carries only a
	BSSID, a channel and an RCPI. Its control socket (BEACON-RESP-RX) carries
	the whole report, including the neighbour's beacon as the client heard it,
	and with it SSID, security and channel width (see parse_report). Both are
	collected, and the control-socket record wins. Entries that the passive
	cache already knows keep the cache's version, which alone can carry the
	sibling tag. This AP's own BSSIDs are skipped (merge_into); siblings are
	kept and tagged by the caller.
]]--

local M = {}

-- Injectable seams, mirroring ucihelper/bcfilter.
M._popen = function(cmd)
	local f = io.popen(cmd)
	if not f then return nil end
	local out = f:read("*a")
	f:close()
	return out
end
M._exec  = function(cmd) return os.execute(cmd) end
M._now   = function() return os.time() end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Where the background collector parks hostapd's ubus notifications.
M.EVENT_FILE = "/tmp/openuf-rrm.jsonl"

-- hostapd delivers a beacon report as a ubus NOTIFICATION on the per-BSS
-- object, not as a broadcast event. `ubus listen` -- which catches broadcasts
-- -- therefore sees nothing at all here, however long it waits; only
-- `ubus subscribe hostapd.<iface>` receives them. Confirmed live: a listen
-- across two requests captured zero notifications while a subscribe over the
-- same window captured 22 beacon-reports.
local SUBSCRIBE_MATCH = "^ubus subscribe hostapd"

-- 802.11 RCPI is a 0.5-dBm-step scale anchored at -110 dBm (IEEE 802.11-2020
-- 9.4.2.38), so dBm = rcpi/2 - 110. Sanity-checked against reality on the
-- capture this module was written from: the reporting client sat on the
-- living-room AP's own 2.4 GHz BSS and gave it rcpi=124 -> -48 dBm, while the
-- furthest neighbour came back rcpi=32 -> -94 dBm.
function M.rcpi_to_dbm(rcpi)
	rcpi = tonumber(rcpi)
	if not rcpi then return nil end
	return math.floor(rcpi / 2 - 110)
end

-- Not every client fills the RCPI field with RCPI. One live (2026-10-13, an
-- office 2.4 GHz client) wrote its received power as a signed dBm byte: its
-- own AP came back as 0xbf, which is -65 dBm read signed and -14.5 dBm read as
-- RCPI, while hostapd measured that client at -71 dBm. Every neighbour it
-- reported landed between -11 and -26 dBm. Which way a client writes the byte
-- is learned per station from the one BSS whose true level is known here --
-- the station's own AP, which every report seen so far includes. Verdicts are
-- kept for the daemon's life: a station that is not calibrated yet, or never
-- reports its own AP, is read the standard way.
M._rcpi_signed = {}

-- true = the byte is signed dBm, false = it is RCPI, nil = this sample cannot
-- tell. ap_dbm is hostapd's own reading of the station.
function M.rcpi_verdict(raw, ap_dbm)
	raw, ap_dbm = tonumber(raw), tonumber(ap_dbm)
	if not raw or not ap_dbm then return nil end
	local std = raw / 2 - 110
	local sgn = raw >= 128 and raw - 256 or nil
	if sgn and math.abs(sgn - ap_dbm) <= 12 and math.abs(std - ap_dbm) > 20 then
		return true
	end
	if math.abs(std - ap_dbm) <= 12 then return false end
	return nil
end

-- A reported level in dBm for this station's way of writing it.
function M.signal_of(sta, raw)
	raw = tonumber(raw)
	if not raw then return nil end
	if sta and M._rcpi_signed[sta:lower()] then
		return raw >= 128 and raw - 256 or nil
	end
	return M.rcpi_to_dbm(raw)
end

-- This interface's BSSID and hostapd's averaged signal for one station on it.
-- Both names come off the event file, so they are checked before reaching a
-- shell.
local IFNAME_SAFE = "^[%w_%.%-]+$"
local MAC_SAFE = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"
function M.iface_bssid(ifname)
	if type(ifname) ~= "string" or not ifname:match(IFNAME_SAFE) then return nil end
	local out = M._popen("iw dev " .. ifname .. " info 2>/dev/null") or ""
	local mac = out:match("addr (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	return mac and mac:lower()
end
function M.sta_signal(ifname, sta)
	if type(ifname) ~= "string" or not ifname:match(IFNAME_SAFE)
	   or type(sta) ~= "string" or not sta:match(MAC_SAFE) then
		return nil
	end
	local out = M._popen("iw dev " .. ifname .. " station get " .. sta .. " 2>/dev/null") or ""
	return tonumber(out:match("signal avg:%s*(%-?%d+)") or out:match("signal:%s*(%-?%d+)"))
end

-- Band for a reported channel, in the controller's own radio vocabulary.
-- Beacon reports name a channel but never a frequency, and a client answering
-- on one band routinely reports the other, so this is what decides which
-- radio's scan_table an entry belongs to.
function M.band_of_channel(ch)
	ch = tonumber(ch)
	if not ch then return nil end
	if ch >= 1 and ch <= 14 then return "ng" end
	if ch >= 32 then return "na" end
	return nil
end

-- Centre frequency for a reported channel. Beacon reports carry a channel
-- number only, while scan_table entries carry both -- and the Environment
-- tab's spectrum chart plots the frequency.
function M.freq_of_channel(ch)
	ch = tonumber(ch)
	if not ch then return nil end
	if ch == 14 then return 2484 end
	if ch >= 1 and ch <= 13 then return 2407 + 5 * ch end
	if ch >= 32 then return 5000 + 5 * ch end
	return nil
end

-- Width from the operation elements, injected by inform.lua as
-- sysinfo.channel_width so the scan cache and beacon reports decide it the
-- same way. Unset (a test, or a load-order surprise), a report's width is
-- simply not known.
M._channel_width = nil

local WPA_OUI_TYPE = string.char(0x00, 0x50, 0xf2, 0x01)

-- One Beacon Report element as hostapd prints it on its control socket
-- (BEACON-RESP-RX <sta> <token> <rep_mode> <hex>), hex being the report from
-- its Operating Class on (IEEE 802.11-2020 9.4.2.22.7). The ubus notification
-- carries only the fixed fields; this carries the subelements too, and with
-- them the Reported Frame Body (subelement 1): the neighbour's own beacon,
-- fixed fields and elements, which is where SSID, security and width are.
-- Clients include it because the request names no Reporting Detail, and the
-- standard's default for that is 2, "all fixed fields and elements". Captured
-- live 2026-10-12: a 205-byte body with SSID, RSN, HT and VHT operation.
--
-- A body is cut to fit, sometimes flagged (subelement 2, Reported Frame Body
-- Fragment ID, "more fragments" bit) and sometimes not, and a client may also
-- send only some elements: live, one body held just the SSID and a vendor
-- element, with privacy set and no fragment subelement. Nor is the order
-- dependable -- another held its Country element after Tx Power Envelope.
-- What is missing from a body is therefore unknown, never absent, and each
-- field is taken only where an element present in the body proves it:
--   essid    -- the SSID element; empty or NUL-filled (hidden) stays nil.
--   security -- RSN -> wpa2, WPA vendor element -> wpa, privacy bit clear ->
--               open (the capability field is always there). Privacy with
--               neither element stays nil -- never wep.
--   bw       -- VHT operation on 5 GHz, HT operation on 2.4 GHz. A 5 GHz body
--               with HT but no VHT operation gives no width: the VHT element
--               may simply not have been sent. nil means the caller's 20 floor.
--   channel  -- HT operation's primary channel. Clients put an 80 MHz BSS's
--               CENTRE channel in the fixed field (channel 42 for a BSS on
--               36, captured live), which plotted it on the wrong channel.
-- A continuation fragment (fragment number > 0) arrives as a report of its
-- own for the same BSSID, its body starting mid-beacon. It returns nil: it
-- repeats fragment 0's fixed fields and nothing in it can be anchored, and
-- returned, it could take the BSSID's place ahead of fragment 0.
-- Returns nil for anything malformed.
function M.parse_report(hex)
	if type(hex) ~= "string" or #hex < 52 or #hex % 2 ~= 0
	   or not hex:match("^%x+$") then
		return nil
	end
	local b = hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
	local rec = {
		bssid   = string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(16, 21)),
		channel = b:byte(2),
		rcpi    = b:byte(14),
		signal  = M.rcpi_to_dbm(b:byte(14)),
	}
	local body, frag_num
	local i = 27
	while i + 1 <= #b do
		local id, len = b:byte(i), b:byte(i + 1)
		if i + 1 + len > #b then break end
		local data = b:sub(i + 2, i + 1 + len)
		if id == 1 then
			body = data
		elseif id == 2 and len >= 2 then
			frag_num = data:byte(2) % 128
		end
		i = i + 2 + len
	end
	if (frag_num or 0) > 0 then return nil end
	if body and #body >= 12 then
		-- Marks a record whose essid/security/bw/channel came from a body, so
		-- a bodiless copy of the same sighting cannot pass for a newer truth.
		rec.body = true
		local privacy = body:byte(11) % 32 >= 16  -- capability bit 4
		local rsn, wpa, ht, ht_prim, ht_sec, vht_w, seg1, seg2
		local j = 13
		while j + 1 <= #body do
			local e, l = body:byte(j), body:byte(j + 1)
			if j + 1 + l > #body then break end
			local v = body:sub(j + 2, j + 1 + l)
			if e == 0 then
				if l > 0 and v ~= string.rep(string.char(0), l) then rec.essid = v end
			elseif e == 48 then
				rsn = true
			elseif e == 221 and v:sub(1, 4) == WPA_OUI_TYPE then
				wpa = true
			elseif e == 61 and l >= 2 then
				ht, ht_prim = true, v:byte(1)
				local off = v:byte(2) % 4
				ht_sec = (off == 1 and "above") or (off == 3 and "below") or "none"
			elseif e == 192 and l >= 3 then
				vht_w, seg1, seg2 = v:byte(1), v:byte(2), v:byte(3)
			end
			j = j + 2 + l
		end
		if rsn then rec.security = "wpa2"
		elseif wpa then rec.security = "wpa"
		elseif not privacy then rec.security = "open" end
		if ht_prim and M.band_of_channel(ht_prim) then rec.channel = ht_prim end
		local band = M.band_of_channel(rec.channel)
		if M._channel_width and (vht_w or (ht and band == "ng")) then
			rec.bw = M._channel_width(vht_w, seg1, seg2, ht_sec)
		end
	end
	rec.band = M.band_of_channel(rec.channel)
	return rec
end

-- RM Enabled Capabilities bits (IEEE 802.11-2020 9.4.2.44), as hostapd's
-- get_clients exposes them in the first byte of "rrm".
local RRM_BEACON_PASSIVE = 0x10  -- bit 4
local RRM_BEACON_ACTIVE  = 0x20  -- bit 5
local RRM_BEACON_TABLE   = 0x40  -- bit 6

-- Request modes (IEEE 802.11-2020 9.4.2.20.7, Measurement Mode).
M.MODE_ACTIVE = 1
M.MODE_TABLE  = 2

-- Stations on this BSS that can report what they see, and how to ask each:
-- returns {mac, ...} and {mac = M.MODE_ACTIVE | M.MODE_TABLE}. A station
-- with passive or active measurement is asked to go and look. A beacon-TABLE
-- one is asked for what its own scans already hold: asking it for a passive
-- measurement is refused by hostapd itself ("does not support passive beacon
-- report"). Table-only stations used to be left out because one acked every
-- request and answered none; on 2026-10-03 every 802.11k client on a home AP
-- was table-only (rrm 0x42/0x43), so none was ever asked, and one asked by hand
-- (mode 2, op_class 0, channel 0) answered within a second with five BSSes,
-- two of them sibling APs on other channels. A table-only station that never
-- answers is benched by tick()'s unanswered-request count like any other.
function M.capable_stations(ifname)
	if not ifname then return {}, {} end
	local out = M._popen("ubus call hostapd." .. ifname .. " get_clients 2>/dev/null") or ""
	local stations, modes = {}, {}
	for mac, block in out:gmatch('"(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)":%s*(%b{})') do
		local rrm = tonumber(block:match('"rrm":%s*%[%s*(%d+)')) or 0
		local mode
		if rrm % (RRM_BEACON_PASSIVE * 2) >= RRM_BEACON_PASSIVE
		   or rrm % (RRM_BEACON_ACTIVE * 2) >= RRM_BEACON_ACTIVE then
			mode = M.MODE_ACTIVE
		elseif rrm % (RRM_BEACON_TABLE * 2) >= RRM_BEACON_TABLE then
			mode = M.MODE_TABLE
		end
		if mode then
			stations[#stations + 1] = mac
			modes[mac] = mode
		end
	end
	table.sort(stations)  -- deterministic, so round-robin actually rotates
	return stations, modes
end

-- Ask one station for a full sweep. mode 1 is ACTIVE measurement: the client
-- probes rather than only listening, which is what makes it report BSSes on
-- channels it is not sitting on. channel 255 means "every channel in this
-- operating class". op_class defaults to 115 (5 GHz U-NII-1); dual-band clients
-- observed here ignore its band restriction and answer for 2.4 GHz too, but a
-- 2.4 GHz-only client answers a 5 GHz class with report mode 0x02
-- ("incapable") and an all-zero BSSID -- nothing usable at all. So the caller
-- (inform._rrm_tick) passes 81, the 2.4 GHz class, for a station on a 2.4 GHz
-- BSS, and the dual-band bonus stays a bonus rather than the mechanism.
--
-- Fire-and-forget by design: the report comes back asynchronously as a ubus
-- notification minutes-to-never later, and is picked up by harvest().
function M.request(ifname, sta, opts)
	if not ifname or not sta then return false end
	opts = opts or {}
	local cmd = string.format(
		"ubus call hostapd.%s rrm_beacon_req " ..
		"'{\"addr\":\"%s\",\"mode\":%d,\"op_class\":%d,\"channel\":%d,\"duration\":%d}' " ..
		">/dev/null 2>&1",
		ifname, sta, opts.mode or M.MODE_ACTIVE, opts.op_class or 115,
		opts.channel or 255, opts.duration or 50)
	M._exec(cmd)
	return true
end

-- Is the background collector alive? It is a plain `ubus subscribe` child, so
-- this doubles as the restart trigger: the subscription dies whenever one of
-- the hostapd objects it named goes away, which a `wifi reload` does on every
-- config push.
--
-- Anchored, so the shell that runs pgrep (whose own command line contains the
-- pattern) is never counted as the collector.
function M.collector_pids()
	local out = M._popen("pgrep -f '" .. SUBSCRIBE_MATCH .. "' 2>/dev/null") or ""
	local pids = {}
	for p in out:gmatch("%d+") do pids[#pids + 1] = p end
	return pids
end

function M.collector_running()
	return #M.collector_pids() > 0
end

M._file_exists = function(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

-- Every hostapd BSS object currently on ubus.
function M.hostapd_objects()
	local out = M._popen("ubus list 2>/dev/null") or ""
	local objs = {}
	for line in out:gmatch("[^\n]+") do
		local o = line:match("^(hostapd%.[%w%-%._]+)%s*$")
		if o then objs[#objs + 1] = o end
	end
	table.sort(objs)
	return objs
end

-- (Re)start the collector across every current BSS. Safe to call on every
-- cycle: it is a no-op while one is running.
--
-- A collector alive with its file gone writes every report into an unlinked
-- inode nobody can read, and still counts as running. Seen on all three home
-- APs on 2026-10-03 (/proc/<pid>/fd/1 -> "/tmp/openuf-rrm.jsonl (deleted)"):
-- collector_stop() used pkill, which OpenWrt's busybox does not have, so the
-- stop removed the file and left the collector. Such a collector is replaced.
function M.collector_ensure()
	if M.collector_running() then
		if M._file_exists(M.EVENT_FILE) then return false end
		M.collector_stop()
	end
	local objs = M.hostapd_objects()
	if #objs == 0 then return false end
	M._exec("ubus subscribe " .. table.concat(objs, " ") ..
		" >> " .. M.EVENT_FILE .. " 2>/dev/null &")
	return true
end

-- By pid from pgrep: busybox on OpenWrt 25.12 has no pkill.
function M.collector_stop()
	local pids = M.collector_pids()
	if #pids > 0 then
		M._exec("kill " .. table.concat(pids, " ") .. " 2>/dev/null")
	end
	M.monitors_stop()
	M._exec("rm -f " .. M.EVENT_FILE .. " " .. M.ACTION_SCRIPT .. " 2>/dev/null")
end

-- The control-socket half of the collector. hostapd's ubus beacon-report
-- notification carries only the fixed fields; the same report's subelements
-- -- the neighbour's beacon body -- reach only hostapd's control socket, as
-- BEACON-RESP-RX. One `hostapd_cli -a` per BSS listens there and runs this
-- script per event, which appends the beacon reports, uptime-stamped like the
-- ubus lines, to the same EVENT_FILE, so a single drain() still reads both.
-- hostapd_cli runs it as "<script> <ifname> <event words...>".
M.ACTION_SCRIPT   = "/tmp/openuf-bresp.sh"
M.HOSTAPD_CTRL_DIR = "/var/run/hostapd"

function M.action_script()
	return table.concat({
		"#!/bin/sh",
		"# openUF hostapd control-socket hook -- written by rrmscan.lua, do not edit.",
		'[ "$2" = BEACON-RESP-RX ] || exit 0',
		"read -r u _ < /proc/uptime",
		"printf '%s %s\\n' \"$u\" \"$*\" >> " .. M.EVENT_FILE,
	}, "\n") .. "\n"
end

-- Control sockets hostapd has open: one per BSS, plus "global".
function M.ctrl_ifaces()
	local out = M._popen("ls " .. M.HOSTAPD_CTRL_DIR .. " 2>/dev/null") or ""
	local list = {}
	for name in out:gmatch("[^\n]+") do
		if name ~= "global" and name:match("^[%w%-%._]+$") then list[#list + 1] = name end
	end
	table.sort(list)
	return list
end

local function monitor_cmd(ifname)
	return "hostapd_cli -p " .. M.HOSTAPD_CTRL_DIR .. " -i " .. ifname
		.. " -a " .. M.ACTION_SCRIPT
end

-- Start a monitor for every BSS that has none. A monitor exits once hostapd
-- stops answering it (a `wifi reload` replaces the sockets), so this runs on
-- the same liveness clock as collector_ensure and simply starts it again.
-- A changed script (an openUF upgrade) replaces every monitor. Returns how
-- many were started.
function M.monitors_ensure()
	local want = M.action_script()
	local fresh = M._read_file(M.ACTION_SCRIPT) ~= want
	if fresh then
		M.monitors_stop()
		local f = io.open(M.ACTION_SCRIPT, "w")
		if not f then return 0 end
		f:write(want)
		f:close()
		M._exec("chmod 755 " .. M.ACTION_SCRIPT)
	end
	local ps = fresh and "" or (M._popen("ps w 2>/dev/null") or "")
	local started = 0
	for _, ifname in ipairs(M.ctrl_ifaces()) do
		if not ps:find(monitor_cmd(ifname), 1, true) then
			M._exec(monitor_cmd(ifname) .. " -B >/dev/null 2>&1")
			started = started + 1
		end
	end
	return started
end

-- Same bracket trick as collector_stop, for the same reason.
function M.monitors_stop()
	M._exec("kill $(pgrep -f '[h]ostapd_cli .*-a " .. M.ACTION_SCRIPT .. "') 2>/dev/null")
end

-- Drain the notification file into neighbour records.
--
-- Parsed with patterns rather than cjson on purpose: the notification carries
-- a "start-time" holding a raw 64-bit TSF that real clients emit past what a
-- double represents (-7160986498777481216 was observed), and nothing here
-- needs it. Matching only the fields we use sidesteps the question entirely.
--
-- The file is read whole and then truncated. The collector holds it O_APPEND,
-- so a notification written between the read and the truncate is lost rather
-- than corrupted -- acceptable for opportunistic enrichment, and the next
-- request re-reports the same neighbourhood anyway.
-- blob: the events to read (tests); nil drains EVENT_FILE.
function M.harvest(blob)
	if blob == nil then
		local f = io.open(M.EVENT_FILE, "r")
		if not f then return {}, {} end
		blob = f:read("*a") or ""
		f:close()
		local t = io.open(M.EVENT_FILE, "w")
		if t then t:close() end
	end

	local now, seen, out = M._now(), {}, {}
	-- Every station that produced an ANSWER, alongside the neighbours it
	-- reported. The caller uses it to tell a station that answers from one
	-- that only ever acknowledges: hostapd notifies over ubus only when a
	-- report BODY arrived, so a bodiless refusal never reaches this file at
	-- all and its ABSENCE is the only signal there is. A bodied refusal
	-- (rep-mode non-zero) is a station declining too, so it does not count
	-- here either.
	local reporters = {}
	-- Control-socket reports first: they carry the neighbour's beacon body,
	-- so for a BSSID both paths reported, this is the record that is kept.
	-- The hook writes "<uptime> <ifname> BEACON-RESP-RX ...": the interface
	-- is what the station's own BSS is looked up by, for calibration.
	local ctrl, own_rec, sta_if = {}, {}, {}
	for line in blob:gmatch("[^\n]+") do
		local pre, sta, rep, hex = line:match(
			"^(.-)BEACON%-RESP%-RX (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x) %d+ (%x+) (%x+)")
		if sta and tonumber(rep, 16) == 0 then
			sta = sta:lower()
			reporters[sta] = true
			local r = M.parse_report(hex)
			if r then
				ctrl[#ctrl + 1] = {sta = sta, rec = r}
				local ifname = pre:match("(%S+)%s*$")
				if ifname and not sta_if[sta] then sta_if[sta] = ifname end
			end
		end
	end
	for sta, ifname in pairs(sta_if) do
		local own = M.iface_bssid(ifname)
		for _, c in ipairs(ctrl) do
			if c.sta == sta and c.rec.bssid == own then own_rec[sta] = c.rec break end
		end
		if own_rec[sta] then
			local v = M.rcpi_verdict(own_rec[sta].rcpi, M.sta_signal(ifname, sta))
			if v ~= nil then M._rcpi_signed[sta] = v end
		end
	end
	for _, c in ipairs(ctrl) do
		local r = c.rec
		if r.band and r.bssid ~= "00:00:00:00:00:00" and not seen[r.bssid] then
			seen[r.bssid] = true
			r.signal = M.signal_of(c.sta, r.rcpi)
			r.seen_at = now
			out[#out + 1] = r
		end
	end
	for body in blob:gmatch('"beacon%-report":%s*(%b{})') do
		local address  = body:match('"address":"(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)"')
		local bssid    = body:match('"bssid":"(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)"')
		local channel  = tonumber(body:match('"channel":(%-?%d+)'))
		local rcpi     = tonumber(body:match('"rcpi":(%-?%d+)'))
		-- rep-mode is the measurement report mode: any non-zero value means
		-- the client refused, was incapable, or the measurement was
		-- unavailable, and those arrive with an all-zero BSSID. Reporting one
		-- would put 00:00:00:00:00:00 on ch 0 in the Environment tab.
		local repmode  = tonumber(body:match('"rep%-mode":(%-?%d+)')) or 0
		if address and repmode == 0 then reporters[address:lower()] = true end
		local band     = M.band_of_channel(channel)
		if bssid and band and repmode == 0
		   and bssid ~= "00:00:00:00:00:00" and not seen[bssid] then
			seen[bssid] = true
			out[#out + 1] = {
				bssid   = bssid,
				channel = channel,
				band    = band,
				signal  = M.signal_of(address, rcpi),
				seen_at = now,
			}
		end
	end
	return out, reporters
end

-- Merge harvested neighbours into one radio's scan_table.
--
-- `entries` is the payload-shaped list already built from the passive scan
-- cache; anything the cache knows wins, because it is the radio's own
-- measurement and carries the sibling tag (is_unifi/serialno) that a beacon
-- report cannot: the tag rides in a vendor element at the END of the beacon,
-- past where a client's reported frame body is cut. Only genuinely new
-- BSSIDs on this radio's band are appended.
--
-- opts.max_age drops stale records: the controller's rogue-AP ingestion
-- silently discards any entry whose age is 30 or more, so a record held past
-- that would be payload weight nobody reads. Reporting each one for a cycle or
-- two and letting it fall out mirrors what a real scan produces, and the
-- controller keeps its own history of what it was told.
--
-- opts.skip: BSSIDs never to report (lowercase keys) -- this AP's own. A
-- client reports the AP it sits on like any other BSS; a UniFi AP never lists
-- itself.
--
-- opts.siblings: BSSIDs of sibling openUF APs (lowercase keys), which the
-- caller tags is_unifi after the merge (sysinfo.sibling_bssids); they keep
-- their SSID.
--
-- opts.site_ssids: this site's own SSIDs. Any other reported BSS carrying one
-- would go out untagged with the site's SSID, which the controller flags as an
-- impersonating rogue, so its SSID is withheld. The trade: an evil twin that
-- only a client ever saw is not flagged.
function M.merge_into(entries, neighbours, opts)
	entries = entries or {}
	opts    = opts or {}
	local band    = opts.band
	local now     = opts.now or M._now()
	local max_age = opts.max_age or 30
	local skip    = opts.skip or {}
	local site    = opts.site_ssids or {}
	local known   = opts.siblings or {}
	local have = {}
	for _, e in ipairs(entries) do
		if e.bssid then have[e.bssid] = true end
	end
	for _, n in ipairs(neighbours or {}) do
		local age = now - (n.seen_at or now)
		if age < 0 then age = 0 end
		if n.band == band and not have[n.bssid] and age < max_age
		   and not skip[n.bssid:lower()] then
			have[n.bssid] = true
			entries[#entries + 1] = {
				mac        = n.bssid,
				bssid      = n.bssid,
				radio      = opts.radio,
				radio_name = opts.radio_name,
				-- `band` is the field the Environment tab filters on
				-- unconditionally; an entry without it vanishes with no
				-- visible cause. See inform.lua's note on the same field.
				band       = opts.radio,
				channel    = n.channel,
				freq       = M.freq_of_channel(n.channel),
				rssi       = n.signal,
				signal     = n.signal,
				-- What the report proved (parse_report), and nothing more.
				--
				-- bw falls back to 20 because every AP occupies at least its
				-- 20 MHz primary channel, so it is a floor rather than a guess --
				-- and because the Environment tab's unconditional filter indexes
				-- T.R[band][bw>0 ? bw : <a per-band default>]: a falsy bw falls
				-- through to a default this controller build may not define, and
				-- an undefined index drops the row silently. 20 is confirmed to
				-- render; nil is not.
				bw         = n.bw or 20,
				age        = age,
				-- security is left ABSENT when unproven, never defaulted:
				-- writing "open" would state, in the operator's rogue-AP view,
				-- that a neighbour is unencrypted when nothing measured it.
				-- Observed live -- four WPA2 neighbours rendered as "open"
				-- before the default was removed.
				security   = n.security,
				essid      = (n.essid and (known[n.bssid:lower()] or not site[n.essid]))
					and n.essid or nil,
			}
		end
	end
	return entries
end

-- ─── Scheduling ──────────────────────────────────────────────────────────────

-- Matches merge_into's own cutoff, which exists because the controller's
-- rogue-AP ingestion silently drops any entry with age >= 30.
M.MAX_AGE = 30

-- Start the inform heartbeat loop (blocks forever).
-- cfg, ufhw: passed through to build_json()
-- One cycle of the client-assisted enrichment: keep the notification
-- collector alive, fold in whatever clients have reported since last time,
-- expire what the controller would discard anyway, and -- at most every
-- RRM_REQUEST_INTERVAL -- ask one more station to go and look.
--
-- Everything here is pcall-wrapped and best-effort: no hostapd, no ubus, no
-- capable client and no answer are all ordinary outcomes, and none of them may
-- interrupt an inform.
function M.tick(ctx, cfg)
	local rrm = ctx._rrmscan
	if not rrm then return false end
	if not (cfg and cfg.config and cfg.config.rrm_enrichment) then
		-- Enrichment is off, but a collector from an earlier run with it ON may
		-- still be alive: it is a detached `ubus subscribe` child reparented to
		-- init, so it outlives both the config change and the daemon. Nothing
		-- below this line runs any more, and harvest() is the ONLY thing that
		-- truncates the notification file -- so left alone the child appends to
		-- /tmp/openuf-rrm.jsonl forever with no reader and no cap. /tmp is a
		-- RAM disk on these boards; the debug-dump cap above exists because
		-- 31.7 MB there was measured starving state.json writes and apk.
		--
		-- Rate-limited on the collector's own liveness clock rather than run
		-- every tick: this is a pgrep, and there is nothing to catch between
		-- checks once the child is gone.
		local now = ctx._time()
		if now >= ctx._rrm_collector_next then
			ctx._rrm_collector_next = now + ctx.RRM_COLLECTOR_CHECK_INTERVAL
			local ok_r, running = pcall(rrm.collector_running)
			if ok_r and running then pcall(rrm.collector_stop) end
			pcall(rrm.monitors_stop)
		end
		return false
	end

	-- On ctx._time(), the seam the rest of the timed paths use, so the gate below
	-- is testable. Note this is also the clock the age-out compares against,
	-- and n.seen_at comes from rrmscan's own ctx._now -- a test that stubs one
	-- must stub the other, or "freshness" is measured between two clocks.
	local now = ctx._time()
	if now >= ctx._rrm_collector_next then
		ctx._rrm_collector_next = now + ctx.RRM_COLLECTOR_CHECK_INTERVAL
		pcall(rrm.collector_ensure)
		-- The control-socket half: the beacon body reaches only hostapd's
		-- control socket (BEACON-RESP-RX), not its ubus notification.
		pcall(rrm.monitors_ensure)
	end

	local ok, fresh, reporters = pcall(rrm.harvest)
	if ok then
		-- A station that answered is off the bench, whatever it reported.
		for mac in pairs(reporters or {}) do ctx._rrm_asked[mac] = nil end
		for _, n in ipairs(fresh or {}) do
			-- Keyed by BSSID so a neighbour two clients both saw is carried
			-- once, at whichever sighting is freshest.
			local prev = ctx._rrm_cache[n.bssid]
			if not prev or n.seen_at >= prev.seen_at then
				-- hostapd emits each report twice: on the control socket with
				-- the neighbour's beacon body, then over ubus without. The two
				-- reach the event file through different processes and land in
				-- different drains often enough (upstream, live 2026-10-13:
				-- every row of one report went out unnamed, on the 80 MHz centre
				-- channel 42 at 20 MHz). A bodiless copy keeps what the body
				-- proved about the same BSS instead of erasing it.
				if prev and prev.body and not n.body and prev.band == n.band then
					n.essid, n.security, n.bw = prev.essid, prev.security, prev.bw
					n.channel, n.body = prev.channel, true
				end
				ctx._rrm_cache[n.bssid] = n
			end
		end
	end

	local live = {}
	for bssid, n in pairs(ctx._rrm_cache) do
		if now - n.seen_at < M.MAX_AGE then
			live[#live + 1] = n
		else
			ctx._rrm_cache[bssid] = nil
		end
	end
	table.sort(live, function(a, b) return a.bssid < b.bssid end)
	ctx._rrm_neighbours = live

	if now < ctx._rrm_next_request then return true end
	ctx._rrm_next_request = now +
		(tonumber(cfg.config.rrm_request_interval) or ctx.RRM_REQUEST_INTERVAL)

	-- Round-robin across every capable station on every BSS, one per
	-- interval. Asking them all at once would take every 802.11k-capable
	-- client in the house off-channel simultaneously.
	local cands = {}
	local ok_o, objs = pcall(rrm.hostapd_objects)
	for _, obj in ipairs(ok_o and objs or {}) do
		local ifname = obj:match("^hostapd%.(.+)$")
		local ok_s, stas, modes = pcall(rrm.capable_stations, ifname)
		for _, sta in ipairs(ok_s and stas or {}) do
			local key   = tostring(sta):lower()
			local asked = ctx._rrm_asked[key]
			local spent = asked and asked.n >= ctx.RRM_MAX_UNANSWERED
			if spent and (now - asked.at) >= ctx.RRM_BENCH_SECONDS then
				ctx._rrm_asked[key] = nil   -- bench over: one more try, clean count
				spent = false
			end
			if not spent then
				cands[#cands + 1] = {ifname = ifname, sta = sta,
					mode = modes and modes[sta] or M.MODE_ACTIVE}
			end
		end
	end
	if #cands == 0 then return true end
	ctx._rrm_rr = (ctx._rrm_rr % #cands) + 1
	local c = cands[ctx._rrm_rr]
	local key = tostring(c.sta):lower()
	local asked = ctx._rrm_asked[key] or {n = 0}
	asked.n, asked.at = asked.n + 1, now
	ctx._rrm_asked[key] = asked
	if asked.n == ctx.RRM_MAX_UNANSWERED then
		io.stderr:write(string.format(
			"openuf: rrm: %s on %s advertises beacon measurement but has answered none "
			.. "of %d requests -- not asking again for %d h\n",
			c.sta, c.ifname, asked.n - 1, math.floor(ctx.RRM_BENCH_SECONDS / 3600)))
	end
	-- The operating class has to be one the CLIENT can measure. Asking every
	-- station for class 115 (5 GHz U-NII-1) works for a dual-band client --
	-- they ignore the band restriction and answer for 2.4 GHz too -- but a
	-- 2.4 GHz-only station answers it with report mode 0x02, "incapable", and
	-- an all-zero BSSID, which is nothing at all. So a station on a 2.4 GHz
	-- BSS is asked for class 81 (2.4 GHz, channels 1-13) instead; the band
	-- comes from that BSS's live channel.
	local op_class = 115
	local ok_c, caps = pcall(ctx._sysinfo.radio_caps, c.ifname)
	if ok_c and type(caps) == "table" and caps.channel and caps.channel <= 14 then
		op_class = 81
	end
	if c.mode == M.MODE_TABLE then
		-- What its cache holds, every band: the form a table-only client
		-- answered live (op_class 0, channel 0, no measurement duration).
		pcall(rrm.request, c.ifname, c.sta,
			{mode = M.MODE_TABLE, op_class = 0, channel = 0, duration = 0})
	else
		pcall(rrm.request, c.ifname, c.sta, {op_class = op_class})
	end
	return true
end

return M
