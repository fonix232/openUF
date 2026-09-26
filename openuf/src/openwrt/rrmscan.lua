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

	A beacon report also carries less than a scan does: a BSSID, a channel and
	an RCPI, but no SSID, no security and no channel width. Entries that the
	passive cache already knows keep the cache's richer version; entries only
	the client can see are reported with what there is. The controller renders
	a missing WiFi Name as the BSSID, so they are still useful rows.
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

-- Where the background collector parks hostapd's ubus notifications.
M.EVENT_FILE = "/tmp/openuf-rrm.jsonl"

-- hostapd delivers a beacon report as a ubus NOTIFICATION on the per-BSS
-- object, not as a broadcast event. `ubus listen` -- which catches broadcasts
-- -- therefore sees nothing at all here, however long it waits; only
-- `ubus subscribe hostapd.<iface>` receives them. Confirmed live: a listen
-- across two requests captured zero notifications while a subscribe over the
-- same window captured 22 beacon-reports.
local SUBSCRIBE_MATCH = "ubus subscribe hostapd"

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

-- RM Enabled Capabilities bits (IEEE 802.11-2020 9.4.2.44), as hostapd's
-- get_clients exposes them in the first byte of "rrm".
local RRM_BEACON_PASSIVE = 0x10  -- bit 4
local RRM_BEACON_ACTIVE  = 0x20  -- bit 5

-- Stations on this BSS that can actually go and look. Deliberately requires
-- passive or active measurement and NOT beacon-table: a table-only client
-- reports from a cache it may never have filled, and the one real example
-- observed acked every request and answered none. hostapd agrees about the
-- direction -- asking a table-only client for a passive measurement is
-- refused by hostapd itself with "does not support passive beacon report",
-- before anything reaches the air.
function M.capable_stations(ifname)
	if not ifname then return {} end
	local out = M._popen("ubus call hostapd." .. ifname .. " get_clients 2>/dev/null") or ""
	local stations = {}
	for mac, block in out:gmatch('"(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)":%s*(%b{})') do
		local rrm = tonumber(block:match('"rrm":%s*%[%s*(%d+)')) or 0
		if rrm % (RRM_BEACON_PASSIVE * 2) >= RRM_BEACON_PASSIVE
		   or rrm % (RRM_BEACON_ACTIVE * 2) >= RRM_BEACON_ACTIVE then
			stations[#stations + 1] = mac
		end
	end
	table.sort(stations)  -- deterministic, so round-robin actually rotates
	return stations
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
		"'{\"addr\":\"%s\",\"mode\":%d,\"op_class\":%d,\"channel\":255,\"duration\":%d}' " ..
		">/dev/null 2>&1",
		ifname, sta, opts.mode or 1, opts.op_class or 115, opts.duration or 50)
	M._exec(cmd)
	return true
end

-- Is the background collector alive? It is a plain `ubus subscribe` child, so
-- this doubles as the restart trigger: the subscription dies whenever one of
-- the hostapd objects it named goes away, which a `wifi reload` does on every
-- config push.
function M.collector_running()
	local out = M._popen("pgrep -f '" .. SUBSCRIBE_MATCH .. "' 2>/dev/null") or ""
	return out:match("%d") ~= nil
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
function M.collector_ensure()
	if M.collector_running() then return false end
	local objs = M.hostapd_objects()
	if #objs == 0 then return false end
	M._exec("ubus subscribe " .. table.concat(objs, " ") ..
		" >> " .. M.EVENT_FILE .. " 2>/dev/null &")
	return true
end

function M.collector_stop()
	M._exec("pkill -f '" .. SUBSCRIBE_MATCH .. "' 2>/dev/null")
	M._exec("rm -f " .. M.EVENT_FILE .. " 2>/dev/null")
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
function M.harvest()
	local f = io.open(M.EVENT_FILE, "r")
	if not f then return {}, {} end
	local blob = f:read("*a") or ""
	f:close()
	local t = io.open(M.EVENT_FILE, "w")
	if t then t:close() end

	local now, seen, out = M._now(), {}, {}
	-- Every station that produced an ANSWER, alongside the neighbours it
	-- reported. The caller uses it to tell a station that answers from one
	-- that only ever acknowledges: hostapd notifies over ubus only when a
	-- report BODY arrived, so a bodiless refusal never reaches this file at
	-- all and its ABSENCE is the only signal there is. A bodied refusal
	-- (rep-mode non-zero) is a station declining too, so it does not count
	-- here either.
	local reporters = {}
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
				signal  = M.rcpi_to_dbm(rcpi),
				seen_at = now,
			}
		end
	end
	return out, reporters
end

-- Merge harvested neighbours into one radio's scan_table.
--
-- `entries` is the payload-shaped list already built from the passive scan
-- cache; anything the cache knows wins, because it carries an SSID, a security
-- mode and a width that a beacon report simply does not have. Only genuinely
-- new BSSIDs on this radio's band are appended.
--
-- opts.max_age drops stale records: the controller's rogue-AP ingestion
-- silently discards any entry whose age is 30 or more, so a record held past
-- that would be payload weight nobody reads. Reporting each one for a cycle or
-- two and letting it fall out mirrors what a real scan produces, and the
-- controller keeps its own history of what it was told.
function M.merge_into(entries, neighbours, opts)
	entries = entries or {}
	opts    = opts or {}
	local band    = opts.band
	local now     = opts.now or M._now()
	local max_age = opts.max_age or 30
	local have = {}
	for _, e in ipairs(entries) do
		if e.bssid then have[e.bssid] = true end
	end
	for _, n in ipairs(neighbours or {}) do
		local age = now - (n.seen_at or now)
		if age < 0 then age = 0 end
		if n.band == band and not have[n.bssid] and age < max_age then
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
				-- A beacon report carries no SSID, no security mode and no
				-- width. Each of those absences is handled differently, and the
				-- difference matters:
				--
				-- bw is set to 20 because every AP occupies at least its 20 MHz
				-- primary channel, so it is a floor rather than a guess -- and
				-- because the Environment tab's unconditional filter indexes
				-- T.R[band][bw>0 ? bw : <a per-band default>]: a falsy bw falls
				-- through to a default this controller build may not define, and
				-- an undefined index drops the row silently. 20 is confirmed to
				-- render; nil is not.
				bw         = 20,
				age        = age,
				-- security is left ABSENT, not defaulted. There is no floor to
				-- fall back on here: writing "open" would state, in the operator's
				-- rogue-AP view, that a neighbour is unencrypted when nothing
				-- measured it. Observed live -- four WPA2 neighbours reported by a
				-- client all rendered as "open" before this was removed. A blank
				-- cell is the honest answer, and no filter keys on this field.
				security   = nil,
				essid      = nil,
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
		local ok_s, stas = pcall(rrm.capable_stations, ifname)
		for _, sta in ipairs(ok_s and stas or {}) do
			local key   = tostring(sta):lower()
			local asked = ctx._rrm_asked[key]
			local spent = asked and asked.n >= ctx.RRM_MAX_UNANSWERED
			if spent and (now - asked.at) >= ctx.RRM_BENCH_SECONDS then
				ctx._rrm_asked[key] = nil   -- bench over: one more try, clean count
				spent = false
			end
			if not spent then
				cands[#cands + 1] = {ifname = ifname, sta = sta}
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
	pcall(rrm.request, c.ifname, c.sta, {op_class = op_class})
	return true
end

return M
