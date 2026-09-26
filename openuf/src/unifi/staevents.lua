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

	A roam is the controller pairing one AP's sta_leave with another AP's
	association for the same client, so nothing here has to know about the
	other APs. Every event names the VAP by vap_table `name` -- the controller
	drops one whose VAP it cannot find.

	Associations and departures come from diffing the station list between
	heartbeats, with iw's "connected time" dating each association.

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
	return e
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
function M.observe(stas, now, uptime, phases)
	local conns = type(phases) == "table" and phases.connections or {}
	local evs = M.diff(M._prev and M._prev.stas, stas, now, M._prev and M._prev.uptime)
	for _, e in ipairs(evs) do
		if e.event_type == "success" then
			M._held[e.mac] = {ev = e, at = now}
		else
			if e.event_type == "sta_leave" then M._held[e.mac] = nil end
			enqueue(e)
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

-- The next event to send, without removing it (a failed POST keeps it).
function M.peek() return M._queue[1] end
function M.pop() return table.remove(M._queue, 1) end
function M.pending() return #M._queue end

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
end

return M
