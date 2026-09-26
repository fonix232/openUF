--[[
	Client connection events: the controller's STA_ASSOC_TRACKER notifications.

	A UniFi AP does not leave client history to the periodic sta_table. Every
	association, successful connection and departure is reported as a separate
	NOTIFICATION inform -- `inform_as_notif: true`, `notif_reason: "event"` and a
	`notif_payload` whose `message_type` is STA_ASSOC_TRACKER. The controller
	(10.6.106, devmgr.w.a) dispatches on `event_type`:

	  association   the roaming detector records where the client joined
	                (needs auth_rssi, or it is ignored)
	  success       WiFi-connectivity statistics and the connection timeline
	  sta_leave     the disconnect time (from last_seen, in device-uptime
	                seconds) and the roaming detector's "left" half

	A roam is the controller pairing one AP's sta_leave with another AP's
	association for the same client, so nothing here has to know about the
	other APs. Every event names the VAP by vap_table `name` -- the controller
	drops one whose VAP it cannot find.

	Source: the station list openUF already builds every heartbeat. Diffing it
	against the previous heartbeat's, with iw's "connected time" dating each
	association, needs no extra process and no hostapd subscription (whose
	notification stream is dominated by probe requests). Resolution is one
	heartbeat for departures; associations are dated exactly.

	The controller stores a `success` only when the device saw the client get a
	DNS answer (dns_resp_seen "yes"); an unverified one is held and dropped. So
	`success` waits until dnswatch.lua has seen a DNS answer go to the client
	(then "yes"), or SUCCESS_WAIT seconds (then "N/A", honestly unverified).
	Not claimed at all: ARP/DHCP observations, per-phase latencies, failure
	counts.
]]--

local M = {}

M.MESSAGE_TYPE = "STA_ASSOC_TRACKER"
-- Bounds: a `wifi reload` drops and re-adds every client at once, and a
-- controller that is down must not turn the queue into a memory leak.
M.MAX_QUEUE    = 200
M.MAX_PER_TICK = 8
-- How long a join's `success` waits for a DNS answer to be seen.
M.SUCCESS_WAIT = 60

M._prev  = nil    -- {uptime = n, stas = {mac -> {vap, signal, uptime, idle}}}
M._queue = {}
M._held  = {}     -- mac -> {ev = success event, at = when it was held}

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

-- Feed one heartbeat's snapshot; queues whatever changed since the last.
-- dns_seen: {mac -> true} for clients a DNS answer was seen going to
-- (dnswatch.seen); nil when that is unavailable.
function M.observe(stas, now, uptime, dns_seen)
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
		elseif dns_seen and dns_seen[mac] then
			h.ev.dns_resp_seen = "yes"
			enqueue(h.ev)
			M._held[mac] = nil
		elseif now - h.at >= M.SUCCESS_WAIT then
			enqueue(h.ev)                          -- stays "N/A"
			M._held[mac] = nil
		end
	end
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
end

return M
