--[[
	Lock to Access Point on the AP a client is locked TO, and what openUF
	itself did to clients that leave.

	The controller enforces a lock by denying the client on every other AP;
	the AP it is locked to hears nothing (PROTOCOL-VALIDATION.md,
	#lock-to-access-point-lock2ap). Its siblings announce whom they deny
	(openwrt/siblings.lua, authenticated packets only), and a client they deny
	and this AP does not is locked here (siblings.locked_here). Such a client
	is exempted from usteer's steering (usteer.set_locked), from Roaming
	Assistant and from Minimum RSSI (report.lua, is_locked).

	The same module keeps the departure-cause ledger: a Minimum RSSI kick is
	noted (note_kick) and reported once in the client's departure event as
	assoc_status 16; a Roaming Assistant action comes from roamassist.lua
	(departure_cause).

	State is in memory: the exemptions are rebuilt from the sibling file at
	most once a minute (INTERVAL) or at once after request(), and acted on
	only when they changed.
]]--

local M = {}

M.INTERVAL     = 60     -- s between rebuilds of the exemptions
M.STEER_WINDOW = 120    -- s a kick or an action stays a departure's cause
M.KICKS_MAX    = 256    -- kick ledger entries kept, whatever reads them

M._time = os.time
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

M._next  = 0      -- earliest time of the next rebuild
M._built = nil    -- the exemption list last acted on, joined
M.here   = {}     -- clients locked to this AP: a set of lowercase MACs
M.kicks  = {}     -- mac -> time of openUF's last Minimum RSSI kick

-- Forget everything (a test, or a reset).
function M.reset()
	M._next, M._built, M.here, M.kicks = 0, nil, {}, {}
end

-- Rebuild at the next resync, whatever the clock says (a push changed this
-- AP's own lock list).
function M.request()
	M._next = 0
end

function M.is_locked(mac)
	return type(mac) == "string" and M.here[mac:lower()] == true
end

-- Rebuild the exemptions: own is this AP's own deny list (st.lock2ap), usteer
-- the module told about a change (set_locked), siblings the sibling module.
-- Rate-limited to INTERVAL; acts only on a change. Returns true when it did.
function M.resync(own, usteer, siblings)
	local now = M._time()
	if now < M._next then return false end
	M._next = now + M.INTERVAL
	local sib = siblings or require("openwrt.siblings")
	local here = sib.locked_here(sib.decode_locks(M._read_file(sib.FILE), now,
		require("cjson")), own)
	local key = table.concat(here, " ")
	if key == M._built then return false end
	local set = {}
	for _, m in ipairs(here) do set[m] = true end
	M.here = set
	if usteer and usteer.set_locked then usteer.set_locked(here) end
	if #here > 0 or M._built then
		io.stderr:write("openuf: locked to this AP: " .. (#here > 0 and key or "none") .. "\n")
	end
	M._built = key
	return true
end

-- Drop kicks older than STEER_WINDOW, and everything past KICKS_MAX, so the
-- ledger stays small with connection events off, when nothing reads it.
function M.prune(now)
	local n = 0
	for m, t in pairs(M.kicks) do
		if now - t > M.STEER_WINDOW then M.kicks[m] = nil else n = n + 1 end
	end
	if n > M.KICKS_MAX then M.kicks = {} end
end

-- openUF's Minimum RSSI just deauthenticated mac.
function M.note_kick(mac, now)
	M.kicks[mac] = now
	M.prune(now)
end

-- What openUF itself did to a client that has just left, as the controller's
-- assoc_status bits and whether it was a roam: a Minimum RSSI kick (16) or a
-- Roaming Assistant action (8192) within STEER_WINDOW seconds; a client that
-- left on a BSS Transition request and is seen on another AP is a roam. Each
-- kick is reported once. staevents: the bit values; roamassist: optional.
function M.departure_cause(mac, now, staevents, roamassist)
	local bits, roam = 0, false
	local kicked = M.kicks[mac]
	if kicked then
		M.kicks[mac] = nil
		if now - kicked <= M.STEER_WINDOW then bits = bits + staevents.KICKED_DUE_TO_MIN_RSSI end
	end
	M.prune(now)
	local ra = roamassist and roamassist.departure_cause
		and roamassist.departure_cause(mac, now, M.STEER_WINDOW)
	if ra then
		bits = bits + staevents.MOVED_DUE_TO_ROAMING_ASSISTANT
		roam = (ra == "btm")
	end
	return bits, roam
end

return M
