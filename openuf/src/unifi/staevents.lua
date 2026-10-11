--[[
	Client connection events: the controller's STA_ASSOC_TRACKER notifications.

	A UniFi AP does not leave client history to the periodic sta_table. Every
	association, successful connection, failed attempt and departure is
	reported as a separate NOTIFICATION inform -- `inform_as_notif: true`,
	`notif_reason: "event"` and a `notif_payload` whose `message_type` is
	STA_ASSOC_TRACKER. The controller (10.6.106, devmgr.w.a) dispatches on
	`event_type`:

	  association   the roaming detector records where the client joined
	                (needs auth_rssi, or it is ignored)
	  success       the WiFi Connectivity view: one connection, and how long
	                each phase of it took
	  failure       the same view: an attempt that failed, and at which phase
	  sta_leave     the disconnect time (from last_seen, in device-uptime
	                seconds) and the roaming detector's "left" half
	  sta_roam      the roaming detector's "left" half for a client that
	                roamed away, read only from a device claiming wifi_caps2
	                0x2000 (supportsRoamTopologyStats); it does not reach the
	                station manager, so a sta_leave still follows it

	Each departure carries assoc_status, the cause bits the roaming detector
	reads (10.6.106 devmgr.w.a.Cuhf, enum rFCHnXVpfjjP): 16 when openUF's
	Minimum RSSI kicked the client, 8192 when its Roaming Assistant moved it.
	They become the roam record's triggeredByMinRssi /
	triggeredByRoamingAssistant. A departure the Roaming Assistant's BSS
	Transition request caused (the client left inside the request's grace,
	before any forced disassociation) is also sent as sta_roam, which the
	controller counts as a seamless roam. With 0x2000 claimed, the
	controller stops feeding `success` to the roaming detector and joins
	the "joined" half from `association` alone, which carries auth_rssi.

	A roam is the controller pairing one AP's sta_leave with another AP's
	association for the same client, so nothing here has to know about the
	other APs. Every event names the VAP by vap_table `name` -- the controller
	drops one whose VAP it cannot find.

	Roam reports -- association, sta_leave, sta_roam -- are event-driven
	(roam_ingest below, upstream ea0b5d6): the controller's roaming detector
	(devmgr wifiRoamingDetector) keeps each client's last event for 10 s and
	pairs a departure from one AP with an arrival at another, in either
	order, by its own receive time; a sta_leave more than a second ahead of
	the association is a failed roam with that gap as its disconnect time.
	A heartbeat diff would put a departure up to a heartbeat late, and
	hostapd keeps a silently departed client listed for 6-40 s, so the
	collector (openwrt/staphase.uc) logs hostapd's assoc / sta-authorized /
	disassoc and the bridge's fdb moves the moment they happen, and
	inform.lua's idle wait reads that log every ROAM_POLL_S and sends a
	report at once:

	  association  once hostapd reports the client authorized, with the
	               assoc's signal as auth_rssi and auth-alg as auth_algo
	               ("ft" = Fast Roaming); a failed handshake is no arrival
	  sta_leave    on hostapd's disassoc, unless the client is already on
	               another BSS of this AP (a band change is no roam)
	  sta_roam     when the client's address is learned on a bridge port
	               that is none of this AP's BSSes while hostapd still lists
	               it: it is behind another AP now. hostapd's later drop is
	               not reported again, and the heartbeat leaves the client
	               out until then (roamed_away), or 10.6's roam fallback
	               records the move a second time, without tags.

	The heartbeat diff below still times connections (success) from iw's
	"connected time".

	A success needs more. For an AP on firmware 6.2.1 or later the controller
	counts one only with traffic_delta > 0 and dns_responses > 0 (anything else
	is held in memory and dropped), and it draws the phases from cumulative
	deltas in µs since the first Authentication frame, each at most a minute:

	  assoc_delta     association                    -> "Association"
	  wpa_auth_delta  key handshake done               -> "Authentication" (minus assoc)
	  ip_delta        DHCP ACK                          -> "DHCP" (minus auth)
	  traffic_delta   first DNS answer                  -> "DNS" (minus DHCP); the total

	The device side measures them (openwrt/staphase.lua: hostapd's steps, and
	nftables for DHCP and DNS); deltas() turns that timeline into the fields.
	A success waits for its first DNS answer, and is not sent at all when none
	came: an unverified one would be dropped by the controller anyway.
	Failures are the wrong-passphrase attempts hostapd reports, one event per
	client per FAIL_WINDOW carrying the count.
]]--

local M = {}

M.MESSAGE_TYPE = "STA_ASSOC_TRACKER"
-- Bounds: a `wifi reload` drops and re-adds every client at once, and a
-- controller that is down must not turn the queue into a memory leak.
M.MAX_QUEUE    = 200
M.MAX_PER_TICK = 8
-- How long a join's `success` waits for its first DNS answer: the
-- controller's deltas stop at a minute, plus a heartbeat.
M.SUCCESS_WAIT = 80
-- The controller's ceiling for any delta, µs.
M.MAX_DELTA = 60 * 1000000
-- How far the device's timeline and iw's connected time may disagree on when
-- the client joined, seconds (iw counts whole seconds).
M.MATCH_WINDOW = 5
-- Failed attempts of one client within this many seconds go out as one event.
M.FAIL_WINDOW = 60
-- The controller's assoc_status cause bits (devmgr.w.a.rFCHnXVpfjjP).
M.KICKED_DUE_TO_MIN_RSSI         = 16
M.MOVED_DUE_TO_ROAMING_ASSISTANT = 8192

M._prev     = nil  -- {uptime = n, stas = {mac -> {vap, signal, uptime, idle}}}
M._queue    = {}
M._held     = {}   -- mac -> {ev = success event, at = when it was held}
M._fail_seq = nil  -- the last failure (the collector's seq) already counted
M._failing  = {}   -- mac -> aggregated failures not yet sent

local function event_id(mac, kind, ts)
	-- Unique per event, stable for a retry of the same one.
	local s = tostring(mac) .. kind .. tostring(ts)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

local function base(kind, mac, sta, ts)
	return {
		message_type = M.MESSAGE_TYPE,
		event_type   = kind,
		event_id     = event_id(mac, kind, ts),
		mac          = mac,
		vap          = sta.vap,
		auth_ts      = ts,
	}
end

-- The events one client's appearance produces.
local function joined(mac, sta, now)
	local ts = now - (tonumber(sta.uptime) or 0)
	local rssi = tonumber(sta.signal)
	local a = base("association", mac, sta, ts)
	a.auth_rssi    = rssi
	a.assoc_status = 0
	local s = base("success", mac, sta, ts)
	s.auth_rssi         = rssi
	s.avg_rssi          = rssi
	s.assoc_failures    = 0
	s.auth_failures     = 0
	s.wpa_auth_failures = 0
	s.ip_failures       = 0
	s.traffic_failures  = 0
	s.dns_timeouts      = 0
	s.arp_reply_gw_seen = "N/A"
	s.dns_resp_seen     = "N/A"
	return a, s
end

-- The controller's latency deltas from one connection's timeline
-- ({auth, assoc, authorized, dhcp, dns}, µs on one clock): cumulative from the
-- first Authentication frame, each only where it is later than the step
-- before it -- a DHCP ACK or DNS answer from before the client could send
-- data belongs to an earlier connection.
function M.deltas(c)
	local out = {}
	local t0 = type(c) == "table" and tonumber(c.auth)
	if not t0 then return out end
	local function since(t)
		t = tonumber(t)
		if t and t > t0 and t - t0 <= M.MAX_DELTA then return math.floor(t - t0) end
	end
	out.assoc_delta    = since(c.assoc)
	out.wpa_auth_delta = since(c.authorized)
	if not out.wpa_auth_delta then return out end
	local ready = tonumber(c.authorized)
	if tonumber(c.dhcp) and c.dhcp > ready then
		out.ip_delta = since(c.dhcp)
		if out.ip_delta then ready = c.dhcp end
	end
	if tonumber(c.dns) and c.dns > ready then out.traffic_delta = since(c.dns) end
	return out
end

-- A held success, completed from the device's timeline of the same
-- connection. False until its first DNS answer has been timed.
local function complete(ev, c)
	if type(c) ~= "table" or not tonumber(c.authorized) then return false end
	if math.abs(c.authorized / 1000000 - (tonumber(ev.auth_ts) or 0)) > M.MATCH_WINDOW then
		return false
	end
	local d = M.deltas(c)
	if not d.traffic_delta then return false end
	for k, v in pairs(d) do ev[k] = v end
	ev.dns_responses = 1
	ev.dns_resp_seen = "yes"
	if d.ip_delta then ev.ip_assign_type = "dhcp" end
	return true
end

local function left(mac, sta, prev_uptime, now)
	local e = base("sta_leave", mac, sta, now)
	-- Device uptime at the client's last activity, as the controller expects.
	local idle = tonumber(sta.idle) or 0
	e.last_seen = math.max(0, (tonumber(prev_uptime) or 0) - idle)
	e.avg_rssi  = tonumber(sta.signal)
	e.assoc_status = 0
	return e
end

-- The sta_roam twin of one sta_leave: the same fields under its own id.
local function roamed(leave)
	local r = {}
	for k, v in pairs(leave) do r[k] = v end
	r.event_type = "sta_roam"
	r.event_id = event_id(leave.mac, "sta_roam", leave.auth_ts or leave.last_seen)
	return r
end

-- Compare two station snapshots ({mac -> {vap, signal, uptime, idle}}) and
-- return the events between them, oldest first. `prev` nil (the first
-- heartbeat after a start) produces nothing: every client would otherwise be
-- reported as a fresh association after each daemon restart.
function M.diff(prev, cur, now, prev_uptime)
	local out = {}
	if type(prev) ~= "table" or type(cur) ~= "table" then return out end
	local macs = {}
	for mac in pairs(prev) do macs[#macs + 1] = mac end
	for mac in pairs(cur) do if not prev[mac] then macs[#macs + 1] = mac end end
	table.sort(macs)
	for _, mac in ipairs(macs) do
		local p, c = prev[mac], cur[mac]
		if p and not c then
			out[#out + 1] = left(mac, p, prev_uptime, now)
		elseif c and not p then
			local a, s = joined(mac, c, now)
			out[#out + 1] = a
			out[#out + 1] = s
		elseif p.vap ~= c.vap
			or (tonumber(c.uptime) and tonumber(p.uptime) and tonumber(c.uptime) < tonumber(p.uptime)) then
			-- Moved to another VAP here, or dropped and came back between two
			-- heartbeats (its connected time went backwards).
			out[#out + 1] = left(mac, p, prev_uptime, now)
			local a, s = joined(mac, c, now)
			out[#out + 1] = a
			out[#out + 1] = s
		end
	end
	return out
end

local function enqueue(e)
	if #M._queue >= M.MAX_QUEUE then table.remove(M._queue, 1) end
	M._queue[#M._queue + 1] = e
end

-- Fold the collector's new failed attempts into per-client aggregates, and
-- queue the aggregates whose window has closed. The first call only notes
-- where the collector is: its file survives a daemon restart, and what it
-- already holds was counted by the previous run.
local function failures(list, now)
	local top = 0
	for _, f in ipairs(list or {}) do if f.seq > top then top = f.seq end end
	if M._fail_seq == nil then
		M._fail_seq = top
		return
	end
	if top < M._fail_seq then M._fail_seq = 0 end  -- the collector restarted
	for _, f in ipairs(list or {}) do
		if f.seq > M._fail_seq and f.vap then
			local agg = M._failing[f.mac]
			if not agg then
				-- Failed before associating is the SAE exchange rejecting the
				-- passphrase; after, it is the 4-way handshake.
				agg = {at = now, vap = f.vap, signal = f.signal, count = 0,
					ts = math.floor((f.auth or f.at) / 1000000),
					counter = f.assoc and "wpa_auth_failures" or "auth_failures",
					assoc_delta = M.deltas({auth = f.auth, assoc = f.assoc}).assoc_delta}
				M._failing[f.mac] = agg
			end
			agg.count = agg.count + 1
		end
	end
	M._fail_seq = math.max(M._fail_seq, top)
	local macs = {}
	for mac in pairs(M._failing) do macs[#macs + 1] = mac end
	table.sort(macs)
	for _, mac in ipairs(macs) do
		local agg = M._failing[mac]
		if now - agg.at >= M.FAIL_WINDOW then
			local e = base("failure", mac, {vap = agg.vap}, agg.ts)
			e.auth_rssi = agg.signal
			e[agg.counter] = agg.count
			e.assoc_delta = agg.assoc_delta
			enqueue(e)
			M._failing[mac] = nil
		end
	end
end

-- Feed one heartbeat's snapshot; queues whatever changed since the last.
-- phases: openwrt/staphase.collect()'s {connections, failures}; nil when the
-- device cannot time connections, and then no success is claimed.
-- (A departure's cause is roam_ingest's now; observe takes no cause.)
function M.observe(stas, now, uptime, phases)
	local conns = type(phases) == "table" and phases.connections or {}
	local evs = M.diff(M._prev and M._prev.stas, stas, now, M._prev and M._prev.uptime)
	-- Only the connection timing comes from the diff: association and
	-- sta_leave are roam reports, sent from hostapd's own events
	-- (roam_ingest).
	for _, e in ipairs(evs) do
		if e.event_type == "success" then
			M._held[e.mac] = {ev = e, at = now}
		elseif e.event_type == "sta_leave" then
			M._held[e.mac] = nil
		end
	end
	local macs = {}
	for mac in pairs(M._held) do macs[#macs + 1] = mac end
	table.sort(macs)
	for _, mac in ipairs(macs) do
		local h = M._held[mac]
		if type(stas) ~= "table" or not stas[mac] then
			M._held[mac] = nil                     -- gone before it was proven
		elseif complete(h.ev, conns[mac]) then
			enqueue(h.ev)
			M._held[mac] = nil
		elseif now - h.at >= M.SUCCESS_WAIT then
			M._held[mac] = nil                     -- never verified: not claimed
		end
	end
	if type(phases) == "table" then failures(phases.failures, now) end
	M._prev = {stas = stas, uptime = uptime}
	return #evs
end

-- ─── Roam reports ────────────────────────────────────────────────────────

M.MAX_ROAMS = 32

-- mac -> {ifname, rssi, seen, fresh}: who is associated here, from hostapd's
-- events and every heartbeat's stations (roam_observe). seen = uptime of the
-- last frame heard from it, as far as known; fresh = associated, not yet
-- authorized.
M._here   = {}
-- mac -> uptime its address moved behind another AP; until it disassociates
-- here, so that disassociation is not reported again, and so the heartbeat
-- stops listing it (roamed_away).
M._roamed = {}
M._roam_queue = {}

-- The collector's hostapd roam log (openwrt/staphase.uc), one event per line:
--   <seq> <uptime> <ev> <mac> <ifname|-> <signal|-> <alg|->
-- Returns the events with seq > after, oldest first, and the highest seq. A
-- log whose seqs are all below after is a restarted collector's: read whole.
local WANTED = {assoc = true, ["sta-authorized"] = true, disassoc = true, deauth = true}
function M.parse_roam_log(text, after)
	local out, top = {}, 0
	if type(text) ~= "string" then return out, after or 0 end
	for line in text:gmatch("[^\n]+") do
		local seq = tonumber(line:match("^(%d+)%s"))
		if seq and seq > top then top = seq end
	end
	if top < (after or 0) then after = 0 end
	for line in text:gmatch("[^\n]+") do
		local seq, t, ev, rest = line:match("^(%d+)%s+(%d+%.?%d*)%s+(%S+)%s*(.*)$")
		seq = tonumber(seq)
		if seq and seq > (after or 0) then
			if WANTED[ev] then
				local mac, ifname, sig, alg = rest:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%S+)%s+(%S+)%s+(%S+)")
				if mac then
					out[#out + 1] = {seq = seq, t = tonumber(t), mac = mac:lower(),
						ev = (ev == "deauth") and "disassoc" or ev,
						ifname = ifname ~= "-" and ifname or nil,
						signal = tonumber(sig), alg = alg ~= "-" and alg or nil}
				end
			end
		end
	end
	return out, math.max(top, after or 0)
end

-- The collector's fdb log: "<uptime> fdb <bridge monitor fdb line>" per line.
-- Only a learned bridge entry is an event: "Deleted" ages out, "self" is the
-- switch's own table repeating the bridge's, "permanent" is one of the AP's
-- own addresses.
function M.parse_fdb_log(text)
	local out = {}
	if type(text) ~= "string" then return out end
	for line in text:gmatch("[^\n]+") do
		local t, rest = line:match("^(%d+%.?%d*)%s+fdb%s+(.*)$")
		local mac, port = (rest or ""):match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+dev%s+(%S+)")
		if mac and rest:find(" master ", 1, true) and not rest:find("permanent", 1, true)
			and not rest:find(" self", 1, true) then
			out[#out + 1] = {t = tonumber(t), ev = "fdb", mac = mac:lower(), port = port}
		end
	end
	return out
end

-- Both logs' events in one list, by uptime (stable: a tie keeps hostapd's
-- events first, in their own order).
function M.merge_events(a, b)
	local all = {}
	for i, e in ipairs(a or {}) do all[#all + 1] = {e = e, k = i} end
	for i, e in ipairs(b or {}) do all[#all + 1] = {e = e, k = 100000 + i} end
	table.sort(all, function(x, y)
		local tx, ty = x.e.t or 0, y.e.t or 0
		if tx ~= ty then return tx < ty end
		return x.k < y.k
	end)
	local out = {}
	for i, w in ipairs(all) do out[i] = w.e end
	return out
end

-- Has this station, which hostapd still lists, left for another AP? True from
-- its sta_roam until hostapd drops it, unless it is heard from here after the
-- move (its return was missed, or the move was not one), which lifts the
-- mark. up: uptime of the station dump; inactive_ms: the dump's inactive time.
function M.roamed_away(mac, up, inactive_ms)
	if type(mac) ~= "string" then return false end
	mac = mac:lower()
	local r = M._roamed[mac]
	if not r then return false end
	if up and up - (tonumber(inactive_ms) or 0) / 1000 > r + 1 then
		M._roamed[mac] = nil
		return false
	end
	return true
end

-- The heartbeat's stations, all of them (a roamed-away one included):
-- {mac, ifname, signal, inactive_ms}; up: uptime when they were read. Fills in
-- stations associated before the collector saw them, refreshes signal and
-- last-heard, and forgets stations that left without an event.
function M.roam_observe(stas, up)
	local here, listed = {}, {}
	for _, s in ipairs(stas or {}) do
		local mac = type(s.mac) == "string" and s.mac:lower()
		if mac then listed[mac] = true end
		if mac and s.ifname and not M.roamed_away(mac, up, s.inactive_ms) then
			local h = M._here[mac] or {}
			h.ifname = s.ifname
			h.rssi   = tonumber(s.signal) or h.rssi
			if up then h.seen = up - (tonumber(s.inactive_ms) or 0) / 1000 end
			here[mac] = h
		end
	end
	M._here = here
	for mac in pairs(M._roamed) do
		if not listed[mac] then M._roamed[mac] = nil end
	end
end

local function queue_roam(p)
	M._roam_queue[#M._roam_queue + 1] = p
	while #M._roam_queue > M.MAX_ROAMS do table.remove(M._roam_queue, 1) end
end

-- cause: optional function(mac) -> assoc_status bits, roamed (bool); what
-- openUF itself did to the client (openwrt/lockap.lua's departure_cause).
local function leave_payload(kind, mac, h, vap, last_seen, cause)
	local e = base(kind, mac, {vap = vap}, math.floor(last_seen or 0))
	-- The detector reads its own receive time; auth_ts is the funnel's.
	e.auth_ts      = nil
	e.avg_rssi     = h.rssi
	-- Whole seconds of this AP's uptime: the controller subtracts it from the
	-- uptime of this AP's last inform.
	e.last_seen    = math.floor(last_seen or 0)
	e.assoc_status = 0
	local was_roam = false
	if type(cause) == "function" then
		local ok, bits, roam = pcall(cause, mac)
		if ok and tonumber(bits) then e.assoc_status = math.floor(tonumber(bits)) end
		was_roam = ok and roam or false
	end
	return e, was_roam
end

-- Turn the collector's events into roam reports, queued for roam_take.
-- vap_by_ifname maps a BSS netdev to its vap_table name; a station on a BSS
-- without one is not reported (the controller resolves everything from the
-- vap). Returns how many were queued.
function M.roam_ingest(events, vap_by_ifname, cause)
	vap_by_ifname = vap_by_ifname or {}
	local n = 0
	local function emit(p) n = n + 1; queue_roam(p) end
	for _, e in ipairs(events or {}) do
		local h = M._here[e.mac]
		if e.ev == "assoc" then
			M._roamed[e.mac] = nil
			M._here[e.mac] = {ifname = e.ifname, rssi = e.signal, seen = e.t, fresh = true}
		elseif e.ev == "sta-authorized" then
			-- Reported once authorized, so a failed handshake is no arrival and
			-- auth_algo is known. No signal seen means no auth_rssi, and the
			-- controller drops an association without one.
			if h and h.fresh and (e.ifname == nil or h.ifname == e.ifname) then
				h.fresh = nil
				local vap = vap_by_ifname[h.ifname]
				if vap and h.rssi then
					local a = base("association", e.mac, {vap = vap}, math.floor(e.t or 0))
					a.auth_ts      = nil
					a.auth_rssi    = h.rssi
					a.auth_algo    = e.alg
					a.assoc_status = 0
					emit(a)
				end
			end
		elseif e.ev == "disassoc" then
			-- A roamed station left _here when its address moved: hostapd's
			-- late drop of it is not reported again.
			M._roamed[e.mac] = nil
			if h and (e.ifname == nil or h.ifname == e.ifname) then
				M._here[e.mac] = nil
				local vap = vap_by_ifname[h.ifname]
				-- Never authorized: a failed attempt, not a departure (the
				-- connection funnel reports it).
				if vap and h.rssi and not h.fresh then
					local l, was_roam = leave_payload("sta_leave", e.mac, h, vap, e.t, cause)
					-- Left on Roaming Assistant's BSS Transition request: a
					-- roam, which the controller counts as seamless.
					if was_roam then emit(roamed(l)) end
					emit(l)
				end
			end
			-- Otherwise the station is already on another BSS of this AP (it
			-- associated there first): a band change, not a departure.
		elseif e.ev == "fdb" then
			-- Learned on a port that is none of this AP's BSSes while hostapd
			-- still has it: it is behind another AP now. Judged only once the
			-- BSS map is known, or a move to a sibling BSS would look foreign.
			local vap = h and not h.fresh and vap_by_ifname[h.ifname]
			if vap and e.port ~= h.ifname and not vap_by_ifname[e.port] then
				M._here[e.mac] = nil
				M._roamed[e.mac] = e.t
				if h.rssi then
					emit((leave_payload("sta_roam", e.mac, h, vap, h.seen or e.t, cause)))
				end
			end
		end
	end
	return n
end

-- The next event to send, without removing it (a failed POST keeps it). Roam
-- reports go first: they are the ones a delay spoils.
function M.peek() return M._roam_queue[1] or M._queue[1] end
function M.pop()
	if M._roam_queue[1] then return table.remove(M._roam_queue, 1) end
	return table.remove(M._queue, 1)
end
function M.pending() return #M._roam_queue + #M._queue end
function M.roam_pending() return #M._roam_queue end

-- The notification inform for one event: the identity fields of the last full
-- payload plus the three notif keys.
M.IDENTITY_FIELDS = {"mac", "serial", "model", "model_display", "version", "sysid",
	"cfgversion", "hostname", "ip", "inform_url", "inform_ip", "uptime", "time",
	"default", "state", "required_version", "board_rev", "architecture"}

function M.notif_payload(identity, ev)
	local p = {}
	for _, k in ipairs(M.IDENTITY_FIELDS) do
		if type(identity) == "table" and identity[k] ~= nil then p[k] = identity[k] end
	end
	p.inform_as_notif = true
	p.notif_reason    = "event"
	p.notif_payload   = ev
	return p
end

function M._reset()
	M._prev, M._queue, M._held = nil, {}, {}
	M._fail_seq, M._failing = nil, {}
	M._here, M._roamed, M._roam_queue = {}, {}, {}
end

return M
