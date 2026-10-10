--[[
	Sibling openUF APs telling each other their BSSIDs.

	WHY THIS EXISTS

	The controller lists a UniFi AP's neighbouring APs (WiFiman's nearest
	neighbours, the topology's AP-to-AP signal) from the AP's scan entries
	tagged is_unifi + serialno: 10.6.106's scan ingest (com.ubnt.service.aS
	.qikih) accepts such an entry up to inform.interval + 10 s old and keeps
	it for an hour (the "peer-scan-cache", expireAfterWrite 3600 s).

	openUF tags an entry from the vendor element siblings beacon
	(sysinfo.peer_ie_hex), which only a scanned beacon or probe response
	carries. The other source of neighbours, a client's 802.11k beacon report
	(rrmscan.lua), carries a BSSID and a signal and nothing else, so a
	sibling it reports could not be told from a stranger. Siblings are on
	different channels by design, so the passive cache hardly ever holds one.

	So every openUF AP broadcasts its identity MAC and its BSSIDs on the LAN,
	and keeps what its siblings broadcast. report.lua then tags any scan entry
	whose BSSID belongs to a sibling. Its own UDP port, not Ubiquiti's
	discovery port 10001: UniFi Core parses everything that arrives there.

	Each BSSID goes with its frequency, so a sibling can be listened for on
	its own channel (idlescan.lua) instead of in a full off-channel sweep.

	PACKET

	"oUFs" | 0x04 (version) | identity MAC (6) |
	model length (1) | model | model_display length (1) | model_display |
	count (1) | count x (BSSID (6) | frequency MHz (2, big-endian; 0 = unknown)) |
	lock count (1) | lock count x client MAC (6)

	Version 3 is the same without the lock list, and is still accepted.

	The model pair is the identity the sender presents (U6IW / U6-IW). The
	controller copies `model` and `model_display` from the reporting AP's scan
	entry into its AP-to-AP sighting (10.6.106 aS.LUdHVFmmB), which is where
	WiFiman's neighbour list takes the name from; a real UniFi AP reads them
	from its neighbour's Ubiquiti element.

	The lock list is the sender's st.lock2ap: the clients the controller
	denies on it because of "Lock to Access Point" (PROTOCOL-VALIDATION.md,
	#lock-to-access-point-lock2ap). The controller sends a lock to every AP
	except the client's own, so the AP a client is locked to never hears of
	it from the controller. It reads it here instead: a MAC its siblings deny
	and it does not is locked to it (locked_here), and openUF stops steering
	that client away (usteer.set_locked, roamassist).
]]--

local M = {}

M.PORT      = 10011
M.MAGIC     = "oUFs"
M.VERSION   = 4
M.MAX_BSSID = 32
-- 32 BSSIDs and two 64-byte names leave ~1000 bytes of a 1500-byte frame.
M.MAX_LOCKS = 150
-- Where announce.lua leaves the table for the inform loop.
M.FILE      = "/tmp/openuf-siblings.json"
-- A sibling not heard for this long is forgotten. Thirty broadcasts.
M.TTL       = 300

local function mac_bytes(s)
	if type(s) ~= "string" or not s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return nil
	end
	local out = {}
	for h in s:gmatch("%x%x") do out[#out + 1] = string.char(tonumber(h, 16)) end
	return table.concat(out)
end

local function mac_string(b, i)
	local parts = {}
	for k = i, i + 5 do parts[#parts + 1] = string.format("%02x", b:byte(k)) end
	return table.concat(parts, ":")
end

-- The packet announcing mac's BSSIDs, or nil when mac is not a MAC.
-- bssids: {{bssid = "xx:..", freq = MHz or nil}, ...}. Malformed BSSIDs are
-- left out; at most M.MAX_BSSID go in.
local function short(s)
	s = type(s) == "string" and s:gsub("[^ -~]", "") or ""
	return s:sub(1, 64)
end

-- info: {model = "U6IW", model_display = "U6-IW"} (optional).
function M.build(mac, bssids, info, locks)
	local m = mac_bytes(mac and mac:lower())
	if not m then return nil end
	local model, display = short(info and info.model), short(info and info.model_display)
	local list = {}
	for _, b in ipairs(bssids or {}) do
		local bb = type(b) == "table" and mac_bytes(type(b.bssid) == "string"
			and b.bssid:lower() or nil)
		if bb and #list < M.MAX_BSSID then
			local f = math.floor(tonumber(b.freq) or 0)
			if f < 0 or f > 65535 then f = 0 end
			list[#list + 1] = bb .. string.char(math.floor(f / 256), f % 256)
		end
	end
	local lk = {}
	for _, c in ipairs(locks or {}) do
		local cb = mac_bytes(type(c) == "string" and c:lower() or nil)
		if cb and #lk < M.MAX_LOCKS then lk[#lk + 1] = cb end
	end
	return M.MAGIC .. string.char(M.VERSION) .. m
		.. string.char(#model) .. model .. string.char(#display) .. display
		.. string.char(#list) .. table.concat(list)
		.. string.char(#lk) .. table.concat(lk)
end

-- mac, {{bssid, freq}, ...}, {model, model_display} from a packet, or nil
-- for anything else (another version included: every AP runs the same build).
function M.parse(data)
	if type(data) ~= "string" or #data < 14 then return nil end
	local version = data:byte(5)
	if data:sub(1, 4) ~= M.MAGIC or (version ~= 3 and version ~= 4) then return nil end
	local p = 12
	local ml = data:byte(p)
	local model = data:sub(p + 1, p + ml)
	p = p + 1 + ml
	if p > #data then return nil end
	local dl = data:byte(p)
	local display = data:sub(p + 1, p + dl)
	p = p + 1 + dl
	if p > #data then return nil end
	local n = data:byte(p)
	local locks = {}
	if version == 3 then
		if #data ~= p + 8 * n then return nil end
	else
		local q = p + 8 * n + 1
		if q > #data then return nil end
		local nl = data:byte(q)
		if #data ~= q + 6 * nl then return nil end
		for k = 0, nl - 1 do locks[#locks + 1] = mac_string(data, q + 1 + 6 * k) end
	end
	local bssids = {}
	for k = 0, n - 1 do
		local at = p + 1 + 8 * k
		local f = data:byte(at + 6) * 256 + data:byte(at + 7)
		bssids[#bssids + 1] = {bssid = mac_string(data, at), freq = f > 0 and f or nil}
	end
	return mac_string(data, 6), bssids,
		{model = model ~= "" and model or nil, model_display = display ~= "" and display or nil},
		locks
end

-- This device's AP interfaces from `iw dev` output:
-- {{bssid = addr, freq = MHz or nil}, ...}.
function M.own_bssids(iw_dev)
	local out, addr, freq = {}, nil, nil
	for line in (iw_dev or ""):gmatch("[^\n]+") do
		if line:match("^%s*Interface ") or line:match("^phy#") then
			addr, freq = nil, nil
		else
			local a = line:match("^%s*addr (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
			if a then addr = a:lower() end
			local f = line:match("^%s*channel %d+ %((%d+) MHz%)")
			if f then
				freq = tonumber(f)
				-- iw prints the channel after the type; fill in the entry
				-- already taken for this interface.
				if out[#out] and out[#out].bssid == addr then out[#out].freq = freq end
			end
			if line:match("^%s*type AP%s*$") and addr then
				out[#out + 1] = {bssid = addr, freq = freq}
			end
		end
	end
	return out
end

-- Fold one received packet into store ({bssid = {mac, seen}}). A packet
-- from self_mac is our own broadcast coming back, and is ignored.
function M.record(store, data, self_mac, now)
	local mac, bssids, info, locks = M.parse(data)
	if not mac or mac == (self_mac or ""):lower() then return false end
	-- The lock list rides on each of the sender's BSSID entries, so it ages
	-- out with them; nil rather than {} keeps the file's arrays unambiguous.
	for _, b in ipairs(bssids) do
		store[b.bssid] = {mac = mac, seen = now, freq = b.freq,
			model = info.model, model_display = info.model_display,
			locks = #locks > 0 and locks or nil}
	end
	return true
end

-- Drop what has not been heard for M.TTL. Returns store.
function M.expire(store, now)
	for b, e in pairs(store) do
		if now - (e.seen or 0) > M.TTL then store[b] = nil end
	end
	return store
end

-- {bssid = sibling identity MAC} from the file's text, fresh entries only.
function M.decode(text, now, cjson)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for b, e in pairs(t) do
		if type(b) == "string" and type(e) == "table" and type(e.mac) == "string"
			and type(e.seen) == "number" and now - e.seen <= M.TTL then
			out[b:lower()] = e.mac:lower()
		end
	end
	return out
end

-- {identity MAC = {model, model_display}} of fresh siblings.
function M.decode_models(text, now, cjson)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for _, e in pairs(t) do
		if type(e) == "table" and type(e.mac) == "string" and type(e.seen) == "number"
			and now - e.seen <= M.TTL and (e.model or e.model_display) then
			out[e.mac:lower()] = {model = e.model, model_display = e.model_display}
		end
	end
	return out
end

-- The distinct frequencies fresh siblings beacon on, from the file's text.
function M.decode_freqs(text, now, cjson)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local seen, out = {}, {}
	for _, e in pairs(t) do
		local f = type(e) == "table" and tonumber(e.freq)
		if f and type(e.seen) == "number" and now - e.seen <= M.TTL and not seen[f] then
			seen[f] = true
			out[#out + 1] = f
		end
	end
	table.sort(out)
	return out
end

-- Write store to path through a temporary file, so a reader never sees half
-- of it.
-- The clients some fresh sibling denies for Lock to Access Point, as a set.
function M.decode_locks(text, now, cjson)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for _, e in pairs(t) do
		if type(e) == "table" and type(e.seen) == "number" and now - e.seen <= M.TTL
			and type(e.locks) == "table" then
			for _, c in ipairs(e.locks) do
				if type(c) == "string" then out[c:lower()] = true end
			end
		end
	end
	return out
end

-- The clients locked to THIS AP: denied by a sibling (sibling_locks, from
-- decode_locks) and not denied here (own, st.lock2ap). Sorted.
function M.locked_here(sibling_locks, own)
	local mine = {}
	for _, c in ipairs(own or {}) do mine[c:lower()] = true end
	local out = {}
	for c in pairs(sibling_locks or {}) do
		if not mine[c] then out[#out + 1] = c end
	end
	table.sort(out)
	return out
end

function M.save(store, path, cjson)
	path = path or M.FILE
	local f = io.open(path .. ".tmp", "w")
	if not f then return false end
	f:write(cjson.encode(store))
	f:close()
	return os.rename(path .. ".tmp", path) and true or false
end

return M
