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

	PACKETS

	v3, unauthenticated, sent always (every openUF build since the exchange
	began understands it, so a rolling upgrade keeps every AP hearing every
	other's BSSIDs):

	"oUFs" | 0x03 (version) | identity MAC (6) |
	model length (1) | model | model_display length (1) | model_display |
	count (1) | count x (BSSID (6) | frequency MHz (2, big-endian; 0 = unknown))

	v5, authenticated, sent as well while the AP holds the site's exchange key:

	the v3 body with 0x05 for the version | lock count (1) |
	lock count x client MAC (6) | sender's clock (4, big-endian Unix time) |
	HMAC-SHA256 of everything before it, first 16 bytes

	The key is HMAC-SHA256(unifi.key, "openUF sibling exchange v5"). unifi.key
	is the site's x_mgmt_key, which the controller pushes in the system_cfg of
	every adopted device of the site while UniFi IDP is on (10.6.106
	service.config.lwueNrOWUBYJX, RPnnqSiu.wpwxm; PROTOCOL-VALIDATION.md
	"Sibling exchange authentication"). Only the derived key is kept on disk
	(KEY_FILE, mode 0600, never state.json), so a leaked file does not leak the
	site key. A v5 packet whose MAC does not verify, or whose clock is more than
	SKEW seconds from ours, is dropped whole.

	What a packet may change depends on whether it was authenticated:
	- any packet (v3, v4, v5): the BSSID -> identity MAC map that tags scan
	  entries, the models, the frequencies the sibling scans listen on;
	- an authenticated v5 packet only: the lock list (locked_here), and the
	  BSSID -> identity MAC map backhaul.lua names a wireless parent or child
	  from (decode(..., true)).
	v4 (a lock list without authentication, from builds before v5) is still
	parsed for its BSSIDs; its lock list is ignored.

	The store holds at most MAX_STORE BSSIDs; a new BSSID past that is dropped
	until entries expire, so a flood of forged senders cannot grow the file
	without bound.

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
-- The authenticated version; COMPAT the one every build understands.
M.VERSION   = 5
M.COMPAT    = 3
M.MAX_BSSID = 32
-- 32 BSSIDs and two 64-byte names leave ~1000 bytes of a 1500-byte frame,
-- less the 20-byte clock + MAC trailer.
M.MAX_LOCKS = 150
-- At most this many BSSIDs are kept from all siblings together.
M.MAX_STORE = 1024
-- The derived exchange key (hex), written by provisioning, read by announce.
M.KEY_FILE  = "/etc/openuf/sibling.key"
M.KEY_LABEL = "openUF sibling exchange v5"
M.TAG_LEN   = 16
-- How far a v5 packet's clock may be from ours, either way.
M.SKEW      = 600
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

local function short(s)
	s = type(s) == "string" and s:gsub("[^ -~]", "") or ""
	return s:sub(1, 64)
end

local function crypto() return require("unifi.crypto") end

local function u32(n)
	n = math.floor(n) % 4294967296
	return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
		math.floor(n / 256) % 256, n % 256)
end

-- The exchange key (64 hex chars) derived from the site's unifi.key (32 hex
-- chars), or nil for anything else.
function M.derive_key(site_key)
	if type(site_key) ~= "string" or #site_key ~= 32 or not site_key:match("^%x+$") then
		return nil
	end
	local c = crypto()
	return c.bin_to_hex(c.hmac_sha256(c.hex_to_bin(site_key:lower()), M.KEY_LABEL))
end

local function valid_key(key)
	return type(key) == "string" and #key == 64 and key:match("^%x+$") ~= nil
end

local function tag(key, data)
	local c = crypto()
	return c.hmac_sha256(c.hex_to_bin(key:lower()), data):sub(1, M.TAG_LEN)
end

-- The packets announcing mac's BSSIDs: the v3 packet, and with a valid key
-- the v5 packet carrying locks; nil when mac is not a MAC. A third value is
-- true when the lock list was cut at MAX_LOCKS.
-- bssids: {{bssid = "xx:..", freq = MHz or nil}, ...}. Malformed BSSIDs are
-- left out; at most M.MAX_BSSID go in.
-- info: {model = "U6IW", model_display = "U6-IW"} (optional).
function M.build(mac, bssids, info, locks, key, now)
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
	local body = m .. string.char(#model) .. model .. string.char(#display) .. display
		.. string.char(#list) .. table.concat(list)
	local v3 = M.MAGIC .. string.char(M.COMPAT) .. body
	if not valid_key(key) then return v3, nil, false end
	local lk, cut = {}, false
	for _, c in ipairs(locks or {}) do
		local cb = mac_bytes(type(c) == "string" and c:lower() or nil)
		if cb then
			if #lk < M.MAX_LOCKS then lk[#lk + 1] = cb else cut = true end
		end
	end
	local v5 = M.MAGIC .. string.char(M.VERSION) .. body
		.. string.char(#lk) .. table.concat(lk) .. u32(now or os.time())
	return v3, v5 .. tag(key, v5), cut
end

-- mac, {{bssid, freq}, ...}, {model, model_display}, {lock MAC, ...},
-- authenticated from a packet. nil plus a reason for anything else:
-- "version N" (right magic, a version this build does not know),
-- "unauthenticated" (a v5 packet that does not verify under key, or arrives
-- with no key here), "clock" (verified, but its clock is off by more than
-- SKEW), "malformed".
function M.parse(data, key, now)
	if type(data) ~= "string" or #data < 14 or data:sub(1, 4) ~= M.MAGIC then
		return nil, "malformed"
	end
	local version = data:byte(5)
	if version ~= 3 and version ~= 4 and version ~= 5 then
		return nil, "version " .. version
	end
	local authed = false
	if version == 5 then
		if #data < 14 + 4 + M.TAG_LEN then return nil, "malformed" end
		local signed = data:sub(1, #data - M.TAG_LEN)
		if not valid_key(key) or tag(key, signed) ~= data:sub(#data - M.TAG_LEN + 1) then
			return nil, "unauthenticated"
		end
		local t = signed:sub(-4)
		local ts = ((t:byte(1) * 256 + t:byte(2)) * 256 + t:byte(3)) * 256 + t:byte(4)
		if math.abs((now or os.time()) - ts) > M.SKEW then return nil, "clock" end
		data = signed:sub(1, #signed - 4)
		authed = true
	end
	local p = 12
	local ml = data:byte(p)
	local model = data:sub(p + 1, p + ml)
	p = p + 1 + ml
	if p > #data then return nil, "malformed" end
	local dl = data:byte(p)
	local display = data:sub(p + 1, p + dl)
	p = p + 1 + dl
	if p > #data then return nil, "malformed" end
	local n = data:byte(p)
	local locks = {}
	if version == 3 then
		if #data ~= p + 8 * n then return nil, "malformed" end
	else
		local q = p + 8 * n + 1
		if q > #data then return nil, "malformed" end
		local nl = data:byte(q)
		if #data ~= q + 6 * nl then return nil, "malformed" end
		-- v4's list is unauthenticated: parsed for the shape, never used.
		if authed then
			for k = 0, nl - 1 do locks[#locks + 1] = mac_string(data, q + 1 + 6 * k) end
		end
	end
	local bssids = {}
	for k = 0, n - 1 do
		local at = p + 1 + 8 * k
		local f = data:byte(at + 6) * 256 + data:byte(at + 7)
		bssids[#bssids + 1] = {bssid = mac_string(data, at), freq = f > 0 and f or nil}
	end
	return mac_string(data, 6), bssids,
		{model = model ~= "" and model or nil, model_display = display ~= "" and display or nil},
		locks, authed
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

-- Fold one received packet into store ({bssid = entry}). A packet from
-- self_mac is our own broadcast coming back, and is ignored. Returns true
-- when the packet was a sibling's; otherwise false and parse's reason (nil
-- for our own). A second value "full" says a new BSSID was dropped because
-- the store holds MAX_STORE already.
--
-- Entry: {mac, seen, freq, model, model_display} from any packet;
-- {amac, auth, locks} only from an authenticated one, which an
-- unauthenticated packet never overwrites: amac is the identity an
-- authenticated sibling claimed the BSSID under, auth when.
function M.record(store, data, self_mac, now, key)
	local mac, bssids, info, locks, authed = M.parse(data, key, now)
	if not mac then return false, bssids end
	if mac == (self_mac or ""):lower() then return false end
	local count, full = nil, nil
	for _, b in ipairs(bssids) do
		local e = store[b.bssid]
		if not e then
			if count == nil then
				count = 0
				for _ in pairs(store) do count = count + 1 end
			end
			if count >= M.MAX_STORE then
				full = "full"
			else
				count = count + 1
				e = {}
				store[b.bssid] = e
			end
		end
		if e then
			e.mac, e.seen, e.freq = mac, now, b.freq
			e.model, e.model_display = info.model, info.model_display
			if authed then
				-- The lock list rides on each of the sender's BSSID entries,
				-- so it ages out with them; nil rather than {} keeps the
				-- file's arrays unambiguous.
				e.amac, e.auth = mac, now
				e.locks = #locks > 0 and locks or nil
			end
		end
	end
	return true, full
end

-- An entry an authenticated packet vouched for within the TTL.
local function authed_fresh(e, now)
	return type(e.auth) == "number" and now - e.auth <= M.TTL and type(e.amac) == "string"
end

-- Drop what has not been heard for M.TTL. Returns store.
function M.expire(store, now)
	for b, e in pairs(store) do
		if now - (e.seen or 0) > M.TTL then store[b] = nil end
	end
	return store
end

-- {bssid = sibling identity MAC} from the file's text, fresh entries only.
-- authed_only: only what an authenticated packet vouched for, under the
-- identity it claimed (backhaul attribution).
function M.decode(text, now, cjson, authed_only)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for b, e in pairs(t) do
		if type(b) == "string" and type(e) == "table" then
			if authed_only then
				if authed_fresh(e, now) then out[b:lower()] = e.amac:lower() end
			elseif type(e.mac) == "string" and type(e.seen) == "number"
					and now - e.seen <= M.TTL then
				out[b:lower()] = e.mac:lower()
			end
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

-- The clients some authenticated sibling denies for Lock to Access Point, as
-- a set.
function M.decode_locks(text, now, cjson)
	local ok, t = pcall(cjson.decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for _, e in pairs(t) do
		if type(e) == "table" and authed_fresh(e, now) and type(e.locks) == "table" then
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

-- The exchange key from KEY_FILE, or nil.
function M.read_key(path)
	local f = io.open(path or M.KEY_FILE, "r")
	if not f then return nil end
	local k = (f:read("*a") or ""):match("^%s*(%x+)%s*$")
	f:close()
	return valid_key(k) and k:lower() or nil
end

-- Keep the key derived from a pushed unifi.key in path, readable by root
-- only; site_key nil removes it. Writes only on a change, as the file is on
-- flash. Returns "written", "removed" or nil (unchanged), plus an error.
function M.store_key(site_key, path, run)
	path = path or M.KEY_FILE
	run = run or os.execute
	local key = site_key and M.derive_key(site_key) or nil
	local have = M.read_key(path)
	if key == have then return nil end
	if not key then
		os.remove(path)
		return "removed"
	end
	local tmp = path .. ".tmp"
	os.remove(tmp)
	local f = io.open(tmp, "w")
	if not f then return nil, "cannot write " .. tmp end
	f:close()
	-- 0600 before the key goes in, so it is never readable by anyone else.
	local rc = run("chmod 600 '" .. tmp .. "'")
	if rc ~= 0 and rc ~= true then
		os.remove(tmp)
		return nil, "cannot chmod " .. tmp
	end
	f = io.open(tmp, "w")
	local ok = f and f:write(key .. "\n")
	local closed = f and f:close()
	if not (ok and closed and os.rename(tmp, path)) then
		os.remove(tmp)
		return nil, "cannot write " .. path
	end
	return "written"
end

-- Write store to path through a temporary file, so a reader never sees half
-- of it.
function M.save(store, path, cjson)
	path = path or M.FILE
	local f = io.open(path .. ".tmp", "w")
	if not f then return false end
	f:write(cjson.encode(store))
	f:close()
	return os.rename(path .. ".tmp", path) and true or false
end

return M
