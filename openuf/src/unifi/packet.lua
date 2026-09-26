--[[
	packet.lua -- the TNBU inform packet ("UBNT" reversed): framing,
	AES-128-CBC/GCM and compression.

	  Offset  Len  Field
	   0       4   Magic: 0x54 0x4E 0x42 0x55 ("TNBU")
	   4       4   Packet version (uint32 BE) -- the controller ignores it; openUF sends 1
	   8       6   Device MAC
	  14       2   Flags (uint16 BE):
	               0x01 = payload encrypted (AES-128-CBC or GCM)
	               0x02 = payload zlib-compressed
	               0x04 = payload snappy-compressed
	               0x08 = use AES-128-GCM instead of CBC (requires 0x01)
	  16      16   AES IV
	  32       4   Data version (uint32 BE) -- always 1 (= JSON payload)
	  36       4   Payload length (uint32 BE)
	  40+      *   Payload (may be compressed then encrypted)
]]--

local bit = (function()
	local ok, b = pcall(require, "bit")
	if ok then return b end
	ok, b = pcall(require, "bit32")
	if ok then return b end
	local _l = load or loadstring
	local function _f(e) return _l("return function(a,b) return "..e.." end")() end
	return {
		band   = _f("a&b"),
		bor    = _l("return function(...) local r=0 for i=1,select('#',...)do r=r|select(i,...)end return r end")(),
		bxor   = _f("a~b"),
		lshift = _f("a<<b"),
		rshift = _f("a>>b"),
	}
end)()

local M = {}

-- Packet constants
local MAGIC        = "TNBU"
local PKT_VERSION  = 1   -- confirmed by amd989/unifi-gateway and fxkr reverse-engineering
local DATA_VERSION = 1

-- Inform flags
local FLAG_ENCRYPTED  = 0x01
local FLAG_COMPRESSED = 0x02
local FLAG_SNAPPY     = 0x04  -- Snappy compression (amd989 prefers it; we send zlib only)
local FLAG_GCM        = 0x08

-- ─── Binary helpers ───────────────────────────────────────────────────────────

local function uint32_be(n)
	return string.char(
		bit.band(bit.rshift(n, 24), 0xFF),
		bit.band(bit.rshift(n, 16), 0xFF),
		bit.band(bit.rshift(n,  8), 0xFF),
		bit.band(n,                 0xFF)
	)
end

local function uint16_be(n)
	return string.char(
		bit.band(bit.rshift(n, 8), 0xFF),
		bit.band(n,                0xFF)
	)
end

local function parse_uint32_be(s, offset)
	local b1, b2, b3, b4 = string.byte(s, offset, offset + 3)
	return bit.bor(
		bit.lshift(b1 or 0, 24),
		bit.lshift(b2 or 0, 16),
		bit.lshift(b3 or 0,  8),
		          (b4 or 0)
	)
end

local function parse_uint16_be(s, offset)
	local hi, lo = string.byte(s, offset, offset + 1)
	return (hi or 0) * 256 + (lo or 0)
end

local function mac_bytes(mac_str)
	-- "aa:bb:cc:dd:ee:ff" → 6-byte binary string
	local bytes = {}
	for h in mac_str:gmatch("[0-9a-fA-F]+") do
		bytes[#bytes + 1] = string.char(tonumber(h, 16))
	end
	if #bytes ~= 6 then error("mac_bytes: invalid MAC: " .. tostring(mac_str)) end
	return table.concat(bytes)
end

-- 32 hex chars = 16 bytes = a valid AES-128 key (matches syswrapper.lua's check)
function M.is_hex32(s)
	return type(s) == "string" and #s == 32 and s:match("^[0-9a-fA-F]+$") ~= nil
end

-- Exactly "aa:bb:cc:dd:ee:ff". Wire-supplied MACs -- the MAC filter's ACL, the
-- Multicast/Broadcast Blocker's allow-list -- end up inside nft and
-- hostapd_cli command lines (bcfilter.lua, firewall.lua) or in UCI lists
-- hostapd parses, so anything not of this shape is refused at the boundary
-- rather than escaped. The controller is authenticated once adopted, but
-- before that the inform channel is plain HTTP under the well-known default
-- key and a forged setparam is within reach of anyone on the path; this is
-- what keeps that from becoming a shell.
function M.is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- ─── Packet builder ──────────────────────────────────────────────────────────

-- Build a TNBU binary packet from a JSON string.
-- st: state table (authkey, mac, use_gcm); crypto: the backend (unifi.crypto)
-- GCM AAD = first 40 bytes of the packet header (per amd989/unifi-gateway encode_inform)
function M.build(json_str, st, crypto)
	crypto = crypto or require("unifi.crypto")
	local use_gcm = st.use_gcm and crypto.gcm_available()
	local payload = json_str

	-- Compress with zlib if available
	local flags = FLAG_ENCRYPTED
	local ok_zlib, zlib = pcall(require, "zlib")
	if ok_zlib and zlib.compress then
		local compressed = zlib.compress(payload)
		if compressed and #compressed < #payload then
			payload = compressed
			flags = bit.bor(flags, FLAG_COMPRESSED)
		end
	end
	if use_gcm then flags = bit.bor(flags, FLAG_GCM) end

	local iv      = crypto.random_iv(16)
	local mac_bin = mac_bytes(st.mac or "00:00:00:00:00:00")

	-- 36-byte fixed prefix (before payload_len field)
	local prefix = MAGIC
		.. uint32_be(PKT_VERSION)
		.. mac_bin
		.. uint16_be(flags)
		.. iv
		.. uint32_be(DATA_VERSION)

	local ciphertext
	if use_gcm then
		-- GCM: payload len = compressed len + 16-byte tag; assemble full 40-byte AAD first
		local aad = prefix .. uint32_be(#payload + 16)
		local ct, tag = crypto.aes_gcm_encrypt(st.authkey, iv, payload, aad)
		ciphertext = ct .. tag
		return aad .. ciphertext
	else
		ciphertext = crypto.aes_cbc_encrypt(st.authkey, iv, payload)
		return prefix .. uint32_be(#ciphertext) .. ciphertext
	end
end

-- ─── Packet parser ───────────────────────────────────────────────────────────

-- Parse and decrypt a TNBU binary packet.
-- Returns json_str, flags.  Raises on magic mismatch or decryption failure.
function M.parse(raw, st, crypto)
	crypto = crypto or require("unifi.crypto")
	if #raw < 40 then
		error("inform: packet too short (" .. #raw .. " bytes)")
	end

	local magic = raw:sub(1, 4)
	if magic ~= MAGIC then
		error("inform: bad magic: " .. magic:gsub(".", function(c)
			return string.format("\\x%02x", string.byte(c))
		end))
	end

	-- pkt_version = parse_uint32_be(raw, 5)  -- currently unused
	-- mac         = raw:sub(9, 14)            -- currently unused
	local flags      = parse_uint16_be(raw, 15)
	local iv         = raw:sub(17, 32)
	-- data_version = parse_uint32_be(raw, 33) -- currently unused
	local payload_len = parse_uint32_be(raw, 37)
	local payload     = raw:sub(41, 40 + payload_len)

	if #payload < payload_len then
		error("inform: truncated payload")
	end

	-- Decrypt
	if bit.band(flags, FLAG_ENCRYPTED) ~= 0 then
		local key = st.authkey
		if bit.band(flags, FLAG_GCM) ~= 0 then
			-- AAD = full 40-byte packet header (per amd989/unifi-gateway decode_inform)
			local aad = raw:sub(1, 40)
			local ct  = payload:sub(1, #payload - 16)
			local tag = payload:sub(#payload - 15)
			payload = crypto.aes_gcm_decrypt(key, iv, ct, tag, aad)
		else
			payload = crypto.aes_cbc_decrypt(key, iv, payload)
		end
	end

	-- Decompress — Snappy (0x04) is not supported; zlib (0x02) is.
	if bit.band(flags, FLAG_SNAPPY) ~= 0 then
		error("inform: controller sent snappy-compressed response; lua-snappy not supported")
	end
	if bit.band(flags, FLAG_COMPRESSED) ~= 0 then
		local done = false
		-- Prefer a native zlib binding if the host happens to have one...
		local ok_zlib, zlib = pcall(require, "zlib")
		if ok_zlib and type(zlib) == "table" and zlib.decompress then
			local ok_d, out = pcall(zlib.decompress, payload)
			if ok_d and out then payload = out; done = true end
		end
		-- ...otherwise fall back to the in-tree pure-Lua inflater (OpenWrt 25.12
		-- ships no Lua zlib binding, so this is the normal path there).
		if not done then
			local inflate = require("unifi.inflate")
			payload = inflate.zlib_decompress(payload)
		end
	end

	return payload, flags
end

return M
