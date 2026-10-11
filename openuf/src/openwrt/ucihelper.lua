--[[
	UCI helper for WiFi provisioning.

	Manages SSID sections named with the "openuf_" prefix so that user-created
	SSIDs are never touched.  The controller pushes config via the inform
	response dispatcher (inform.handle_response → apply_config).

	Requires: uci (Lua UCI bindings, standard on OpenWrt)
]]--

local schedule_mod = require("unifi.schedule")
local hotspot2 = require("openwrt.hotspot2")

local M = {}

-- Injectable seams for tests
M._uci        = nil  -- override with a mock UCI table; nil = require("uci")
-- "Multicast and Broadcast Blocker" enforcement (nftables). Injectable so
-- tests can capture the reconciled rules without shelling out to real nft.
M._bcfilter   = nil  -- nil = load src/openwrt/bcfilter.lua on first use
-- "WiFi Speed Limit" enforcement (tc). Injectable for the same reason.
-- Minimum RSSI's constants (wire offset, refusal margin).
M._minrssi    = nil  -- nil = load src/openwrt/minrssi.lua on first use
M._run_cmd    = function(cmd) return os.execute(cmd) end

-- Injectable: command execution that captures stdout (for read-only introspection,
-- as opposed to M._run_cmd which only reports success/failure for mutating commands).
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end

-- Injectable: file reader, for sysfs lookups (e.g. interface MAC address).
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Injectable: whole-file writer (pristine config copies).
M._write_file = function(path, content)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(content)
	f:close()
	return true
end
M._remove_file = function(path) return os.remove(path) end
-- Local time, for a WLAN Schedule's state at the moment of a push.
M._date = function() return os.date("*t") end
M._now = os.time

-- Where the MAC-based VLAN lists hostapd reads (accept_mac_file) live: on
-- flash, because hostapd reads them at boot, before openUF runs, and a
-- missing accept_mac_file fails the whole BSS.
-- The name carries a hash of the list: hostapd reads the file only when the
-- BSS is (re)configured, and a list-only change would otherwise leave every
-- UCI option as it was, so `wifi reload` would not touch the BSS. A new name
-- is a changed hostapd_bss_options line.
M.MACVLAN_DIR = "/etc/openuf"
function M.macvlan_path(section, content)
	local h = require("unifi.crypto").sha256_hex(content or ""):sub(1, 8)
	return M.MACVLAN_DIR .. "/macvlan-" .. section .. "-" .. h .. ".list"
end

-- The UCI network a vlan_filtering plan has for VLAN vid: its interface for
-- that VLAN, or the management interface when management sits on that VLAN;
-- nil when the plan carries none. The one place PPSK keys, RADIUS VLANs and
-- MAC-based VLANs ask.
function M.plan_network_for_vid(netplan, vid)
	if type(netplan) ~= "table" then return nil end
	local n = (netplan.vlan_ifaces or {})[vid]
	if not n and netplan.mgmt and netplan.bridge
			and netplan.mgmt.device == netplan.bridge.name .. "." .. vid then
		n = netplan.mgmt.iface
	end
	return n
end

-- The VLAN management sits on in a vlan_filtering plan, or nil.
function M.plan_mgmt_vid(netplan)
	local dev = type(netplan) == "table" and netplan.mgmt and netplan.bridge and netplan.mgmt.device
	local prefix = dev and (netplan.bridge.name .. ".")
	if prefix and dev:sub(1, #prefix) == prefix then return tonumber(dev:sub(#prefix + 1)) end
	return nil
end

-- Static radio capability defaults, used when UCI/driver introspection can't
-- supply a real value. Tune per target hardware (see u6iw.lua's fw.ver note
-- for the same caveat pattern).
M.RADIO_DEFAULTS = {
	builtin_antenna  = true,
	builtin_ant_gain = 3,   -- dBi
	max_txpower      = 20,  -- dBm
}

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

-- General memo for the lookup pass M.begin_pass/end_pass open (see the
-- wireless_status cache further down, which was the first thing to need one).
-- Anything in here answers the SAME question for the length of one inform
-- payload; outside a pass every call recomputes, which is what keeps the test
-- suite's per-test stubs independent of one another.
M._pass_cache = nil
local function pass_memo(key, fn)
	local cache = M._ws_pass and M._pass_cache
	if cache then
		local hit = cache[key]
		if hit ~= nil then return hit[1] end
	end
	local value = fn()
	if cache then cache[key] = {value} end
	return value
end

-- An enforcement module, unless a test injected one. nil rather than an
-- error when it cannot be loaded, so a missing module degrades to "not
-- enforced" instead of taking the whole config apply down with it.
local function get_sibling(name, override)
	if override then return override end
	local ok, mod = pcall(require, name)
	return (ok and type(mod) == "table") and mod or nil
end

local function get_bcfilter() return get_sibling("openwrt.bcfilter", M._bcfilter) end
local function get_minrssi()  return get_sibling("openwrt.minrssi", M._minrssi) end

-- Map a UCI wifi-device's channel number to the controller's band identifier.
-- The real controller's radio_table schema requires this "radio" field
-- ("ng"/"na"/"ad"/"6e") on every entry -- confirmed via decompiling the
-- controller's own radio-band enum (com.ubnt.g.f.e.rYtJfMBbtgWvku), whose
-- string-to-enum parser unconditionally calls .toLowerCase() with no null
-- guard. Omitting "radio" (as this function previously did) means that
-- parser gets a null and throws, which corrupts the controller's adopt/UI
-- state on every single inform -- invisible until now because radio_table
-- was always empty (no target hardware to source it from) prior to the UCI
-- mock. Only "ng"/"na" are handled -- openUF only targets dual-band 2.4/5GHz
-- hardware; 60GHz/6GHz
-- would need channel ranges that overlap 5GHz's numbering and can't be
-- disambiguated by channel number alone.
local function band_for_channel(channel)
	local ch = tonumber(channel)
	if ch and ch >= 1 and ch <= 14 then return "ng" end
	return "na"
end
-- Exported for inform.lua's build_json, which re-derives the band from the
-- LIVE negotiated channel (iw) after the radio-caps merge -- authoritative
-- once ACS has picked a channel, when UCI itself may only say "auto".
M.band_for_channel = band_for_channel

-- Band for a UCI wifi-device SECTION: config-first, channel-number fallback.
-- The channel value alone is not enough -- with channel=auto (ACS)
-- tonumber() is nil and the pure channel mapping above misreports a 2.4GHz
-- radio as "na" (5GHz). The section's own band declaration is authoritative:
-- `band` ("2g"/"5g"/"6g") on modern OpenWrt, `hwmode` ("11g"/"11a"/...) on
-- older releases. 6GHz maps to "na" only because openUF targets dual-band
-- 2.4/5GHz hardware (see band_for_channel's comment); a 6E target would need
-- the "6e" identifier and its own model capabilities.
local function band_for_device(s)
	if s.band == "2g" then return "ng" end
	if s.band == "5g" or s.band == "6g" then return "na" end
	if s.hwmode == "11b" or s.hwmode == "11g" or s.hwmode == "11ng" then return "ng" end
	if s.hwmode == "11a" or s.hwmode == "11na" or s.hwmode == "11ac" then return "na" end
	return band_for_channel(s.channel)
end

-- ─── Radio hardware capabilities ─────────────────────────────────────────────
--
-- openUF presents itself as a U6-InWall (802.11ax) no matter what the host
-- radios actually are, so a controller is entitled to push
-- radio.<n>.ieee_mode=11nahe80 at hardware that has never heard of HE -- as it
-- will at every one of this project's documented targets, which are 802.11n/ac.
-- Writing that htmode into UCI verbatim yields a config file that looks
-- perfectly correct and a hostapd that refuses to start: no SSID on the air at
-- all, and nothing in UCI to explain why. So probe what the hardware can
-- really do and clamp DOWNWARD only -- a controller asking for less than the
-- radio supports is a legitimate request, never something to "correct".
local PHY_RANK = {HT = 1, VHT = 2, HE = 3, EHT = 4}
local RANK_PHY = {"HT", "VHT", "HE", "EHT"}

-- Cached because it describes hardware, which does not change while openUF
-- runs -- with one exception. A regdomain change moves the per-channel TX
-- power limits and the DFS flags, so rf_config drops the cache when it writes
-- a new country. But the DRIVER only picks the new domain up when `wifi
-- reload` restarts the radios, which happens later in the same apply_config
-- pass and asynchronously at that -- while rf_config itself re-reads the caps
-- moments after dropping them (clamp_htmode, the beacon_rate check). So the
-- cache came straight back holding the OLD domain's figures and kept them
-- until the daemon restarted, and the max_txpower reported to the controller
-- -- the bound on its TX Power slider -- was the wrong regdomain's.
--
-- Hence the settle window: for PHY_CAPS_SETTLE seconds after a regdomain
-- write, cached caps are trusted for at most PHY_CAPS_REREAD seconds at a
-- time. After that it is back to cache-forever.
M._phy_caps_cache = nil
M._phy_caps_read_at = nil
M._phy_caps_unstable_until = nil
local PHY_CAPS_SETTLE = 60   -- the reload is long done inside this
local PHY_CAPS_REREAD = 10   -- one heartbeat

-- Injectable clock, for the settle window above.
M._time = os.time

local function regdomain_changed()
	M._phy_caps_cache = nil
	M._phy_caps_unstable_until = M._time() + PHY_CAPS_SETTLE
end

-- Parse `iw phy` output into per-band capabilities, keyed by band_for_device's
-- own vocabulary ("ng"/"na"). Each band is identified by the frequencies it
-- actually lists, NOT by its "Band N:" index -- that index is assigned per
-- driver (this project's ath9k radio reports 2.4GHz as Band 1, its ath10k
-- radio reports 5GHz as Band 2) and means nothing on its own.
local function parse_phy_caps(out)
	local bands, cur, phy = {}, nil, nil
	for line in (tostring(out) .. "\n"):gmatch("([^\n]*)\n") do
		-- Phy-level lines carry exactly one leading tab; a Band block's
		-- contents are indented deeper. That is what marks the end of a band
		-- block -- without it, phy-level sections listed after the bands (the
		-- extended-feature list below) would be attributed to whichever band
		-- happened to be last.
		if line:match("^%s*Wiphy%s") then
			phy = {beacon_rate = false, bands = {}}
			cur = nil
		elseif line:match("^\tBand %d+:") then
			cur = {ht40 = false, vht = false, he = false, eht = false,
				w160 = false, w320 = false, freq = nil, txpower = nil,
				phy = phy}
			bands[#bands + 1] = cur
			if phy then phy.bands[#phy.bands + 1] = cur end
		elseif line:match("^\t[^\t]") then
			cur = nil
		end
		-- Driver support for setting the beacon frame rate, reported per phy.
		-- hostapd treats a beacon_rate it cannot program as FATAL ("Failed to
		-- set beacon parameters" -> "Interface initialization failed"), so the
		-- radio never starts -- see rf_config.
		if phy and line:match("BEACON_RATE_LEGACY") then phy.beacon_rate = true end
		if cur then
			if line:match("HT20/HT40") then cur.ht40 = true end
			if line:match("^%s*VHT Capabilities") then cur.vht = true end
			if line:match("^%s*HE Iftypes") or line:match("^%s*HE PHY Capabilities") then
				cur.he = true
			end
			if line:match("^%s*EHT Iftypes") or line:match("^%s*EHT PHY Capabilities") then
				cur.eht = true
			end
			-- "Supported Channel Width: neither 160 nor 80+80" must NOT count
			-- as 160 support, hence the explicit negative check.
			if line:match("Supported Channel Width:") and line:match("160")
				and not line:match("neither 160") then
				cur.w160 = true
			end
			if line:match("320 MHz") then cur.w320 = true end
			-- "\t\t\t* 5180.0 MHz [36] (23.0 dBm)"; disabled channels carry no
			-- usable power and are skipped.
			local mhz, dbm = line:match("^%s*%*%s+([%d%.]+) MHz.*%(([%d%.]+) dBm%)")
			if mhz and not line:match("disabled") then
				cur.freq = cur.freq or tonumber(mhz)
				-- `iw` prints one decimal ("23.0 dBm"); floored to an integer
				-- so the payload carries 23 rather than 23.0 -- max_txpower is
				-- a whole-dBm field, and flooring never claims more than the
				-- driver allows.
				local p = tonumber(dbm)
				p = p and math.floor(p) or nil
				if p and (not cur.txpower or p > cur.txpower) then cur.txpower = p end
			end
		end
	end

	local caps = {}
	for _, b in ipairs(bands) do
		local key = b.freq and ((b.freq < 3000) and "ng" or "na") or nil
		if key then
			local width = 20
			if b.ht40 then width = 40 end
			if b.vht or b.he then width = math.max(width, 80) end
			if b.w160 then width = math.max(width, 160) end
			if b.eht and b.w320 then width = math.max(width, 320) end
			-- 2.4GHz stops at 40MHz -- there is no 80MHz channel in the band
			-- to be had, whatever the PHY generation. The widths above are
			-- derived from the PHY (a VHT or HE radio can do 80), which was
			-- accurate while every 2.4GHz radio here was HT-only and wrong
			-- the moment one was not: an HE 2.4GHz radio reported max_width
			-- 80, clamp_htmode passed a pushed HE80 straight through (it
			-- narrows to 40 only for kind "HT"), and hostapd treats a channel
			-- width it cannot program as fatal -- the radio never starts.
			if key == "ng" then width = math.min(width, 40) end
			local prev = caps[key]
			-- Two radios can serve the same band (rare, but a 2.4GHz-only and a
			-- dual-band phy in one device do it); keep the more capable view.
			caps[key] = {
				max_kind = (b.eht and 4) or (b.he and 3) or (b.vht and 2) or 1,
				max_width = width,
				max_txpower = b.txpower,
				beacon_rate = (b.phy and b.phy.beacon_rate) or false,
			}
			if prev then
				caps[key].max_kind  = math.max(prev.max_kind, caps[key].max_kind)
				caps[key].max_width = math.max(prev.max_width, caps[key].max_width)
				caps[key].max_txpower = math.max(prev.max_txpower or 0,
					caps[key].max_txpower or 0)
				if caps[key].max_txpower == 0 then caps[key].max_txpower = nil end
				caps[key].beacon_rate = prev.beacon_rate or caps[key].beacon_rate
			end
		end
	end
	return caps
end

-- Per-band hardware capabilities: {ng = {max_kind, max_width, max_txpower}, ...}
-- An empty table (no `iw`, unparseable output) means "unknown", which every
-- caller must treat as "leave the controller's request alone".
function M.phy_caps()
	local now = M._time()
	local stale = false
	if M._phy_caps_cache and M._phy_caps_unstable_until then
		if now < M._phy_caps_unstable_until then
			stale = (now - (M._phy_caps_read_at or 0)) >= PHY_CAPS_REREAD
		else
			M._phy_caps_unstable_until = nil   -- settled: back to cache-forever
		end
	end
	if not M._phy_caps_cache or stale then
		M._phy_caps_cache = parse_phy_caps(M._popen("iw phy") or "")
		M._phy_caps_read_at = now
	end
	return M._phy_caps_cache
end

-- The best PHY generation the given band's hardware can run ("HT"/"VHT"/
-- "HE"/"EHT"), or nil when the capabilities are unknown -- which callers must
-- treat as "do not upgrade anything".
--
-- The counterpart to clamp_htmode: that one refuses to give a radio a PHY it
-- cannot do, this one says what it CAN do, for a caller whose only other
-- source is a wire format that does not carry the answer.
function M.best_phy(band)
	local caps = M.phy_caps()[band]
	return caps and RANK_PHY[caps.max_kind] or nil
end

-- Clamp an OpenWrt htmode ("HE80", "VHT40", "HT20", ...) to what the given
-- band's hardware can actually do. Returns the (possibly adjusted) htmode and,
-- when it was adjusted, the original -- callers log the pair, because a
-- silently rewritten channel width is exactly the kind of change that turns
-- into an unexplainable bug report months later.
function M.clamp_htmode(band, htmode)
	if type(htmode) ~= "string" then return htmode, nil end
	local caps = M.phy_caps()[band]
	if not caps then return htmode, nil end
	-- Anything that isn't <PHY><width> (e.g. "NOHT") passes through untouched.
	local kind, width = htmode:match("^(%u+)(%d+)$")
	local rank = kind and PHY_RANK[kind]
	if not rank then return htmode, nil end

	local out_kind = RANK_PHY[math.min(rank, caps.max_kind)]
	local out_width = math.min(tonumber(width), caps.max_width)
	-- HT tops out at 40MHz: there is no such thing as HT80.
	if out_kind == "HT" then out_width = math.min(out_width, 40) end
	local out = out_kind .. tostring(out_width)
	if out == htmode then return htmode, nil end
	return out, htmode
end

-- Raise an OpenWrt htmode to at least `floor`, per-kind and per-width
-- independently ("VHT80" with a floor of "HE20" becomes "HE80"). Overrides the
-- controller, so it only runs when the board's radio policy asked for it
-- (dev.conf.radio.<band>.htmode_floor, UCI openuf.<band>.htmode_floor); the hardware clamp still runs after.
-- Returns the htmode and, when it changed, the original.
function M.raise_htmode(htmode, floor)
	if type(htmode) ~= "string" or type(floor) ~= "string" then return htmode, nil end
	local h_kind, h_width = htmode:match("^(%u+)(%d+)$")
	local f_kind, f_width = floor:match("^(%u+)(%d+)$")
	if not (h_kind and f_kind and PHY_RANK[h_kind] and PHY_RANK[f_kind]) then
		return htmode, nil
	end
	local kind  = RANK_PHY[math.max(PHY_RANK[h_kind], PHY_RANK[f_kind])]
	local width = math.max(tonumber(h_width), tonumber(f_width))
	if kind == "HT" then width = math.min(width, 40) end
	local out = kind .. tostring(width)
	if out == htmode then return htmode, nil end
	return out, htmode
end

-- Lower an htmode to at most `ceiling` -- the mirror of raise_htmode, for a
-- width the driver ADVERTISES and the radio cannot actually run (e.g. HE160
-- on a board whose driver cannot start DFS CAC, when every 160 MHz block
-- overlaps DFS). `iw phy` cannot say "advertised but unusable"; the board's
-- radio policy can, via dev.conf.radio.<band>.htmode_max (UCI
-- openuf.<band>.htmode_max).
function M.cap_htmode(htmode, ceiling)
	if type(htmode) ~= "string" or type(ceiling) ~= "string" then return htmode, nil end
	local h_kind, h_width = htmode:match("^(%u+)(%d+)$")
	local c_kind, c_width = ceiling:match("^(%u+)(%d+)$")
	if not (h_kind and c_kind and PHY_RANK[h_kind] and PHY_RANK[c_kind]) then
		return htmode, nil
	end
	local kind  = RANK_PHY[math.min(PHY_RANK[h_kind], PHY_RANK[c_kind])]
	local width = math.min(tonumber(h_width), tonumber(c_width))
	if kind == "HT" then width = math.min(width, 40) end
	local out = kind .. tostring(width)
	if out == htmode then return htmode, nil end
	return out, htmode
end

-- The UCI prefix applied to all openuf-managed wireless sections
local OPENUF_PREFIX = "openuf_"
-- Exported: the other modules that look for openUF's own sections use it.
M.PREFIX = OPENUF_PREFIX

-- Sentinel for an `extra` value meaning "delete this option", as distinct from
-- both "set it to something" and "leave it alone". Needed because several
-- OpenWrt wifi controls are expressed as the option's absence rather than an
-- off value -- see wlan_add()'s macfilter handling.
M.DELETE = setmetatable({}, {__tostring = function() return "<delete>" end})

-- Map from UniFi security type strings to UCI encryption values.
--
-- The Enterprise values are OpenWrt's own (25.12 iface.uc parse_encryption):
-- wpa2 -> auth_type eap (WPA-EAP), wpa3 -> eap2 (WPA-EAP-SHA256, PMF
-- required), wpa3-mixed -> eap-eap2 (both, PMF optional), wpa3-192 -> eap192
-- (WPA-EAP-SUITE-B-192). Their RADIUS servers come from vap.radius, written
-- by apply_config; unifi/wlan.lua drops an Enterprise WLAN that has none.
local SECURITY_MAP = {
	["open"]       = "none",
	["wpa2"]       = "psk2",
	["wpa3"]       = "sae",
	["wpa2/wpa3"]  = "sae-mixed",
	["owe"]        = "owe",
	["wpa2-eap"]      = "wpa2",
	["wpa3-eap"]      = "wpa3",
	["wpa2/wpa3-eap"] = "wpa3-mixed",
	["wpa3-eap192"]   = "wpa3-192",
}

-- The controller's aaa.<n>.wpa.1.pairwise, as an OpenWrt encryption suffix.
-- The cipher is always written: left out, OpenWrt picks it from the board and
-- the htmode (GCMP-256 where the phy lists it, on some releases), and a
-- cipher the clients or the driver cannot run leaves the SSID dead.
local CIPHER_MAP = {
	["CCMP"]      = "ccmp",
	["TKIP CCMP"] = "tkip+ccmp",
	["GCMP"]      = "gcmp",
	["CCMP-256"]  = "ccmp256",
	["GCMP-256"]  = "gcmp256",
}

-- The UCI `encryption` value for a security type and pushed cipher.
function M.encryption_for(security, pairwise)
	local enc = SECURITY_MAP[security] or "psk2"
	if enc == "none" then return enc end
	-- Enhanced Open is written bare. OpenWrt 25.12's generator expands an
	-- owe_transition section into its two BSSes only when `encryption ==
	-- 'owe'` exactly (hostapd.uc), so a cipher suffix would silently leave a
	-- transition WLAN as a lone hidden OWE BSS, with every legacy client
	-- locked out. Bare, the cipher is iface.uc's CCMP default for any WPA2-level
	-- auth type -- not the board- and htmode-dependent pick the explicit
	-- suffix exists to avoid, which only sae-compat is subject to there.
	if enc == "owe" then return enc end
	-- Suite B 192-bit is GCMP-256 by definition (iface.uc sets it); a CCMP
	-- suffix would override that into a combination no client accepts.
	if enc == "wpa3-192" then return enc .. "+gcmp256" end
	local cipher = CIPHER_MAP[tostring(pairwise or ""):upper()] or "ccmp"
	return enc .. "+" .. cipher
end

-- Deterministic 16-bit id from a string, formatted as 4 hex chars (802.11r
-- mobility domain is a 2-octet field). Used as a stopgap mobility_domain
-- when the controller only sends the high-level fast_roaming_enabled toggle
-- and no raw mobility_domain/r0kh/r1kh (UniFi's admin API has no such fields
-- -- it computes and syncs them internally across all APs on a site). Same
-- seed always yields the same domain, so every openUF-emulated AP on the
-- same network computes it identically without needing to coordinate.
function M.derive_mobility_domain(seed)
	local hash = 0
	for i = 1, #seed do
		hash = (hash * 31 + seed:byte(i)) % 65536
	end
	return string.format("%04x", hash)
end

-- ─── VAP management ──────────────────────────────────────────────────────────

-- Delete all openuf_* wifi-iface sections on the given radio (or all radios),
-- with the private pre-shared keys and VLANs (M.ppsk_add) that belong to them.
-- radio: optional UCI radio name (e.g. "radio0"); nil removes from all radios.
function M.wlan_clear(radio)
	local uci = get_uci()
	local cursor = uci.cursor()
	local to_delete = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if name and name:sub(1, #OPENUF_PREFIX) == OPENUF_PREFIX then
			if radio == nil or s.device == radio then
				to_delete[#to_delete + 1] = name
			end
		end
	end)
	-- netifd applies a wifi-station or wifi-vlan section without an iface to
	-- EVERY VAP, so one left behind by its VAP would not stay harmless. Only
	-- openUF's own are touched; a user's stays.
	local cleared = {}
	for _, name in ipairs(to_delete) do cleared[name] = true end
	for _, stype in ipairs({"wifi-station", "wifi-vlan"}) do
		cursor:foreach("wireless", stype, function(s)
			local name = s[".name"]
			if name and name:sub(1, #OPENUF_PREFIX) == OPENUF_PREFIX then
				local ifaces = s.iface
				if type(ifaces) ~= "table" then ifaces = {ifaces} end
				local ours = radio == nil
				for _, i in ipairs(ifaces) do
					if cleared[i] then ours = true end
				end
				if ours then to_delete[#to_delete + 1] = name end
			end
		end)
	end
	for _, name in ipairs(to_delete) do
		cursor:delete("wireless", name)
	end
	cursor:commit("wireless")
end

-- ─── Private Pre-Shared Keys ─────────────────────────────────────────────────

-- Every VLAN id one vap_table entry needs an L2 for: the WLAN's own, plus the
-- VLAN of each private pre-shared key. Sorted, no duplicates.
function M.vap_vlan_ids(vap)
	local seen, out = {}, {}
	local function add(v)
		v = tonumber(v)
		if v and not seen[v] then seen[v] = true; out[#out + 1] = v end
	end
	if vap.vlan_enabled then add(vap.vlan) end
	for _, k in ipairs(vap.ppsk or {}) do add(k.vid) end
	table.sort(out)
	return out
end

-- Private Pre-Shared Keys for the VAP in wifi-iface section `iface`.
--
-- OpenWrt has the whole feature already (checked in 25.12's ap.uc and the
-- wifi-station/wifi-vlan schemas): each wifi-station section becomes one line
-- of hostapd's wpa_psk_file (and of sae_password_file for SAE),
--   vlanid=20 00:00:00:00:00:00 <passphrase>
-- and each wifi-vlan section one line of its vlan_file, for which netifd
-- creates a netdev named <vap ifname>-<name> and puts it in the bridge of the
-- network it names. A key without a VLAN puts its client on the VAP's own
-- network.
--
-- keys:     vap.ppsk, {key=, vid=} each
-- networks: vid -> UCI network section for that VLAN
-- A key whose VLAN has no network is left out rather than provisioned
-- without one: that client would land on the VAP's own network, past the
-- segmentation the key exists for.
function M.ppsk_add(iface, keys, networks)
	local uci = get_uci()
	local cursor = uci.cursor()
	for i, k in ipairs(keys or {}) do
		local net = k.vid and networks[k.vid]
		if k.vid and not net then
			io.stderr:write(("ucihelper: %s: private pre-shared key %d left out, "
				.. "no network for VLAN %d\n"):format(iface, i, k.vid))
		else
			-- Two keys on one VLAN share its section.
			if k.vid then
				local vs = iface .. "_vlan" .. k.vid
				cursor:set("wireless", vs, "wifi-vlan")
				cursor:set("wireless", vs, "iface", {iface})
				-- The netdev is <vap ifname>-<name>: "phy0-ap0-20" stays
				-- inside the 15-character limit, where "v20" might not.
				cursor:set("wireless", vs, "name", tostring(k.vid))
				cursor:set("wireless", vs, "vid", tostring(k.vid))
				cursor:set("wireless", vs, "network", {net})
			end
			local ss = iface .. "_psk" .. i
			cursor:set("wireless", ss, "wifi-station")
			cursor:set("wireless", ss, "iface", {iface})
			cursor:set("wireless", ss, "mac", {"00:00:00:00:00:00"})
			cursor:set("wireless", ss, "key", k.key)
			if k.vid then
				cursor:set("wireless", ss, "vid", tostring(k.vid))
			end
		end
	end
	cursor:commit("wireless")
end

-- MAC-based VLANs ("Virtual Network Override") for one vap_table entry: what
-- goes into its accept_mac_file, and the VLAN networks it needs.
--
-- hostapd reads an accept_mac_file line as "<MAC> <VLAN id>"
-- (hostapd_config_read_maclist), and several accept_mac_file lines add up.
-- hostapd_check_acl consults the accept list FIRST, before the deny list and
-- macaddr_acl, and returns the line's VLAN with the accept; the VLAN must be
-- in the BSS's vlan_file (hostapd_vlan_valid), which OpenWrt builds from the
-- wifi-vlan sections. So with no MAC filter (macaddr_acl 0) a listed client
-- is accepted onto its VLAN and every other client as before. Because the
-- accept list wins, it must never carry a MAC the AP is meant to refuse:
--   * a deny filter (the user's, or Lock to Access Point's lock2ap entries):
--     a denied MAC is left out, so it stays refused;
--   * an allow filter (macaddr_acl 1): only allow-listed MACs keep their
--     VLAN, so the list cannot widen the allowlist;
--   * RADIUS MAC authentication (macaddr_acl 2): left out entirely, as an
--     accept-list hit would skip the RADIUS check.
-- An entry on the VAP's own VLAN changes nothing and is left out. Open and
-- OWE WLANs are left out too: ap.uc only writes dynamic_vlan/vlan_no_bridge
-- (vlan_possible) for PSK, SAE, EAP and an allow filter, and without
-- vlan_no_bridge hostapd would try to bridge the VLAN netdev itself.
--
-- resolve(vid) -> UCI network section for that VLAN (vid 1 = untagged), or
-- nil. Returns nil when nothing remains, else {content = "<file>",
-- networks = {vid -> network}, macs = n}.
function M.macvlan_plan(vap, resolve)
	if type(vap) ~= "table" or not vap.mac_vlans or #vap.mac_vlans == 0 then return nil end
	local sec = vap.security or "open"
	if sec == "open" or sec == "owe" then
		io.stderr:write(("ucihelper: %s: MAC-based VLANs not applied on an %s WLAN\n")
			:format(tostring(vap.ssid), sec))
		return nil
	end
	if vap.radius_mac_auth then
		io.stderr:write(("ucihelper: %s: MAC-based VLANs not applied with RADIUS MAC "
			.. "authentication (an accept-list hit would skip it)\n"):format(tostring(vap.ssid)))
		return nil
	end
	local listed = {}
	for _, m in ipairs(vap.mac_filter_list or {}) do listed[m:lower()] = true end
	local policy = vap.mac_filter_policy
	local own = (vap.vlan_enabled and tonumber(vap.vlan)) or 1
	local lines, networks, n = {}, {}, 0
	for _, e in ipairs(vap.mac_vlans) do
		local mac = e.mac:lower()
		local keep = e.vid ~= own
		if policy == "deny" and listed[mac] then keep = false end
		if policy == "allow" and not listed[mac] then keep = false end
		if keep then
			local net = networks[e.vid] or resolve(e.vid)
			if net then
				networks[e.vid] = net
				lines[#lines + 1] = mac .. " " .. e.vid
				n = n + 1
			else
				io.stderr:write(("ucihelper: %s: MAC-based VLAN %d for %s left out, "
					.. "no network for it\n"):format(tostring(vap.ssid), e.vid, mac))
			end
		end
	end
	if n == 0 then return nil end
	return {content = table.concat(lines, "\n") .. "\n", networks = networks, macs = n}
end

-- RADIUS-assigned VLANs (dynamic_vlan) for the Enterprise VAP in wifi-iface
-- section `iface`: one wifi-vlan per VLAN this AP already carries, the same
-- sections ppsk_add writes for a key's VLAN, so hostapd's vlan_file maps each
-- VLAN id RADIUS may return onto that VLAN's network. The push names no VLAN
-- list for this (a UniFi AP builds them on demand), so a VLAN the AP carries
-- no other way is not in the file and hostapd refuses the station.
-- networks: vid -> UCI network section
function M.radius_vlans_add(iface, networks)
	local uci = get_uci()
	local cursor = uci.cursor()
	local vids = {}
	for vid in pairs(networks or {}) do vids[#vids + 1] = vid end
	table.sort(vids)
	for _, vid in ipairs(vids) do
		local vs = iface .. "_vlan" .. vid
		cursor:set("wireless", vs, "wifi-vlan")
		cursor:set("wireless", vs, "iface", {iface})
		cursor:set("wireless", vs, "name", tostring(vid))
		cursor:set("wireless", vs, "vid", tostring(vid))
		cursor:set("wireless", vs, "network", {networks[vid]})
	end
	cursor:commit("wireless")
end

-- UCI option marking a wifi-iface that openUF disabled on the user's behalf,
-- so use_only_unifi_wlan can be switched back off without stranding the SSID.
local AUTODISABLED = OPENUF_PREFIX .. "autodisabled"

-- Apply the use_only_unifi_wlan option to every wifi-iface openUF does not
-- manage (i.e. not "openuf_"-prefixed).
--
-- enabled=true  -> disable those SSIDs, stamping each one openUF turns off.
-- enabled=false -> re-enable only the ones carrying that stamp.
--
-- An SSID the *user* had already disabled is never stamped, so switching the
-- option off later does not silently switch their SSID back on. The option is
-- documented (README/USAGE) and defaults to true in config.lua, but a missing
-- config is treated as false: openUF should not start disabling a stranger's
-- SSIDs just because a caller failed to thread cfg through.
--
-- A wifi-iface whose mode is not "ap" is EXEMPT, in both directions. This
-- option is about SSIDs competing with the controller's on the air; a mesh
-- point or a station interface is a LINK, not a competing SSID -- and it may
-- well be this AP's own uplink, in which case disabling it takes the device
-- off the network with no way back short of a serial console. An absent mode
-- is OpenWrt's own default of "ap". An exempt section openUF had already
-- switched off on an earlier pass (it carries the stamp) is switched back on
-- once, so the exemption repairs the damage rather than freezing it.
-- Where the board's own wireless config is kept, once, before own_config
-- deletes the SSIDs openUF does not manage (syswrapper.sh restore-wireless).
M.WIRELESS_PRISTINE = "/etc/openuf/wireless.pre-openuf"

-- own: delete foreign AP sections outright instead of disabling them
-- (config.own_config, default on) -- the controller's WLANs are the AP's WLANs.
-- Client/mesh sections are never touched.
function M.set_wlan_exclusive(enabled, own)
	local uci = get_uci()
	local cursor = uci.cursor()
	if enabled and own then
		local doomed = {}
		cursor:foreach("wireless", "wifi-iface", function(s)
			local name = s[".name"]
			if name and name:sub(1, #OPENUF_PREFIX) ~= OPENUF_PREFIX
				and (s.mode == nil or s.mode == "ap") then
				doomed[#doomed + 1] = name
			end
		end)
		if #doomed > 0 then
			if not M._read_file(M.WIRELESS_PRISTINE) then
				local cur = M._read_file("/etc/config/wireless")
				if cur then M._write_file(M.WIRELESS_PRISTINE, cur) end
			end
			for _, name in ipairs(doomed) do cursor:delete("wireless", name) end
			io.stderr:write("openuf: removed the board's own SSIDs (" .. table.concat(doomed, ", ")
				.. "); originals in " .. M.WIRELESS_PRISTINE .. "\n")
			cursor:commit("wireless")
		end
		return
	end
	local targets = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if name and name:sub(1, #OPENUF_PREFIX) ~= OPENUF_PREFIX then
			local stamped = (s[AUTODISABLED] == "1")
			if s.mode ~= nil and s.mode ~= "ap" then
				if stamped then
					targets[#targets + 1] = {name = name, release = true}
				end
			else
				targets[#targets + 1] = {name = name, disabled = s.disabled,
					stamped = stamped}
			end
		end
	end)
	for _, t in ipairs(targets) do
		if t.release then
			cursor:set("wireless", t.name, "disabled", "0")
			cursor:set("wireless", t.name, AUTODISABLED, "0")
		elseif enabled then
			if t.disabled ~= "1" then
				cursor:set("wireless", t.name, "disabled", "1")
				cursor:set("wireless", t.name, AUTODISABLED, "1")
			end
		elseif t.stamped then
			cursor:set("wireless", t.name, "disabled", "0")
			cursor:set("wireless", t.name, AUTODISABLED, "0")
		end
	end
	cursor:commit("wireless")
end

-- ─── Minimum Data Rate ───────────────────────────────────────────────────────

-- The 802.11 legacy rate ladder, in kb/s -- the unit both the controller's
-- wireless.<n>.minrate_data and OpenWrt's basic_rate/supported_rates use.
-- CCK (802.11b) rates first, then the OFDM (802.11g/a) set.
local CCK_RATES  = {1000, 2000, 5500, 11000}
local OFDM_RATES = {6000, 9000, 12000, 18000, 24000, 36000, 48000, 54000}

-- Derive a radio's UCI rate options from a Minimum Data Rate floor.
--
-- floor_kbps:    the minimum data rate, in kb/s (wireless.<n>.minrate_data)
-- allow_cck:     whether 802.11b/CCK rates stay on the ladder at all
--                (wireless.<n>.minrate_cck_rates.status)
-- drop_below:    whether rates under the floor are also removed from the
--                advertised set, not merely made non-basic
--                (wireless.<n>.minrate_below_disable)
--
-- basic_rate is what actually enforces a *minimum*: a station must support
-- every basic rate to associate at all, so making the floor basic excludes
-- anything slower. supported_rates additionally stops the lower rates being
-- advertised, which is the separate "advertising rates" sub-toggle.
--
-- is_2g:         the radio is a 2.4 GHz one. CCK exists only there: on 5 GHz
--                the ladder is OFDM alone, whatever allow_cck says.
--
-- Returns nil when the floor excludes every rate in the band, rather than
-- emitting an empty list that would leave hostapd unable to bring the BSS up.
-- The ladder is sorted: CCK's 11 Mb/s sits above OFDM's 6 and 9, so a floor
-- of 6 or 9 Mb/s must make 6 or 9 basic, never 11.
function M.derive_rates(floor_kbps, allow_cck, drop_below, is_2g)
	if not floor_kbps then return nil end
	local ladder = {}
	if allow_cck ~= false and is_2g == true then
		for _, r in ipairs(CCK_RATES) do ladder[#ladder + 1] = r end
	end
	for _, r in ipairs(OFDM_RATES) do ladder[#ladder + 1] = r end
	table.sort(ladder)

	local at_or_above = {}
	for _, r in ipairs(ladder) do
		if r >= floor_kbps then at_or_above[#at_or_above + 1] = r end
	end
	if #at_or_above == 0 then return nil end

	local rates = {
		-- The floor itself is the mandatory rate. Kept as a one-element list
		-- rather than "every rate at or above the floor": each additional basic
		-- rate is another rate a station must implement to associate, which
		-- would exclude clients the controller never intended to exclude.
		basic_rate   = {at_or_above[1]},
		-- OpenWrt's legacy_rates is the 802.11b on/off switch; 0 is also what
		-- the controller signals via pureg=1 on 2.4 GHz.
		legacy_rates = (allow_cck == false) and "0" or "1",
	}
	if drop_below then rates.supported_rates = at_or_above end
	return rates
end

-- Create a new wifi-iface section named openuf_<ssid> on the given radio.
-- radio:    UCI radio name, e.g. "radio0" or "radio1"
-- ssid:     SSID string
-- security: "open" | "owe" | "wpa2" | "wpa3" | "wpa2/wpa3", or a table
--           {security=, pairwise=} carrying the pushed cipher as well
-- password: WPA pre-shared key (ignored when security is "open" or "owe")
-- extra:    optional table of additional UCI key/value pairs (802.11r/k/v etc.)
-- network:  UCI network/interface name to bridge this SSID onto (defaults to
--           "lan"); pass a VLAN-tagged interface from ensure_vlan_network() to
--           put the SSID on that VLAN.
-- wlanconf_id: optional controller-side wlanconf object id (system_cfg's
--           aaa.<n>.id), stashed the same way so get_vap_table() can echo it
--           back as the vap's "id" -- required for the controller to accept
--           the vap (and its sta_table) at all.
-- Returns the section name, which a private pre-shared key ties itself to.
function M.wlan_add(radio, ssid, security, password, extra, network, wlanconf_id)
	local uci = get_uci()
	local cursor = uci.cursor()
	local section_name = M.section_name(radio, ssid)
	local enc
	if type(security) == "table" then
		enc = M.encryption_for(security.security, security.pairwise)
	else
		enc = M.encryption_for(security)
	end
	cursor:set("wireless", section_name, "wifi-iface")
	cursor:set("wireless", section_name, "device", radio)
	cursor:set("wireless", section_name, "mode", "ap")
	cursor:set("wireless", section_name, "ssid", ssid)
	cursor:set("wireless", section_name, "encryption", enc)
	cursor:set("wireless", section_name, "network", network or "lan")
	if wlanconf_id then
		cursor:set("wireless", section_name, "openuf_wlanconf_id", wlanconf_id)
	end
	if password and enc ~= "none" and enc ~= "owe" then
		cursor:set("wireless", section_name, "key", password)
	end
	-- 802.11r/k/v
	if extra then
		for k, v in pairs(extra) do
			-- M.DELETE means "this option must not be present", which is not
			-- the same as "don't touch it": OpenWrt expresses several controls
			-- (macfilter above all) as the option's ABSENCE, and an
			-- out-of-enum stand-in value like "disable" is rejected by the
			-- 25.12 config validator hard enough to abort the radio.
			-- Deleting is also what lifts a previously pushed value.
			if v == M.DELETE then
				cursor:delete("wireless", section_name, k)
			-- A table value is a UCI *list* option (e.g. maclist) and must be
			-- handed to the binding as-is -- tostring() would write the
			-- literal "table: 0x...". Same convention rf_config already uses
			-- for basic_rate/supported_rates.
			elseif type(v) == "table" then
				cursor:set("wireless", section_name, k, v)
			else
				cursor:set("wireless", section_name, k, tostring(v))
			end
		end
	end
	cursor:commit("wireless")
	return section_name
end

-- The wifi-iface section name wlan_add uses for an SSID on a radio.
function M.section_name(radio, ssid)
	-- Section name includes the radio, not just the SSID: broadcasting the
	-- same SSID on both radios simultaneously is the default, common case
	-- (the controller UI's "Radio Band: 2.4 GHz + 5 GHz" checkboxes) and
	-- produces one wlan_add() call per radio with an identical ssid. Keying
	-- purely by SSID collapsed both calls into the same UCI section, so the
	-- second call's "device" silently overwrote the first -- confirmed live
	-- against a real controller: only the last-processed radio's VAP
	-- survived. The radio is sanitized the same way the ssid is, though UCI
	-- radio names ("radio0"/"radio1") never need it.
	--
	-- The character class must NOT keep "-". A UCI section name may contain
	-- only [A-Za-z0-9_], and libuci enforces that in the most unhelpful way
	-- available: cursor:set() returns true, cursor:commit() returns true, and
	-- the section is silently discarded -- it never reaches /etc/config and
	-- never appears in `uci show`. So an SSID with a hyphen produced a
	-- wlan_add that reported success at every step and left no WLAN behind,
	-- with nothing in any log to say so. Confirmed live: creating
	-- "openuf-verify" in the controller pushed correctly, parsed correctly
	-- into vap_table, and simply never provisioned. Hyphens are common in
	-- SSIDs, so this was a wide hole.
	--
	-- Sanitizing is lossy, and that loss used to collapse WLANs: "Guest WiFi",
	-- "Guest-WiFi" and "Guest_WiFi" all became openuf_radio0_Guest_WiFi, so
	-- two of them on one radio shared a section and the second silently
	-- overwrote the first -- the same failure the per-radio keying above
	-- exists to prevent, one level down. When the name had to be ALTERED at
	-- all, a short hash of the original keeps them apart; a name that needed
	-- no alteration keeps the section name it has always had, so nothing
	-- already deployed is renamed. (apply_config wlan_clear()s every openuf_
	-- section before rebuilding them, so a name that does change leaves
	-- nothing stale behind either.)
	local safe_ssid = ssid:gsub("[^%w_]", "_")
	if safe_ssid ~= ssid then
		safe_ssid = safe_ssid .. "_" .. M.derive_mobility_domain(ssid)
	end
	local section_name = OPENUF_PREFIX .. tostring(radio):gsub("[^%w_]", "_")
		.. "_" .. safe_ssid
	return section_name
end

-- True when this OpenWrt is 21.02+, i.e. netifd expects `config device`
-- sections and `option device` on an interface. Probed from the running
-- config rather than assumed: any interface carrying `device`, or the
-- presence of a `device` section, settles it. Pre-21.02 builds have neither
-- and want `option ifname` (which 25.12 still accepts as a legacy alias --
-- confirmed live -- so the probe is about which BRIDGE syntax to use, not
-- about the sub-device name).
local function netifd_uses_device_sections(cursor)
	local modern = false
	cursor:foreach("network", "device", function() modern = true end)
	if modern then return true end
	cursor:foreach("network", "interface", function(s)
		if s.device then modern = true end
	end)
	return modern
end

-- Idempotently create (or reuse) the L2 a VLAN-tagged SSID lives on: a bridge
-- holding the tagged uplink sub-device (e.g. "eth1.20" for VLAN 20 on cpueth
-- "eth1"). The VAP joins by naming the returned interface section, and netifd
-- enslaves it to the same bridge.
--
-- The bridge is the whole point. An interface whose device is the bare
-- sub-device does come up (confirmed live on 25.12: `eth1.20@eth1` UP,
-- netifd logging "Interface 'openuf_vlan20' is now up") -- but the VAP is
-- then a second, SEPARATE netdev with no master, so nothing joins the two.
-- A client associates and gets no DHCP, no gateway, nothing, while every
-- layer looks healthy. The controller's own push says as much: alongside the
-- WLAN it sends a bridge block naming exactly this topology --
--   bridge.2.devname=br0.20
--   bridge.2.port.1.devname=ath2      (the vap)
--   bridge.2.port.2.devname=eth0.20   (the tagged uplink)
-- which is a specification, not decoration.
--
-- OWNERSHIP, since two modules write this bridge. This function guarantees
-- one thing: the tagged uplink sub-device is a member. Any OTHER member it
-- finds is left alone, because on a DSA board switchvlan puts the physical
-- sockets assigned to this VLAN into the same bridge -- per-port VLAN and a
-- tagged SSID on the same VID are the same L2 there, and must be. An earlier
-- version set `ports` outright, which meant each push handed the bridge back
-- and forth: apply_config resetting it to the uplink alone, switchvlan adding
-- the sockets again, and a network reload on every inform.
--
-- Returns the UCI network/interface section name.
function M.ensure_vlan_network(cpueth, vlan_id)
	local uci = get_uci()
	local cursor = uci.cursor()
	local section_name = OPENUF_PREFIX .. "vlan" .. tostring(vlan_id)
	local ifname = cpueth .. "." .. tostring(vlan_id)
	local br_section = OPENUF_PREFIX .. "brdev" .. tostring(vlan_id)
	local br_name = "br-" .. OPENUF_PREFIX:gsub("_$", "") .. tostring(vlan_id)
	local port_section = OPENUF_PREFIX .. "brport" .. tostring(vlan_id)

	local changed = false
	if netifd_uses_device_sections(cursor) then
		-- 21.02+: a named `config device` bridge, and the interface points at
		-- it by name.
		if cursor:get("network", br_section, "name") ~= br_name then
			cursor:set("network", br_section, "device")
			cursor:set("network", br_section, "type", "bridge")
			cursor:set("network", br_section, "name", br_name)
			cursor:set("network", br_section, "ports", {ifname})
			changed = true
		else
			-- Section already there: add the uplink if it is missing and
			-- leave every other member in place (see OWNERSHIP above).
			local ports = cursor:get("network", br_section, "ports")
			if type(ports) == "string" then ports = {ports} end
			ports = ports or {}
			local have = false
			for _, p in ipairs(ports) do if p == ifname then have = true end end
			if not have then
				ports[#ports + 1] = ifname
				cursor:set("network", br_section, "ports", ports)
				changed = true
			end
		end
		-- Turn MAC learning OFF on the tagged uplink port. On a DSA board
		-- `wan` (untagged, in br-lan) and `wan.10` are the SAME physical
		-- port on the SAME hardware switch, and that switch has ONE FDB.
		-- With learning on, it learns the upstream router's MAC against
		-- wan.10 and files it in the VLAN bridge's domain:
		--     5a:d6:..:f6 dev wan.10 offload master br-openuf10
		-- Wired clients sit in that hardware FDB too (`dev lan4 self`), so
		-- their frames to the router get hardware-forwarded into the VLAN
		-- domain and blackholed -- LAN peers reachable, gateway and internet
		-- dead. WiFi clients ride the CPU/software path, hit the correct
		-- `dev wan master br-lan` entry, and work: the giveaway signature is
		-- WiFi fine, wired broken, on the same AP. Confirmed live on an
		-- AX3000T (2026-09-03) and fixed by exactly this, after which the
		-- hardware entry binds correctly as `dev wan self`.
		--
		-- Cost is nil in practice: the VLAN bridge is the uplink plus the
		-- VAP(s), so unlearned unicast floods to the one other port it would
		-- have been forwarded to anyway. Only the uplink port is set -- every
		-- other member still learns normally.
		if cursor:get("network", port_section, "name") ~= ifname
			or tostring(cursor:get("network", port_section, "learning") or "") ~= "0" then
			cursor:set("network", port_section, "device")
			cursor:set("network", port_section, "name", ifname)
			cursor:set("network", port_section, "learning", "0")
			changed = true
		end
		if cursor:get("network", section_name, "device") ~= br_name then
			cursor:set("network", section_name, "interface")
			cursor:set("network", section_name, "device", br_name)
			cursor:set("network", section_name, "proto", "none")
			-- Leaving a stale ifname behind would have netifd bridge the raw
			-- sub-device instead of the bridge on some builds.
			cursor:delete("network", section_name, "ifname")
			changed = true
		end
	else
		-- Pre-21.02: the interface IS the bridge, with the sub-device as its
		-- only member port.
		if cursor:get("network", section_name, "ifname") ~= ifname
			or cursor:get("network", section_name, "type") ~= "bridge" then
			cursor:set("network", section_name, "interface")
			cursor:set("network", section_name, "type", "bridge")
			cursor:set("network", section_name, "ifname", ifname)
			cursor:set("network", section_name, "proto", "none")
			changed = true
		end
	end

	if changed then cursor:commit("network") end
	-- Reported to the caller so one network reload covers every VLAN in a
	-- push, and a steady-state push that changed nothing issues none.
	M._network_dirty = M._network_dirty or changed

	return section_name
end

-- ─── Bridge identity ─────────────────────────────────────────────────────────

-- One netdev's MAC from sysfs, lowercased, or nil.
local function mac_of(ifname)
	local raw = ifname and M._read_file("/sys/class/net/" .. ifname .. "/address")
	local mac = type(raw) == "string" and raw:match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	return mac and mac:lower() or nil
end

-- The bridge a netdev is enslaved to, or nil when it carries its own address.
local function master_of(ifname)
	local m = M._popen("readlink /sys/class/net/" .. tostring(ifname) .. "/master")
	m = type(m) == "string" and m:match("([^/%s]+)%s*$") or nil
	if m and m ~= "" and m ~= ifname then return m end
	return nil
end

-- Give the management bridge the MAC openUF identifies as.
--
-- openUF takes its IDENTITY from `dev.conf.net.lan_cpueth` -- that netdev's MAC
-- is what the controller keys the adopted device on, what lldpd advertises as
-- the chassis id, and what every inform arrives under. It takes its reported
-- IP from the same name, but `announce.get_ip` deliberately hops to the BRIDGE
-- that port is enslaved to, because a bridge member carries no address.
--
-- MAC from the port, address from the bridge: fine as long as the two share a
-- MAC, which on every swconfig board here they do (`eth1` and `br-lan` both
-- read the same address, so the divergence never existed to be noticed). It is
-- NOT true on DSA. There `lan_cpueth` names a socket -- `wan` on the AX3000T,
-- whose MAC is board.json's `label_macaddr` -- while `br-lan` inherits the DSA
-- conduit's (`eth0`). openUF then announces itself as 00:00:5e:00:53:01 while
-- every frame it sources, and the ARP entry for the address it reports, is
-- 00:00:5e:00:53:02. The gateway sees one device claiming the IP and a
-- different one using it, and raises an IP conflict against a network that is
-- in fact correctly configured. Confirmed on the wire 2026-09-12: a capture on
-- `wan` shows 192.0.2.4 sending exclusively from the eth0 MAC, while
-- `lldpd.config.cid_interface='wan'` advertises the other one.
--
-- Pinning the bridge's `macaddr` closes it, and is what a real UniFi AP looks
-- like: one MAC for identity, LLDP and management traffic. Adoption is keyed
-- on `lan_cpueth`'s MAC, which this does not touch, so the device record
-- survives -- see _warn_identity_change for what changing THAT would cost.
--
-- Only ever acts when the two genuinely differ, so a board where they already
-- agree (every swconfig one) is untouched and no reload is issued. Note that
-- on a DHCP-addressed board the new L2 identity means a new lease and possibly
-- a new address; openUF reports the change on the next inform and the adoption
-- is unaffected, but that is why this is loud rather than silent.
-- Before openUF reloads the network itself: a DHCP management interface must
-- come back on the address it has. OpenWrt's DHCP client releases its lease
-- when it stops (unless norelease), so a reload renumbered the AP -- bifrost
-- 10.0.0.4 -> 10.0.1.46 on an LLDP fix. norelease covers every later restart;
-- the running client was started without it and releases once more, so it
-- also asks for the address back (`ipaddr` is a request hint on proto dhcp).
-- Returns true when UCI changed.
function M.keep_dhcp_address(iface, ip)
	if type(iface) ~= "string" or type(ip) ~= "string"
		or not ip:match("^%d+%.%d+%.%d+%.%d+$") or ip == "0.0.0.0" then return false end
	local cursor = get_uci().cursor()
	if cursor:get("network", iface, "proto") ~= "dhcp" then return false end
	local changed = false
	if cursor:get("network", iface, "norelease") ~= "1" then
		cursor:set("network", iface, "norelease", "1")
		changed = true
	end
	if cursor:get("network", iface, "ipaddr") ~= ip then
		cursor:set("network", iface, "ipaddr", ip)
		changed = true
	end
	if changed then cursor:commit("network") end
	M.stop_releasing_dhcp_client(iface)
	return changed
end

-- A DHCP client started before norelease was set still releases its lease
-- when netifd stops it, and the server then hands the address to nobody in
-- particular -- a reserved address outside the dynamic range is gone for good.
-- SIGKILL skips the release: the lease stays on the server and the client
-- netifd starts next renews it. Only a client running with -R (release on
-- exit) is touched. Called right before openUF reloads the network.
function M.stop_releasing_dhcp_client(iface)
	local ok_j, cjson = pcall(require, "cjson")
	if not ok_j then return false end
	local ok, st = pcall(cjson.decode, M._popen("ubus call network.interface." .. tostring(iface) .. " status") or "")
	local dev = ok and type(st) == "table" and (st.l3_device or st.device) or nil
	if type(dev) ~= "string" or not dev:match("^[%w%.%-_]+$") then return false end
	local pid = tonumber((M._read_file("/var/run/udhcpc-" .. dev .. ".pid") or ""):match("%d+"))
	if not pid then return false end
	local cmdline = (M._read_file("/proc/" .. pid .. "/cmdline") or ""):gsub("%z", " ")
	if not (cmdline:find("udhcpc", 1, true) and cmdline:find(" -R", 1, true)) then return false end
	M._popen("kill -9 " .. pid)
	return true
end

-- LLDP must announce the MAC openUF is adopted under, or the controller cannot
-- place the AP in its topology (it matches the neighbour's chassis ID against
-- its devices). OpenWrt's lldpd init resolves a bridge in cid_interface down
-- to its member PORTS, and lldpd only ever takes a chassis MAC from a port --
-- so pointing it at the bridge announced some port's MAC (heimdall: ...:3b
-- for ...:3a), a random one (a WAX220's eth0), or none at all ("local
-- bifrost"). So: the uplink socket carries the identity MAC -- as a Linux
-- bridge's uplink port normally does -- and is lldpd's chassis interface.
-- Only for an uplink that is a bridge port. Returns network_changed,
-- lldpd_changed.
function M.ensure_lldp_identity(cfg)
	local up = cfg and cfg.net and cfg.net.lan_cpueth
	local pinned = cfg and cfg.net and cfg.net.identity_mac
	local want = type(pinned) == "string" and pinned:lower() or nil
	if not (up and want and master_of(up)) then return false, false end
	local cursor = get_uci().cursor()

	local net_changed = false
	if (mac_of(up) or ""):lower() ~= want then
		local sec
		cursor:foreach("network", "device", function(s)
			if s.name == up and s.type ~= "bridge" then sec = s[".name"] end
		end)
		if not sec then
			sec = "openuf_uplink"
			cursor:set("network", sec, "device")
			cursor:set("network", sec, "name", up)
		end
		if tostring(cursor:get("network", sec, "macaddr") or ""):lower() ~= want then
			cursor:set("network", sec, "macaddr", want)
			cursor:commit("network")
			io.stderr:write(("ucihelper: uplink %s takes the identity MAC %s, so LLDP "
				.. "announces what the controller adopted\n"):format(up, want))
			M._network_dirty = true
			net_changed = true
		end
	end

	local lldp_changed = false
	if cursor:get("lldpd", "config") then
		local cur = cursor:get("lldpd", "config", "cid_interface")
		if type(cur) == "table" then cur = table.concat(cur, " ") end
		if cur ~= up then
			cursor:set("lldpd", "config", "cid_interface", up)
			cursor:commit("lldpd")
			lldp_changed = true
		end
	end
	return net_changed, lldp_changed
end

function M.ensure_bridge_identity(cfg)
	local cpueth = cfg and cfg.net and cfg.net.lan_cpueth
	local pinned = cfg and cfg.net and cfg.net.identity_mac
	local want = (type(pinned) == "string" and pinned:lower()) or mac_of(cpueth)
	if not want then return false end

	local br = master_of(cpueth)
	-- No bridge means the port holds the address itself: nothing diverges.
	if not br then return false end
	local have = mac_of(br)
	if not have or have == want then return false end

	local cursor = get_uci().cursor()
	-- Found by the bridge's NAME, not a section name: it is the board's own
	-- anonymous `network.@device[0]`, and openUF must not assume where it sits.
	local sec
	cursor:foreach("network", "device", function(s)
		if s.name == br and s.type == "bridge" then sec = s[".name"] end
	end)
	if not sec then
		io.stderr:write(("ucihelper: %s has MAC %s but openUF identifies as %s, and "
			.. "there is no `config device` section for %s to pin it on -- the "
			.. "controller will see an IP conflict against itself\n")
			:format(br, have, want, br))
		return false
	end

	if tostring(cursor:get("network", sec, "macaddr") or ""):lower() == want then
		return false
	end
	cursor:set("network", sec, "macaddr", want)
	cursor:commit("network")
	io.stderr:write(("ucihelper: pinning %s to the identity MAC %s (was %s, from %s) "
		.. "-- MAC and reported IP must belong to the same netdev or the gateway "
		.. "reports an IP conflict\n"):format(br, want, have, cpueth))
	M._network_dirty = true
	return true
end

-- Delete the interface and bridge sections of every VLAN not in `wanted`
-- (a set keyed by VLAN id). Only openUF's own sections are ever touched --
-- same discipline as wlan_clear()'s openuf_ prefix rule.
--
-- Called on every push, including one that carries no VLAN at all: deleting
-- the last tagged WLAN has to tear its L2 down too, and an empty `wanted` is
-- exactly how that arrives.
function M.prune_vlan_networks(wanted)
	local uci = get_uci()
	local cursor = uci.cursor()
	wanted = wanted or {}

	local doomed = {}
	local function sweep(stype, pattern)
		cursor:foreach("network", stype, function(s)
			local id = s[".name"] and s[".name"]:match(pattern)
			if id and not wanted[tonumber(id)] then
				doomed[#doomed + 1] = s[".name"]
			end
		end)
	end
	sweep("interface", "^" .. OPENUF_PREFIX .. "vlan(%d+)$")
	sweep("device",    "^" .. OPENUF_PREFIX .. "brdev(%d+)$")
	-- The uplink port's learning override goes with the bridge it qualified;
	-- left behind it would keep learning off on a port no openUF bridge owns.
	sweep("device",    "^" .. OPENUF_PREFIX .. "brport(%d+)$")
	-- ...and switchvlan's per-SOCKET overrides on the same bridge
	-- (`openuf_brport<vid>_<socket>`), which the anchored pattern above
	-- deliberately does not match. A VLAN going away takes its moved sockets
	-- back to br-lan, and an override left behind would keep learning off on a
	-- port no openUF bridge owns -- silently costing that port its host list.
	sweep("device",    "^" .. OPENUF_PREFIX .. "brport(%d+)_")

	if #doomed == 0 then return false end
	for _, name in ipairs(doomed) do
		cursor:delete("network", name)
	end
	cursor:commit("network")
	M._network_dirty = true
	return true
end

-- ─── Radio configuration ─────────────────────────────────────────────────────

-- The UCI `channels` list (hostapd `chanlist`) for an Auto radio whose site
-- excludes some channels. `base` is the candidate plan (2.4 GHz's 1/6/11) or
-- nil for every channel; the exclusions come off it. hostapd's chanlist is
-- an allow-list of channel numbers and hyphenated ranges, matched by number
-- against what the phy has, so "every channel but these" is written as the
-- ranges between them over 1..233 (the highest 6 GHz channel). A plan the
-- exclusions empty falls back to every other channel rather than leaving ACS
-- with nothing. nil when there is nothing to write.
M.ACS_MAX_CHANNEL = 233
function M.acs_candidates(base, exclude)
	local ex = {}
	for _, c in ipairs(exclude or {}) do ex[tonumber(c) or -1] = true end
	if base then
		local out = {}
		for _, c in ipairs(base) do
			if not ex[c] then out[#out + 1] = tostring(c) end
		end
		if #out > 0 then return out end
	end
	if not exclude or #exclude == 0 then return nil end
	local out, start = {}, nil
	for c = 1, M.ACS_MAX_CHANNEL + 1 do
		local free = c <= M.ACS_MAX_CHANNEL and not ex[c]
		if free and not start then
			start = c
		elseif not free and start then
			out[#out + 1] = (start == c - 1) and tostring(start) or (start .. "-" .. (c - 1))
			start = nil
		end
	end
	return out
end

-- Configure a radio's channel, mode, and TX power.
-- radio:  UCI radio name, e.g. "radio0"
-- htmode: UCI/OpenWrt htmode string ("HT20", "HT40", "VHT80", "HE80", ...), or
-- nil to leave the radio's current width/PHY unchanged. Derived from the
-- controller's radio.<n>.ieee_mode by inform.lua's _htmode_from_ieee_mode --
-- that key is the wire's only channel-width signal (CONFIRMED live
-- 2026-07-18). Until then this argument was a "11n"/"11ac"/"11ax" token that
-- nothing on the parse side ever produced, so htmode was never written at all
-- and the controller's channel-width setting silently did nothing.
-- chan:   channel number, or the string "auto" (written verbatim -- UCI
-- channel=auto makes OpenWrt engage hostapd ACS at radio bring-up)
-- txpwr: TX power in dBm, the string "auto" (deletes the UCI option --
-- absent txpower = driver default/max, the closest UCI has to Auto), or
-- nil to leave unchanged
-- minrssi_enabled/minrssi_raw: "Minimum RSSI" (Devices -> [AP] -> Radios),
-- a per-radio (not per-SSID) setting -- confirmed live 2026-07-14 via the
-- controller's stamgr.<n>.minrssi.* wire keys, a section separate from and
-- indexed the same as radio.<n>. minrssi_raw is stored as-received (raw wire
-- units, dBm + 95; openuf/minrssi.lua). On disable only the flag is written
-- to 0; minrssi_rssi stays parked in UCI (harmless -- every consumer gates on
-- the flag first) so a later re-enable without a threshold change reuses it.
-- The refusal half is hostapd's: rssi_reject_assoc_rssi and
-- rssi_ignore_probe_request, stamped openuf_minrssi and torn down on disable.
-- rates: optional table from M.derive_rates() plus an optional beacon_rate,
-- i.e. the "Minimum Data Rate" settings. These are wifi-DEVICE options in
-- OpenWrt, not wifi-iface ones (confirmed in OpenWrt's hostapd.sh: basic_rate,
-- supported_rates, legacy_rates and beacon_rate are all read by
-- hostapd_common_add_device_config and appended to the radio's base_cfg), even
-- though the controller sends Minimum Data Rate per WLAN. apply_config()
-- therefore aggregates the radio's VAPs down to one setting -- see there.
-- Writes are stamped with an openuf_rates marker; rates == nil on a marked
-- section tears all four options down (the wire signals "control off" by
-- omitting every minrate_* key), while unmarked sections are left alone.
-- disabled: tri-state per-radio enable, from the controller's
-- radio.<n>.status (Radios -> Transmit Power -> Disabled). nil leaves UCI
-- alone -- a blob that never carries the key must not re-enable a radio the
-- user disabled by hand; only an explicit enabled/disabled writes.
-- country: ISO 3166-1 alpha-2 regulatory domain from the controller's site
-- setting (system_cfg's radio.<n>.countrycode, numeric on the wire and mapped
-- to alpha-2 by inform.lua). nil leaves UCI alone.
-- radio_policy: dev.conf.radio, keyed by band ("ng" = 2.4 GHz, "na" = 5/6
-- GHz), from UCI `config radio_policy '<band>'` (config.lua; the UCI list
-- `channel` arrives as `channels`, numbers) or local.json -- board-level
-- answers the controller cannot know:
--   acs_exclude_dfs  with channel Auto, keep ACS off DFS channels (for a
--                    driver that cannot start CAC, where ACS picking a DFS
--                    channel leaves the radio down)
--   channels         explicit ACS candidate list (UCI `channels`)
--   htmode_floor     raise a pushed htmode to at least this (raise_htmode)
--   htmode_max       lower a pushed htmode to at most this (cap_htmode)
-- All absent by default. opts.force_wifi4 suppresses the floor (a WLAN on the
-- radio asked for an 802.11n beacon). opts.country_override programs that
-- regdomain INSTEAD of the controller's, which is stamped as openuf_country
-- and still reported -- see the country_override option.
-- opts.max_sta: the controller's per-radio "Max Clients" / Load balance
-- (stamgr.<n>.loadbalance.*, see wlan.parse). UniFi firmware refuses no
-- association for it: it deauths the most idle station while the radio is
-- over the cap (unifi/loadbalance.lua, enforced in report.lua). So a number
-- is kept in the openUF-only option loadbalance_maxsta and false deletes it;
-- nil leaves UCI alone. Either way a hostapd `maxassoc` an older openUF
-- wrote (stamped openuf_maxassoc) is removed; a hand-set one is kept.
-- opts.acs_exclude (channel numbers) and opts.acs_dfs (boolean, nil = not
-- said) are the controller's Auto inputs: the exclusions come off the
-- candidate list (acs_candidates) and acs_dfs=false sets acs_exclude_dfs,
-- stamped openuf_acs_dfs. Both apply only while the channel is Auto, and the
-- policy's acs_exclude_dfs / channels override them.
function M.rf_config(radio, htmode, chan, txpwr, minrssi_enabled, minrssi_raw, rates,
		disabled, country, radio_policy, opts)
	local uci = get_uci()
	local cursor = uci.cursor()
	-- Every write below is cursor:set on a named section, which in UCI CREATES
	-- that section when it does not exist. A controller naming a phy this
	-- device does not have (a stale device record, a config cloned from
	-- another AP, an emulated model whose radio count differs from the real
	-- hardware's) would therefore materialize a phantom `wifi-device` that no
	-- driver backs -- carried into every later get_radio_table() and reported
	-- to the controller as a real radio. Refuse instead.
	local exists = false
	cursor:foreach("wireless", "wifi-device", function(s)
		if s[".name"] == radio then exists = true end
	end)
	if not exists then
		io.stderr:write(string.format(
			"openuf: rf_config: no wifi-device section %q on this device -- ignoring\n",
			tostring(radio)))
		return false
	end
	if disabled ~= nil then
		cursor:set("wireless", radio, "disabled", disabled and "1" or "0")
	end
	-- The regdomain decides which channels are legal and how much power each
	-- may use, so it has to be written BEFORE the channel and txpower below --
	-- and it invalidates the cached driver capabilities, whose per-channel dBm
	-- limits are regdomain-derived.
	local cc_override = nil
	if type(opts) == "table" and type(opts.country_override) == "string"
			and opts.country_override:match("^%a%a$") then
		cc_override = opts.country_override:upper()
	end
	if cc_override then
		-- Stamp what the controller asked for, so get_radio_table keeps
		-- REPORTING the controller's own value.
		if country and country ~= cc_override then
			cursor:set("wireless", radio, "openuf_country", country)
		elseif country == cc_override and cursor:get("wireless", radio, "openuf_country") then
			-- The site now asks for the override itself: nothing to remember.
			cursor:delete("wireless", radio, "openuf_country")
		end
		if cc_override ~= cursor:get("wireless", radio, "country") then
			io.stderr:write(string.format(
				"openuf: %s: regdomain override -- programming %s into the driver, " ..
				"reporting %s to the controller\n", radio, cc_override,
				tostring(country or cursor:get("wireless", radio, "openuf_country")
					or cc_override)))
			cursor:set("wireless", radio, "country", cc_override)
			regdomain_changed()
		end
	else
		-- No override (or it was removed): the controller's value goes back.
		if cursor:get("wireless", radio, "openuf_country") then
			country = country or cursor:get("wireless", radio, "openuf_country")
			cursor:delete("wireless", radio, "openuf_country")
			regdomain_changed()
		end
		if country and country ~= cursor:get("wireless", radio, "country") then
			cursor:set("wireless", radio, "country", country)
			regdomain_changed()
		end
	end
	if chan then
		cursor:set("wireless", radio, "channel", tostring(chan))
	end
	-- The radio's band comes from its own UCI declaration, not from the
	-- channel being pushed alongside: a radio's band is fixed by hardware,
	-- and `chan` can be the literal "auto".
	local band = band_for_device({
		band    = cursor:get("wireless", radio, "band"),
		hwmode  = cursor:get("wireless", radio, "hwmode"),
		channel = cursor:get("wireless", radio, "channel") or chan,
	})
	local policy = (type(radio_policy) == "table" and band and radio_policy[band]) or nil
	-- What "Auto" means on this board, read back from UCI so a push without a
	-- channel still gets the policy applied to the auto already configured.
	-- A concrete channel drops both options: they are ACS inputs only, and
	-- left behind they would come back with the next Auto.
	local eff_chan = tostring(cursor:get("wireless", radio, "channel"))
	local auto = (eff_chan == "auto" or eff_chan == "0")
	-- The controller's Auto inputs (opts.acs_exclude / opts.acs_dfs, from the
	-- site's Radio AI exclusions and DFS switch). The board policy is an
	-- operator override and wins over both: a driver that cannot run CAC
	-- stays off DFS whatever the site says, and a policy channel list is
	-- used as written.
	local acs_exclude = type(opts) == "table" and opts.acs_exclude or nil
	local acs_dfs = nil
	if type(opts) == "table" then acs_dfs = opts.acs_dfs end
	local excl_dfs = nil
	if policy and policy.acs_exclude_dfs ~= nil then
		excl_dfs = policy.acs_exclude_dfs and true or false
	elseif acs_dfs ~= nil then
		excl_dfs = not acs_dfs
	end
	-- A band with a policy entry owns acs_exclude_dfs; without one openUF
	-- removes only a value it stamped itself, so a hand-set option survives
	-- a site that allows DFS.
	local dfs_stamped = cursor:get("wireless", radio, "openuf_acs_dfs") ~= nil
	if auto and excl_dfs then
		if policy then
			cursor:set("wireless", radio, "acs_exclude_dfs", "1")
		elseif dfs_stamped or cursor:get("wireless", radio, "acs_exclude_dfs") ~= "1" then
			cursor:set("wireless", radio, "acs_exclude_dfs", "1")
			cursor:set("wireless", radio, "openuf_acs_dfs", "1")
		end
	elseif policy or dfs_stamped then
		cursor:delete("wireless", radio, "acs_exclude_dfs")
		cursor:delete("wireless", radio, "openuf_acs_dfs")
	end
	-- 2.4 GHz Auto: UniFi's own auto-channel plan is 1/6/11 (the site's radio
	-- settings list exactly those), and plenty of clients cannot use 12/13 at
	-- all. Left to itself hostapd's ACS picked channel 13 on a UK E8450 and
	-- the radio's clients never came back. A board policy's list still wins.
	local list = nil
	if auto and policy and type(policy.channels) == "table" and #policy.channels > 0 then
		list = {}
		for _, c in ipairs(policy.channels) do list[#list + 1] = tostring(c) end
		if acs_exclude then
			io.stderr:write(string.format(
				"openuf: %s: the board's channel list overrides the controller's exclusions\n",
				radio))
		end
	elseif auto and (band == "ng" or acs_exclude) and not (cursor:get("wireless", radio, "channels")
			and not cursor:get("wireless", radio, "openuf_channels")) then
		-- A list openUF did not write is the operator's and is left alone,
		-- on either band.
		list = M.acs_candidates(band == "ng" and {1, 6, 11} or nil, acs_exclude)
	end
	if list then
		cursor:set("wireless", radio, "channels", list)
		cursor:set("wireless", radio, "openuf_channels", "1")
	elseif policy or cursor:get("wireless", radio, "openuf_channels") then
		cursor:delete("wireless", radio, "channels")
		cursor:delete("wireless", radio, "openuf_channels")
	end
	if htmode then
		local want = htmode
		local force_wifi4 = (type(opts) == "table" and opts.force_wifi4) or false
		if policy and policy.htmode_floor and not force_wifi4 then
			local raised, from = M.raise_htmode(want, policy.htmode_floor)
			if from then
				io.stderr:write(string.format(
					"openuf: %s: controller asked for htmode %s, board floor is %s -- raised to %s\n",
					radio, from, policy.htmode_floor, raised))
			end
			want = raised
		end
		if policy and policy.htmode_max then
			local capped, from = M.cap_htmode(want, policy.htmode_max)
			if from then
				io.stderr:write(string.format(
					"openuf: %s: htmode %s exceeds the board ceiling %s -- lowered to %s\n",
					radio, from, policy.htmode_max, capped))
			end
			want = capped
		end
		-- The hardware clamp runs last, so neither a floor nor a push can ask
		-- for more than the radio really has.
		local clamped, requested = M.clamp_htmode(band, want)
		if requested then
			io.stderr:write(string.format(
				"openuf: %s: controller asked for htmode %s, hardware supports %s -- clamped\n",
				radio, requested, clamped))
		end
		cursor:set("wireless", radio, "htmode", clamped)
	end
	if txpwr == "auto" then
		-- UCI has no auto txpower value: absent option = driver default/max.
		-- Deleting is what makes "Transmit Power: Auto" actually revert a
		-- previously pushed fixed dBm instead of stranding it.
		cursor:delete("wireless", radio, "txpower")
	elseif txpwr then
		cursor:set("wireless", radio, "txpower", tostring(txpwr))
	end
	if minrssi_enabled ~= nil then
		cursor:set("wireless", radio, "minrssi_enabled", minrssi_enabled and "1" or "0")
	end
	if minrssi_raw then
		cursor:set("wireless", radio, "minrssi_rssi", tostring(minrssi_raw))
	end
	-- Minimum RSSI's refusal (openwrt/minrssi.lua): the firmware's driver
	-- answers no probe and no authentication below the threshold + 3 dB;
	-- hostapd's equivalents are wifi-device options. Computed from the same
	-- stored threshold the kick reads back, so the two halves never disagree.
	local mr = get_minrssi()
	local raw = tonumber(minrssi_raw or cursor:get("wireless", radio, "minrssi_rssi"))
	if minrssi_enabled and raw and mr then
		local refuse = tostring(mr.dbm(raw) + mr.REFUSE_MARGIN)
		cursor:set("wireless", radio, "rssi_reject_assoc_rssi", refuse)
		cursor:set("wireless", radio, "rssi_ignore_probe_request", refuse)
		cursor:set("wireless", radio, "openuf_minrssi", "1")
	elseif minrssi_enabled ~= nil and cursor:get("wireless", radio, "openuf_minrssi") == "1" then
		-- Off: remove exactly what the stamp says openUF wrote. Hand-set
		-- values on an unstamped radio are never touched.
		for _, opt in ipairs({"rssi_reject_assoc_rssi", "rssi_ignore_probe_request",
				"openuf_minrssi"}) do
			cursor:delete("wireless", radio, opt)
		end
	end
	-- Not `type(opts) == "table" and opts.max_sta`: without opts that is
	-- false, which would read as "limit off".
	local max_sta = nil
	if type(opts) == "table" then max_sta = opts.max_sta end
	if type(max_sta) == "number" then
		cursor:set("wireless", radio, "loadbalance_maxsta", tostring(max_sta))
	elseif max_sta == false then
		cursor:delete("wireless", radio, "loadbalance_maxsta")
	end
	if max_sta ~= nil and cursor:get("wireless", radio, "openuf_maxassoc") == "1" then
		cursor:delete("wireless", radio, "maxassoc")
		cursor:delete("wireless", radio, "openuf_maxassoc")
	end
	if rates then
		-- Stamp the sections we rate-manage: "Minimum Data Rate off" arrives
		-- as the minrate_* keys simply vanishing from the wire, which is
		-- indistinguishable from "never managed / user hand-tuned basic_rate"
		-- without a ledger. The marker (same template as set_wlan_exclusive's
		-- openuf_autodisabled stamp) confines the teardown below to options
		-- openUF itself wrote.
		cursor:set("wireless", radio, "openuf_rates", "1")
		-- cell_density is OpenWrt's other rate control, and the two do not
		-- compose: density 2 left supported_rates at 11 Mbps and up while the
		-- pushed floor made basic_rate 1 Mbps -- a basic rate outside the
		-- supported set, which hostapd refuses outright ("Failed to prepare
		-- rates table"), taking every SSID on the radio down. Seen on a live
		-- E8450. While the controller owns the rates, density is off; the
		-- board's value is kept in openuf_cell_density and put back below.
		local density = cursor:get("wireless", radio, "cell_density")
		if density and density ~= "0" then
			if not cursor:get("wireless", radio, "openuf_cell_density") then
				cursor:set("wireless", radio, "openuf_cell_density", density)
			end
			cursor:set("wireless", radio, "cell_density", "0")
		end
		-- basic_rate/supported_rates are UCI *list* options carrying kb/s
		-- values; OpenWrt divides each by 100 itself (hostapd_add_rate) to
		-- reach hostapd's 100-kbps units, so they are set in kb/s as received.
		-- Each absent field is DELETED, not skipped: supported_rates and
		-- beacon_rate can legitimately drop out while the feature stays on
		-- (the drop-below/beacon sub-toggles), and a skip would strand the
		-- previous stricter push.
		if rates.basic_rate then
			cursor:set("wireless", radio, "basic_rate", rates.basic_rate)
		else
			cursor:delete("wireless", radio, "basic_rate")
		end
		if rates.supported_rates then
			cursor:set("wireless", radio, "supported_rates", rates.supported_rates)
		else
			cursor:delete("wireless", radio, "supported_rates")
		end
		if rates.legacy_rates then
			cursor:set("wireless", radio, "legacy_rates", rates.legacy_rates)
		else
			cursor:delete("wireless", radio, "legacy_rates")
		end
		-- beacon_rate is only written where the driver can actually program it.
		-- hostapd does not degrade gracefully here: on a driver without
		-- NL80211_EXT_FEATURE_BEACON_RATE_LEGACY it logs
		--   nl80211: Driver does not support setting Beacon frame rate (legacy)
		--   Failed to set beacon parameters / Interface initialization failed
		-- and the radio never comes up at all -- one unsupported option takes
		-- the whole band off the air. Confirmed on a real Archer C5 v1: its
		-- ath9k 2.4GHz radio died on exactly this while the ath10k 5GHz radio
		-- (which the controller sent no beacon_rate for) came up fine.
		local band_caps = M.phy_caps()[band_for_device({
			band    = cursor:get("wireless", radio, "band"),
			hwmode  = cursor:get("wireless", radio, "hwmode"),
			channel = cursor:get("wireless", radio, "channel"),
		})]
		-- Unknown capability (no iw, unparseable output) writes the option:
		-- the honest default is to do what the controller asked, as before.
		local beacon_ok = (band_caps == nil) or band_caps.beacon_rate
		if rates.beacon_rate and beacon_ok then
			-- beacon_rate is the exception among these options: OpenWrt appends
			-- it to the hostapd config verbatim, with NO /100 conversion, and
			-- hostapd documents its beacon_rate as a legacy rate in 100-kbps
			-- units. So this one -- unlike basic_rate/supported_rates above --
			-- has to be converted here, or a 12000 kb/s floor would ask for
			-- 1.2 Gbps.
			cursor:set("wireless", radio, "beacon_rate",
				tostring(math.floor(rates.beacon_rate / 100)))
		else
			if rates.beacon_rate then
				io.stderr:write(string.format(
					"openuf: %s: driver cannot set a beacon rate -- skipping " ..
					"beacon_rate=%s (hostapd would refuse to start the radio)\n",
					radio, tostring(rates.beacon_rate)))
			end
			cursor:delete("wireless", radio, "beacon_rate")
		end
	elseif cursor:get("wireless", radio, "openuf_rates") == "1" then
		-- Minimum Data Rate reverted to off: no VAP on this radio carries a
		-- floor anymore, so tear down exactly the options the marker says we
		-- wrote. Without this, the old basic_rate/supported_rates kept
		-- excluding slow clients forever after the control was turned off.
		-- Hand-tuned rate options on unmarked sections are never touched.
		for _, opt in ipairs({"basic_rate", "supported_rates", "legacy_rates",
				"beacon_rate", "openuf_rates"}) do
			cursor:delete("wireless", radio, opt)
		end
		local density = cursor:get("wireless", radio, "openuf_cell_density")
		if density then
			cursor:set("wireless", radio, "cell_density", density)
			cursor:delete("wireless", radio, "openuf_cell_density")
		end
	end
	cursor:commit("wireless")
	return true
end

-- 802.11d country IE for one radio, from the WLANs' aaa.<n>.country_beacon
-- (apply_config folds them per radio). want: true/false, or nil when no WLAN
-- on the radio carries the key.
--
-- Written as `country_ie`, the alias both stacks know: 25.12's validator maps
-- it onto the wifi-device option ieee80211d (schema default true, emitted by
-- hostapd.uc only with a country set), hostapd.sh reads it as is. The board's
-- own value is kept in openuf_country_ie ("none" when it had none) and put
-- back once no WLAN carries the key, the cell_density pattern.
--
-- Off is honoured on 2.4 GHz only, unless the radio has 802.11h switched off:
-- hostapd refuses a config with ieee80211h=1 and no ieee80211d ("Cannot enable
-- IEEE 802.11h without IEEE 802.11d enabled", checked against 25.12.0's wpad),
-- hostapd.uc keeps ieee80211h on every hw_mode=a radio (5 and 6 GHz), and its
-- schema default is on. Writing off there would take the radio off the air.
function M.country_ie_config(radio, want)
	local cursor = get_uci().cursor()
	if cursor:get("wireless", radio) ~= "wifi-device" then return false end
	local band = band_for_device({
		band    = cursor:get("wireless", radio, "band"),
		hwmode  = cursor:get("wireless", radio, "hwmode"),
		channel = cursor:get("wireless", radio, "channel"),
	})
	local value
	if want == true then
		value = "1"
	elseif want == false then
		-- doth is ieee80211h's alias and wins over it, as in the validator.
		local doth = cursor:get("wireless", radio, "doth")
		if doth == nil then doth = cursor:get("wireless", radio, "ieee80211h") end
		if band == "ng" or doth == "0" then
			value = "0"
		else
			io.stderr:write(string.format(
				"openuf: %s: the controller turned 802.11d off, but 802.11h (DFS) " ..
				"needs it on this band -- keeping the country IE\n", radio))
		end
	end
	local stamp = cursor:get("wireless", radio, "openuf_country_ie")
	if value then
		if not stamp then
			cursor:set("wireless", radio, "openuf_country_ie",
				cursor:get("wireless", radio, "country_ie") or "none")
		end
		cursor:set("wireless", radio, "country_ie", value)
	elseif stamp then
		if stamp == "none" then
			cursor:delete("wireless", radio, "country_ie")
		else
			cursor:set("wireless", radio, "country_ie", stamp)
		end
		cursor:delete("wireless", radio, "openuf_country_ie")
	else
		return true
	end
	cursor:commit("wireless")
	return true
end

-- ─── Config apply ────────────────────────────────────────────────────────────

-- Apply a full config payload from the controller.
-- resp: decoded JSON table from the controller's inform response.
-- cfg:  device configuration (config.lua); used for dev.conf.net.lan_cpueth
--       when a VAP requires a VLAN-tagged network. VLAN tagging is skipped
--       (falls back to "lan") if cfg is nil.
-- opts: optional table; opts.keep_vlans is a set of VLAN ids that must keep
--       their L2 even when no WLAN sits on them -- a wired port assigned to
--       that VLAN on a DSA board lives in the same bridge. opts.band_steering_active (boolean) forces 802.11k +
--       BSS Transition on for every managed iface regardless of each WLAN's
--       own bss_transition setting, since usteer (Band Steering) needs it
--       network-wide to function at all -- see src/openwrt/usteer.lua. nil/false
--       leaves each vap's own setting in effect. opts.roam_assist_active
--       (boolean) forces the same, for Roaming Assistant. opts.device_name is the
--       controller-assigned device name, used as the WPS Device Name value
--       when a vap has advertise_ap_name enabled ("Show Access Point Name in
--       Beacon"); defaults to "openUF" if nil. opts.peer_ie is the
--       vendor_elements hex every VAP beacons so sibling openUF APs can tell
--       it is not a rogue (sysinfo.peer_ie_hex); nil removes it.
-- Drive the Multicast and Broadcast Blocker from one normalized list of
-- {ifname, bcfilt_enabled, bcfilt_macs} entries, so the setparam path and the
-- startup reapply below cannot drift apart.
--
-- Reconciled unconditionally, even with an empty list: it rebuilds from
-- scratch rather than diffing, so turning the control off in the controller
-- tears the previous ruleset down instead of leaving it in place -- the same
-- contract firewall.lua keeps. (WiFi Speed Limit is per client, so it needs
-- the stations: inform's _shaper_resync applies it every heartbeat from the
-- openuf_ratelimit_* stamps, see shaper.lua.)
local function reconcile_runtime(entries)
	local bcfilter = get_bcfilter()
	if bcfilter then
		local rules = {}
		for _, e in ipairs(entries) do
			-- The blocker, with Aggressive's exemptions when the Multicast
			-- Suppressor sent bypass types; Conservative is the storm limiter,
			-- alone or next to a blocker the WLAN also has on.
			local storm = e.mcast_suppressor == "conservative"
			if e.bcfilt_enabled or storm then
				rules[#rules + 1] = {ifname = e.ifname, macs = e.bcfilt_macs or {},
					block = e.bcfilt_enabled == true, bypass = e.bcfilt_bypass,
					storm = storm or nil}
			end
		end
		bcfilter.reconcile(rules)
	end
end

-- Handles vap_table and radio_table from the setparam/config response.
function M.apply_config(resp, cfg, opts)
	local radio_table   = resp.radio_table   or {}
	local vap_table     = resp.vap_table     or {}
	local cpueth = cfg and cfg.net and cfg.net.lan_cpueth

	-- "Minimum Data Rate" arrives per WLAN but OpenWrt's rate options are
	-- per radio, so every VAP sharing a radio has to collapse to one setting.
	-- The aggregate is deliberately the most PERMISSIVE of them: the lowest
	-- floor, CCK still allowed if any WLAN allows it, and lower rates only
	-- dropped from the advertised set if every WLAN asked for that. Erring
	-- the other way would apply one WLAN's stricter floor to a co-hosted WLAN
	-- and lock out clients the controller fully intended to admit -- a
	-- silent, on-air-only failure. VAPs with no floor (the key is absent
	-- whenever that band's control is off) contribute nothing.
	-- "Force WiFi 4 Mode" is per WLAN but htmode is per radio: a radio carrying
	-- any such WLAN is never raised by a board htmode_floor (rf_config).
	local iot_by_radio = {}
	for _, vap in ipairs(vap_table) do
		local rn = vap.radio or vap.radio_name
		if vap.iot and rn then iot_by_radio[rn] = true end
	end

	local rates_by_radio = {}
	for _, vap in ipairs(vap_table) do
		if vap.radio and vap.minrate_data then
			local agg = rates_by_radio[vap.radio]
			if not agg then
				-- drop_below is `== true`, not `~= false`: an absent
				-- minrate_below_disable key must count as permissive (don't
				-- trim the advertised set), matching both the most-permissive
				-- contract above and the `if not ...` fold below -- the old
				-- `~= false` made a single VAP with the key absent STRICT,
				-- and flipped to permissive when a second identical VAP
				-- appeared.
				agg = {floor = vap.minrate_data, allow_cck = vap.minrate_cck,
					drop_below = vap.minrate_below_disable == true,
					beacon_rate = vap.beacon_rate}
				rates_by_radio[vap.radio] = agg
			else
				if vap.minrate_data < agg.floor then
					agg.floor = vap.minrate_data
					agg.beacon_rate = vap.beacon_rate
				end
				if vap.minrate_cck ~= false then agg.allow_cck = true end
				if not vap.minrate_below_disable then agg.drop_below = false end
			end
		end
	end

	-- 802.11d (aaa.<n>.country_beacon) arrives per WLAN, but the country IE
	-- is per radio in OpenWrt and hostapd. Same most-permissive fold as the
	-- rates above: on if any enabled WLAN on the radio wants it, off only if
	-- every one carrying the key says off, untouched if none does.
	local country_ie_by_radio = {}
	for _, vap in ipairs(vap_table) do
		if vap.radio and vap.country_beacon ~= nil and vap.disabled ~= true then
			country_ie_by_radio[vap.radio] = country_ie_by_radio[vap.radio]
				or vap.country_beacon
		end
	end

	-- Apply radio parameters
	for _, radio in ipairs(radio_table) do
		if radio.name then
			M.country_ie_config(radio.name, country_ie_by_radio[radio.name])
			local rates
			local agg = rates_by_radio[radio.name]
			if agg then
				local cur = get_uci().cursor()
				local band = band_for_device({
					band    = cur:get("wireless", radio.name, "band"),
					hwmode  = cur:get("wireless", radio.name, "hwmode"),
					channel = cur:get("wireless", radio.name, "channel") or radio.channel,
				})
				rates = M.derive_rates(agg.floor, agg.allow_cck, agg.drop_below, band == "ng")
				if rates then rates.beacon_rate = agg.beacon_rate end
			end
			M.rf_config(radio.name, radio.htmode, radio.channel, radio.tx_power,
				radio.min_rssi_enabled, radio.min_rssi, rates, radio.disabled,
				radio.country, cfg and cfg.radio,
				{force_wifi4 = iot_by_radio[radio.name] or false,
				 max_sta = radio.max_sta,
				 country_override = cfg and cfg.config and cfg.config.country_override or nil,
				 acs_exclude = radio.acs_exclude, acs_dfs = radio.acs_dfs})
		end
	end

	-- Clear existing openuf_ VAPs and re-add from vap_table
	M.wlan_clear()
	-- Every VLAN this push still wants an L2 for; anything else gets pruned
	-- after the loop.
	local wanted_vlans = {}
	-- The MAC-based VLAN lists this push writes; any other is removed after.
	local macvlan_files = {}
	-- Section names already written: two WLANs that map to one name on a
	-- radio (the same SSID twice, or a hash collision of altered names) would
	-- overwrite each other in silence. The first stays; the second is
	-- skipped, and said so.
	local taken = {}
	for _, vap in ipairs(vap_table) do
		local skip = false
		if vap.ssid and vap.radio then
			local sname0 = M.section_name(vap.radio, vap.ssid)
			if taken[sname0] then
				io.stderr:write(("ucihelper: WLAN %q on %s maps to section %s, which another WLAN "
					.. "already has -- not provisioned\n"):format(tostring(vap.ssid), tostring(vap.radio), sname0))
				skip = true
			end
			taken[sname0] = true
		end
		if vap.ssid and vap.radio and not skip then
			local extra = {}
			-- Per-VAP enable, from the controller's wireless.<n>.status. A
			-- disabled WLAN is still provisioned, just with disabled=1, so its
			-- whole config survives a re-enable. These sections are openUF's
			-- own and are rebuilt by wlan_clear() on every push, so there is no
			-- stale state to strand and no need for the autodisabled stamp
			-- set_wlan_exclusive() uses for the user's sections.
			if vap.disabled ~= nil then
				extra.disabled = vap.disabled and "1" or "0"
			end
			-- The controller carries two independent FT toggles: ft.status
			-- for the WLAN and wpa3.ft.status for the SAE akm alone (the
			-- latter only on SAE pushes, so nil elsewhere). OpenWrt cannot
			-- express the split -- one ieee80211r switch feeds hostapd's
			-- key_mgmt, and on sae-mixed it yields FT-PSK *and* FT-SAE
			-- together. So enable FT if either toggle asks for it: that
			-- honours every explicit "enabled" and never silently drops a
			-- capability the controller requested. Warn when they disagree,
			-- because the extra akm is ours, not the controller's.
			local ft_enabled = vap.fast_roaming_enabled
			if vap.wpa3_fast_roaming_enabled ~= nil
				and vap.wpa3_fast_roaming_enabled ~= (vap.fast_roaming_enabled or false) then
				ft_enabled = true
				io.stderr:write(string.format(
					"openuf: %s: ft.status=%s but wpa3.ft.status=%s -- OpenWrt cannot "
						.. "enable 802.11r for one akm only, enabling it for both\n",
					tostring(vap.ssid),
					vap.fast_roaming_enabled and "enabled" or "disabled",
					vap.wpa3_fast_roaming_enabled and "enabled" or "disabled"))
			end
			if ft_enabled then
				extra.ieee80211r = "1"
				extra.mobility_domain = M.derive_mobility_domain(vap.ssid)
				extra.ft_over_ds = "0"
				-- ft_psk_generate_local is deliberately NOT set. It used to be
				-- forced to "1", which silently disabled fast roaming for every
				-- WPA3 client: local key generation is FT-PSK only (each AP
				-- derives PMK-R0/R1 from the PSK it already has), while FT-SAE
				-- derives PMK-R0 from the per-session SAE PMK, which no
				-- passphrase can reproduce. Its PMK-R1 has to be pulled from
				-- the originating AP over the r0kh/r1kh key-holder
				-- relationship -- and forcing local generation is exactly what
				-- stops OpenWrt configuring one.
				--
				-- Observed live on a sae-mixed WLAN: both APs advertised
				-- FT-SAE and the mobility domain correctly, and a station that
				-- had negotiated FT-SAE still reassociated with auth_alg=sae
				-- plus a full EAPOL 4-way -- a fast transition shows
				-- auth_alg=ft and no 4-way at all. It failed even roaming
				-- between two BSSes on the SAME radio, so this was never about
				-- the APs failing to reach each other.
				--
				-- OpenWrt's own default is already right, and better than
				-- anything worth restating here: hostapd.sh keys it on
				-- auth_type (psk -> 1, anything else -> 0) and, when it is 0,
				-- auto-derives wildcard key holders from
				-- md5(mobility_domain .. "/" .. psk) -- deterministic, so every
				-- AP sharing an SSID and passphrase computes the same key with
				-- no coordination, which is the same reasoning behind
				-- derive_mobility_domain above. Leaving the option unset lets
				-- that run: FT-PSK keeps local derivation and needs no
				-- inter-AP traffic, FT-SAE gets the key holders it cannot work
				-- without.
				--
				-- The key-holder secret is the controller's when it sends one:
				-- aaa.<n>.iapp_key, 128 random bits per WLAN, the same key
				-- UniFi firmware wraps its own inter-AP FT frames with. The
				-- wildcard forms are the ones OpenWrt itself generates, so any
				-- openUF AP on the WLAN is accepted as a peer. Without the key
				-- OpenWrt's md5 derivation applies, which anyone who knows the
				-- passphrase can compute. OpenWrt reads the lists only when
				-- ft_psk_generate_local is 0 (not FT-PSK).
				if vap.iapp_key then
					extra.r0kh = { "ff:ff:ff:ff:ff:ff,*," .. vap.iapp_key }
					extra.r1kh = { "00:00:00:00:00:00,00:00:00:00:00:00," .. vap.iapp_key }
				end
				-- UniFi firmware's hostapd template (4.0.15): push PMK-R1 to
				-- the key holders, and a 3000 TU reassociation deadline
				-- (OpenWrt's defaults are 0 and 20000). OpenWrt writes
				-- pmk_r1_push only on the key-holder path (FT-SAE/EAP).
				extra.pmk_r1_push = "1"
				extra.reassociation_deadline = "3000"
			end
			if opts and (opts.band_steering_active or opts.roam_assist_active) then
				-- usteer requires 802.11k (neighbor reports) + BSS
				-- Transition on every managed iface network-wide to
				-- function at all -- confirmed via the OpenWrt wiki's
				-- usteer setup guide. This overrides each WLAN's own
				-- bss_transition/ieee80211k value while device-wide Band
				-- Steering is on, since usteer can't be scoped to a
				-- single SSID. Roaming Assistant needs the same: usteer
				-- running on every iface for its cross-AP view, and
				-- bss_transition for hostapd's bss_transition_request.
				extra.ieee80211k          = "1"
				extra.bss_transition      = "1"
				extra.rrm_neighbor_report = "1"
				extra.rrm_beacon_report   = "1"
				extra.wnm_sleep_mode      = "1"
			else
				if vap.bss_transition ~= nil then
					extra.bss_transition = vap.bss_transition and "1" or "0"
				end
				-- The WLAN's own 802.11k (aaa.<n>.11k.status). Only here, in
				-- the branch above's absence: Band Steering and Roaming
				-- Assistant need it on regardless. ap.uc derives
				-- rrm_neighbor_report/rrm_beacon_report from it.
				if vap.rrm_enabled ~= nil then
					extra.ieee80211k = vap.rrm_enabled and "1" or "0"
				end
			end
			-- Per-BSS knobs with a 1:1 wifi-iface option (schema, ap.uc
			-- append_vars and hostapd.sh all checked on 25.12.0). Absent on
			-- the wire -> option absent -> OpenWrt's default; these sections
			-- are rebuilt on every push, so nothing outlives the key.
			if vap.group_rekey then
				extra.wpa_group_rekey = tostring(vap.group_rekey)
			end
			if vap.tdls_prohibit ~= nil then
				extra.tdls_prohibit = vap.tdls_prohibit and "1" or "0"
			end
			if vap.uapsd ~= nil then
				-- `uapsd` is the alias both stacks know: 25.12's validator maps
				-- it onto uapsd_advertisement_enabled, hostapd.sh reads it as is.
				extra.uapsd = vap.uapsd and "1" or "0"
			end
			if vap.dtim_period then extra.dtim_period = vap.dtim_period end
			if vap.qbssload ~= nil then
				-- "Force WiFi 4 Mode" (IoT Optimization) sends
				-- wireless.<n>.qbssload=disabled alongside iot=enabled. The
				-- QBSS Load element is emitted by hostapd whenever
				-- bss_load_update_period is non-zero (it is the element's
				-- refresh interval, in beacon intervals); 0 suppresses the
				-- element entirely, which is what the controller is asking
				-- for. 60 is hostapd's own conventional enabled value.
				extra.bss_load_update_period = vap.qbssload and "60" or "0"
			end
			if vap.iot then
				-- Recorded so the applied WiFi-4-compat state is visible in
				-- UCI (and in tests) rather than being invisible. There is
				-- deliberately no radio-level action here: the controller
				-- keeps the shared radio at its configured width, and the
				-- rest of the mode's behavior arrives as the ordinary keys
				-- handled above and below (2.4GHz-only vap placement, WPA2,
				-- PMF/BSS-transition/proxy-ARP/band-steering off). See
				-- inform.lua's parse-side comment for the live evidence.
				extra.openuf_iot = "1"
			end
			if vap.pmf_status ~= nil then
				-- 802.11w PMF. ieee80211w: 0=disabled, 1=optional, 2=required
				-- (hostapd's own option, madwifi/mac80211 alike). The
				-- controller signals this via aaa.<n>.pmf.status+pmf.mode; a
				-- disabled block is mode 0. Written explicitly for both
				-- enabled and disabled so the applied value always reflects
				-- the controller's intent (a WPA2-only WLAN gets an explicit
				-- ieee80211w=0, a WPA2/WPA3 mixed WLAN gets 1/2).
				local w = 0
				if vap.pmf_status == "enabled" then w = vap.pmf_mode or 1 end
				extra.ieee80211w = tostring(w)
			end
			if vap.owe_transition then
				-- Enhanced Open transition mode: the ucode generator (25.12,
				-- hostapd.uc/ap.uc) turns this one section into the hidden OWE
				-- BSS plus an open BSS under the section's SSID, each pointing
				-- at the other. The controller sends the same pair as two
				-- VAPs; unifi/wlan.lua keeps the open one only. Absent
				-- otherwise: wlan_clear drops the section on every rebuild.
				extra.owe_transition = "1"
			end
			if vap.mcast_enhance ~= nil then
				-- Multicast Enhancement: multicast_to_unicast is the
				-- OpenWrt/mac80211 wifi-iface option that proxies multicast
				-- frames as unicast at the AP (the mechanism UniFi's
				-- "Multicast Enhancement" / "Multicast to Unicast" provides).
				-- Written explicitly on/off, mirroring bss_transition.
				extra.multicast_to_unicast = vap.mcast_enhance and "1" or "0"
			end
			if vap.proxy_arp ~= nil then
				-- "Proxy ARP": the AP answers ARP (and IPv6 ND) on behalf of
				-- associated stations instead of flooding the request over the
				-- air, so sleeping clients aren't woken by every broadcast ARP.
				-- proxy_arp is hostapd's own option name and OpenWrt exposes it
				-- verbatim as a wifi-iface boolean (confirmed in OpenWrt's
				-- hostapd.sh: declared in hostapd_common_add_bss_config and
				-- emitted as "proxy_arp=1" into the per-BSS config). Like
				-- bss_transition it needs a full wpad build -- hostapd only
				-- compiles proxy_arp support in with CONFIG_PROXYARP, which the
				-- -mini/-basic wpad variants leave out. Written explicitly on
				-- and off, mirroring bss_transition/mcast_enhance.
				extra.proxy_arp = vap.proxy_arp and "1" or "0"
			end
			if vap.roam_assist_enabled then
				-- "Roaming Assistant" threshold in dBm, read back by
				-- get_vap_table for openwrt/roamassist.lua. Absent means off:
				-- wlan_clear drops the whole section before every rebuild,
				-- so switching it off in the controller leaves nothing behind.
				extra.openuf_roam_assist = tostring(vap.roam_assist_rssi or -75)
			end
			if vap.bcfilt_enabled ~= nil then
				-- "Multicast and Broadcast Blocker". Recorded on the section so
				-- the configured state is visible in `uci show` and survives to
				-- be re-derived later; the actual enforcement is nftables, done
				-- after the wifi reload below (see bcfilter.lua for why hostapd
				-- cannot express it).
				extra.openuf_bcfilt = vap.bcfilt_enabled and "1" or "0"
				if vap.bcfilt_macs and #vap.bcfilt_macs > 0 then
					extra.openuf_bcfilt_macs = table.concat(vap.bcfilt_macs, " ")
				end
			end
			-- Multicast Suppressor, the same way: a record on the section, the
			-- nftables rules after the reload (bcfilter.lua), and the startup
			-- rebuild reads it back (reapply_runtime_rules).
			if vap.mcast_suppressor then
				extra.openuf_mcast_suppressor = vap.mcast_suppressor
			end
			if vap.bcfilt_bypass and #vap.bcfilt_bypass > 0 then
				extra.openuf_bcfilt_bypass = table.concat(vap.bcfilt_bypass, " ")
			end
			-- WLAN Schedule (openwrt/wlansched.lua). The schedule rides on the
			-- section itself, so the once-a-minute check needs nothing else
			-- and a restart resumes it; the section starts in the state the
			-- schedule has right now. A WLAN the controller disabled stays
			-- disabled whatever the schedule says.
			if vap.schedule then
				extra.openuf_schedule = schedule_mod.encode(vap.schedule)
				local t = M._date()
				-- Not before the clock is set: the tick takes over once it is.
				if vap.disabled ~= true and schedule_mod.sane_clock(M._now())
						and not schedule_mod.is_on(vap.schedule, t.wday, t.hour * 60 + t.min) then
					extra.disabled = "1"
					extra.openuf_sched_off = "1"
				end
			end
			if vap.l2_isolation ~= nil then
				-- "Client Isolation": drop station-to-station frames inside the
				-- BSS. OpenWrt's wifi-iface option is spelled "isolate" (it maps
				-- to hostapd's ap_isolate) -- confirmed in hostapd.sh's
				-- hostapd_common_add_bss_config declaration list.
				extra.isolate = vap.l2_isolation and "1" or "0"
			end
			-- Sibling-AP recognition: the vendor element that tells the other
			-- openUF APs' scans this BSS is ours (see sysinfo.peer_ie_hex --
			-- without it the controller lists it as a rogue impersonating the
			-- network). Removed when the identity MAC is unknown rather than
			-- left announcing a stale one.
			extra.vendor_elements = (opts and opts.peer_ie) or M.DELETE
			if vap.hide_ssid ~= nil then
				-- "Hide WiFi Name": leave the SSID out of beacons (clients must
				-- know the name to associate). OpenWrt's wifi-iface option is
				-- spelled "hidden" and maps to hostapd's
				-- ignore_broadcast_ssid -- confirmed in hostapd.sh's
				-- hostapd_common_add_bss_config declaration list. Written
				-- explicitly on and off, since the controller always sends the
				-- key and un-hiding has to actually take effect.
				extra.hidden = vap.hide_ssid and "1" or "0"
			end
			-- "MAC Address Filter". OpenWrt's wifi-iface option is macfilter
			-- plus a maclist list, and the policy vocabulary lines up 1:1 with
			-- the controller's: allow = maclist is a whitelist, deny =
			-- blacklist.
			--
			-- "Off" is the ABSENCE of the option, not macfilter="disable".
			-- OpenWrt's own schema (/usr/share/schema/wireless.wifi-iface.json)
			-- declares macfilter as enum ["allow","deny"], and 25.12's ucode
			-- validator does not merely ignore an out-of-enum value -- it
			-- aborts the whole radio setup with die(), so BOTH radios come up
			-- with no interfaces at all and not one SSID reaches the air:
			--   wifi-scripts: macfilter: disable has to be one of [ "allow", "deny" ]
			--   netifd: radio0 (4179): Died
			-- Confirmed on a real Archer C5 v1 running OpenWrt 25.12.5, where
			-- this alone sank an otherwise perfect config push. Deleting is
			-- also what actually lifts a previously pushed filter: ap.uc's
			-- iface_macfilter() emits accept_mac_file/deny_mac_file only for
			-- the two enum values and returns for anything else.
			if vap.mac_filter_policy then
				extra.macfilter = vap.mac_filter_policy
				extra.maclist   = vap.mac_filter_list or {}
			else
				extra.macfilter = M.DELETE
				extra.maclist   = M.DELETE
			end
			-- "WiFi Speed Limit", kbps as pushed. Read back by get_vap_table
			-- for inform's _shaper_resync, which enforces it per client with
			-- tc (shaper.lua: no hostapd or OpenWrt option expresses it).
			-- Absent means no limit: wlan_clear drops the section first.
			if vap.ratelimit_down_kbps then
				extra.openuf_ratelimit_down = vap.ratelimit_down_kbps
			end
			if vap.ratelimit_up_kbps then
				extra.openuf_ratelimit_up = vap.ratelimit_up_kbps
			end
			if vap.advertise_ap_name then
				-- "Show Access Point Name in Beacon" -- CONFIRMED (via
				-- decompiling the controller) to require a device-reported
				-- wifi_caps2 capability bit before the controller even
				-- pushes this field at all; see inform.lua's build_json
				-- for that side. There's no standalone "put this string in
				-- a beacon IE" hostapd option, but there IS a real,
				-- standard mechanism for broadcasting a human-readable
				-- device name in every beacon: the Wi-Fi Alliance WPS/WSC
				-- information element's Device Name attribute, which
				-- hostapd includes automatically once WPS is active
				-- (confirmed via hostapd's own README-WPS and OpenWrt's
				-- documented wifi-iface options: wps_device_name maps
				-- directly to hostapd's device_name). ap_setup_locked=1 is
				-- a standard hostapd/WPS hardening flag that disables
				-- PIN-based external registrar enrollment -- set
				-- unconditionally here to minimize the WPS surface this
				-- opens to only what's needed for the name broadcast,
				-- since no push-button/PIN config method is ever enabled.
				-- NOT independently confirmed against genuine Ubiquiti
				-- hardware (no real device available to capture from) --
				-- this is the standards-based mechanism for the stated
				-- goal, not a verified replica of Ubiquiti's own
				-- implementation.
				extra.wps_device_name = (opts and opts.device_name) or "openUF"
				extra.ap_setup_locked = "1"
			end
			-- SAE Anti-clogging / SAE Sync Time. Neither is a wifi-iface
			-- option (writing them as options was stored and dropped in
			-- silence), but both are hostapd BSS keys, and every OpenWrt wifi
			-- stack passes `list hostapd_bss_options` through verbatim: the
			-- ucode scripts (ap.uc "raw options") and the older hostapd.sh
			-- alike. The controller only sends them for a WLAN that really
			-- runs SAE, and the list is openUF's alone on its own sections.
			local raw = {}
			if vap.security == "wpa3" or vap.security == "wpa2/wpa3" then
				local ac, sync = tonumber(vap.sae_anti_clogging), tonumber(vap.sae_sync)
				if ac and ac > 0 then
					raw[#raw + 1] = "sae_anti_clogging_threshold=" .. math.floor(ac)
				end
				if sync and sync > 0 then
					raw[#raw + 1] = "sae_sync=" .. math.floor(sync)
				end
				-- SAE groups: no wifi-iface option either (ap.uc only ever
				-- set_default()s '19 20 21'). The raw line comes after that
				-- default in the BSS config, and hostapd's intlist parser
				-- replaces, not appends, so the controller's list wins.
				if vap.sae_groups and #vap.sae_groups > 0 then
					raw[#raw + 1] = "sae_groups=" .. table.concat(vap.sae_groups, " ")
				end
			end
			-- RADIUS: WPA-Enterprise, RADIUS MAC authentication, keys from
			-- RADIUS (unifi/wlan.lua parse_radius). The option names are the
			-- 25.12 schema's aliases (wireless.wifi-iface.json), which the
			-- legacy hostapd.sh reads under the same names. auth_server and
			-- acct_server are lists, but each takes ONE port and ONE secret
			-- for every address in it, so a server behind a different port or
			-- secret than the first cannot be expressed and is left out.
			local is_eap = vap.security and vap.security:find("-eap", 1, true) ~= nil
			local password = vap.x_passphrase
			local radius = vap.radius
			if radius then
				local function servers(list, kind)
					local first, ips = list[1], {}
					for i, s in ipairs(list) do
						if s.port == first.port and s.secret == first.secret then
							ips[#ips + 1] = s.ip
						else
							io.stderr:write(("openuf: %s: RADIUS %s server %d left out -- "
								.. "OpenWrt takes one port and secret for all of them\n")
								:format(tostring(vap.ssid), kind, i))
						end
					end
					return first, ips
				end
				local auth, auth_ips = servers(radius.auth, "authentication")
				extra.auth_server = auth_ips
				extra.auth_port   = tostring(auth.port)
				extra.auth_secret = auth.secret
				if radius.acct then
					local acct, acct_ips = servers(radius.acct, "accounting")
					extra.acct_server = acct_ips
					extra.acct_port   = tostring(acct.port)
					extra.acct_secret = acct.secret
					if radius.acct_interval then
						extra.acct_interval = tostring(radius.acct_interval)
					end
				end
				if radius.nas_id then extra.nasid = radius.nas_id end
				-- The WLAN's DAS listener (openwrt/das.lua): on the
				-- controller's internal port, answering only the dispatcher,
				-- which relays from 127.0.0.1. OpenWrt writes it for EAP
				-- BSSes only.
				if radius.das and is_eap then
					extra.dae_client = "127.0.0.1"
					extra.dae_port   = tostring(radius.das.port)
					extra.dae_secret = radius.das.secret
				end
				-- NAS-IP-Address: hostapd's default is 127.0.0.1; take the
				-- address of the interface the request leaves by instead.
				extra.dynamic_ownip = "1"
				if is_eap then
					if radius.auth_cache ~= nil then
						extra.auth_cache = radius.auth_cache and "1" or "0"
					end
					if radius.dynamic_vlan > 0 then
						extra.dynamic_vlan = tostring(radius.dynamic_vlan)
					end
					-- 802.11r over EAP: 25.12's ap.uc derives the FT key
					-- holders from md5(mobility_domain/auth_secret ?? key),
					-- but its schema validator has already renamed auth_secret
					-- to auth_server_shared_secret, so that reads nil and the
					-- iface fails with FT_KEY_CANT_BE_DERIVED. `key` is unused
					-- on an Enterprise BSS otherwise; the secret there gives
					-- the derivation upstream intended, identical on every AP.
					-- (A wpa.psk the WLAN kept from an earlier PSK life is
					-- not written.)
					password = ft_enabled and auth.secret or nil
				end
				-- Keys from RADIUS only (psk_radius=2): OpenWrt's ppsk is
				-- macaddr_acl=2 plus wpa_psk_radius=2.
				if vap.radius_psk then extra.ppsk = "1" end
			end
			-- RADIUS MAC authentication. On an open/PSK/SAE/OWE BSS, ap.uc
			-- turns an auth_server alone into macaddr_acl=2, but then writes
			-- a MAC filter's macaddr_acl after it, and on an Enterprise BSS
			-- never; a raw line comes last and wins in both cases.
			if vap.radius_mac_auth and radius then
				raw[#raw + 1] = "macaddr_acl=2"
			end
			-- RADIUS Filter-Id (attribute 11) in every Access-Request: the
			-- service the gateway's RADIUS server checks the account against
			-- (uid-wifi / wpa-eap). radius_auth_req_attr is in the 25.12 schema
			-- and ap.uc writes it with the authentication servers of an
			-- Enterprise BSS; one element, since ap.uc joins a list onto one
			-- line.
			if is_eap and radius and vap.filter_id then
				extra.radius_auth_req_attr = {"11:s:" .. vap.filter_id}
			end
			-- Hotspot 2.0 (openwrt/hotspot2.lua): raw lines, Enterprise only
			-- (hostapd refuses HS 2.0 on anything but WPA2-Enterprise/CCMP).
			if is_eap and vap.hs20 then
				for _, l in ipairs(hotspot2.lines(vap.hs20, vap.dgaf_disable)) do
					raw[#raw + 1] = l
				end
			end
			-- VLAN comes off the vap itself: the controller derives it from
			-- aaa.<n>.br.devname ("br0.20"), not from a linked network object.
			local vlan_enabled = vap.vlan_enabled
			local vlan_id      = vap.vlan

			local network = "lan"
			local netplan = opts and opts.netmodel
			-- One L2 per VLAN a private pre-shared key puts its clients on
			-- (vid -> network section), for ppsk_add below.
			local key_networks = {}
			if netplan then
				-- vlan_filtering backend: netmodel already built one interface
				-- per network on the filtering bridge; the vap joins the one its
				-- controller bridge maps to (which also covers `br-trunk`, the
				-- untagged network once a Management VLAN is set).
				network = (netplan.net_for_bridge or {})[vap.br_devname]
					or (netplan.mgmt and netplan.mgmt.iface) or network
				-- A key's VLAN goes on the plan's interface for that VLAN.
				-- provision hands netmodel every key's VLAN (the push carries
				-- no bridge for a VLAN only a key uses), so the plan has one; a
				-- key the plan still has nothing for is left out by ppsk_add.
				for _, k in ipairs(vap.ppsk or {}) do
					if k.vid then key_networks[k.vid] = M.plan_network_for_vid(netplan, k.vid) end
				end
			elseif cpueth then
				-- The WLAN's own VLAN and each key's: the same br-openuf<vid> a
				-- tagged SSID uses, built once however many need it.
				for _, vid in ipairs(M.vap_vlan_ids(vap)) do
					key_networks[vid] = M.ensure_vlan_network(cpueth, vid)
					wanted_vlans[vid] = true
				end
				if vlan_enabled and vlan_id then
					network = key_networks[tonumber(vlan_id)]
				end
			end

			-- The wire sends dynamic_vlan=1 with every key list, and OpenWrt's
			-- ap.uc writes hostapd's VLAN options (vlan_no_bridge above all:
			-- netifd, not hostapd, bridges the VLAN netdev) only when it is set.
			if vap.ppsk then extra.dynamic_vlan = "1" end

			-- RADIUS-assigned VLANs land on the VLANs this AP already carries
			-- (radius_vlans_add): every VLAN in the vlan_filtering plan, or
			-- every WLAN's and wired port's VLAN on the legacy backend.
			local radius_networks
			if is_eap and radius and radius.dynamic_vlan > 0 then
				radius_networks = {}
				if netplan then
					for vid in pairs(netplan.vlan_ifaces or {}) do
						radius_networks[vid] = M.plan_network_for_vid(netplan, vid)
					end
					local mvid = M.plan_mgmt_vid(netplan)
					if mvid then radius_networks[mvid] = M.plan_network_for_vid(netplan, mvid) end
				elseif cpueth then
					local vids = {}
					for _, other in ipairs(vap_table) do
						for _, vid in ipairs(M.vap_vlan_ids(other)) do vids[vid] = true end
					end
					for vid in pairs((opts and opts.keep_vlans) or {}) do
						if tonumber(vid) then vids[tonumber(vid)] = true end
					end
					for vid in pairs(vids) do
						radius_networks[vid] = M.ensure_vlan_network(cpueth, vid)
						wanted_vlans[vid] = true
					end
				end
			end

			-- MAC-based VLANs (M.macvlan_plan): hostapd's accept_mac_file with
			-- a VLAN id per MAC, one wifi-vlan per VLAN for its vlan_file.
			local sname = M.section_name(vap.radio, vap.ssid)
			local mv = M.macvlan_plan(vap, function(vid)
				if netplan then
					-- VLAN 1 is the untagged network: the one br0 maps to.
					if vid == 1 then return (netplan.net_for_bridge or {})["br0"] end
					return M.plan_network_for_vid(netplan, vid)
				elseif cpueth then
					if vid == 1 then return (cfg and cfg.net and cfg.net.lan_name) or "lan" end
					wanted_vlans[vid] = true
					return M.ensure_vlan_network(cpueth, vid)
				end
			end)
			if mv then
				local path = M.macvlan_path(sname, mv.content)
				if M._read_file(path) ~= mv.content then M._write_file(path, mv.content) end
				macvlan_files[path] = true
				raw[#raw + 1] = "accept_mac_file=" .. path
				extra.dynamic_vlan = extra.dynamic_vlan or "1"
				radius_networks = radius_networks or {}
				for vid, net in pairs(mv.networks) do radius_networks[vid] = radius_networks[vid] or net end
			end
			extra.hostapd_bss_options = (#raw > 0) and raw or M.DELETE

			local section = M.wlan_add(vap.radio, vap.ssid,
				{security = vap.security, pairwise = vap.pairwise},
				password, extra, network, vap.wlanconf_id)
			if vap.ppsk and section then
				M.ppsk_add(section, vap.ppsk, key_networks)
			end
			if radius_networks and section then
				M.radius_vlans_add(section, radius_networks)
			end
		end
	end

	-- A VLAN no WLAN uses may still be wanted by a wired port assigned to it
	-- (DSA per-port VLAN puts the socket in this same bridge -- see
	-- ensure_vlan_network's OWNERSHIP note). Its bridge must survive the
	-- prune below, and be built even when no WLAN mentions the VID at all.
	for vid in pairs((not (opts and opts.netmodel) and opts and opts.keep_vlans) or {}) do
		local n = tonumber(vid) or vid
		if not wanted_vlans[n] and cpueth then
			M.ensure_vlan_network(cpueth, n)
			wanted_vlans[n] = true
		end
	end

	-- Drop the L2 of any VLAN no longer carried by a WLAN. Changing a
	-- network's VLAN id in the controller (20 -> 10) or deleting the WLAN
	-- outright leaves the old bridge and its tagged sub-device behind
	-- otherwise -- confirmed live on both APs, which kept a br-openuf20 with
	-- eth1.20 in it long after the WLAN had moved to VLAN 10. Harmless-looking
	-- but it accumulates, keeps a sub-device on the trunk forever, and makes
	-- the running config stop matching what the controller asked for.
	-- switchvlan.lua already reconciles its own switch_vlan sections this way.
	M.prune_vlan_networks(wanted_vlans)

	-- The wireless uplink (unifi/mesh.lua's plan): the hidden WDS downlink
	-- and/or the 4-address uplink station. wlan_clear() above removed the
	-- previous copies, so this is a rewrite on every push, the station's
	-- disabled flag following the uplink policy's current mode. Both join the
	-- management network: the inform runs over the hop. Only that network
	-- crosses it -- see USAGE.md § 6b on VLANs.
	if opts and opts.backhaul then
		local netplan = opts.netmodel
		local ok_bh, err_bh = pcall(M.backhaul_apply, opts.backhaul,
			(netplan and netplan.mgmt and netplan.mgmt.iface)
				or (cfg and cfg.net and cfg.net.lan_name) or "lan", opts.peer_ie)
		if not ok_bh then
			io.stderr:write("ucihelper: backhaul sections not written: " .. tostring(err_bh) .. "\n")
		end
	end

	-- Hand-configured (non-openuf_) SSIDs: disable or restore them per
	-- the use_only_unifi_wlan option. Runs after the vap loop so it sees the
	-- final section set, and before the reload so both land in one restart.
	M.set_wlan_exclusive(cfg and cfg.config and cfg.config.use_only_unifi_wlan == true,
		not (cfg and cfg.config and cfg.config.own_config == false))

	-- A VLAN bridge that only exists in UCI carries no traffic: netifd has to
	-- be told, and `wifi reload` alone does not create a bridge device. Runs
	-- BEFORE the wireless reload so the bridge exists by the time hostapd's
	-- interfaces come up and netifd looks for something to enslave them to.
	--
	-- Gated on an actual change (ensure_vlan_network sets the flag) for the
	-- same reason switchvlan guards its own reload: every steady-state
	-- setparam re-carries the whole config, and reloading the network on each
	-- one would bounce the uplink -- and with it the inform connection --
	-- every few seconds.
	if M._network_dirty then
		M._run_cmd("/etc/init.d/network reload 2>/dev/null")
		M._network_dirty = false
	end

	-- Reload wireless
	local reloaded = M._run_cmd("wifi reload")
	-- A list no WLAN references any more: nothing reads it, but it names
	-- clients, so it does not stay on flash. Only once the reload that
	-- stopped hostapd reading it went through: until then the running BSS
	-- may still need the old file (a missing accept_mac_file fails the BSS).
	if require("openwrt.util").exec_ok(reloaded) then
		local listing = M._popen("ls " .. M.MACVLAN_DIR) or ""
		for f in listing:gmatch("[^\n]+") do
			local path = M.MACVLAN_DIR .. "/" .. f
			if (f:match("^macvlan%-openuf_[%w_]+%-%x+%.list$") or f:match("^macvlan%-openuf_[%w_]+%.list$"))
					and not macvlan_files[path] then
				M._remove_file(path)
			end
		end
	else
		io.stderr:write("ucihelper: wifi reload failed -- old MAC-based VLAN lists kept\n")
	end
	-- netifd may hand the interfaces new netdev names on the way back up, and
	-- the wireless config this reload just wrote is the very thing the radio
	-- rows were read from, so the lookups below must not reuse anything read
	-- before it.
	M._ws_cache   = nil
	M._pass_cache = nil

	-- "Multicast and Broadcast Blocker" (nftables) enforcement. Deliberately
	-- after the reload: the rules key off each VAP's live netdev name, which
	-- only exists (and can change) once netifd has brought the interfaces
	-- back up.
	local entries = {}
	for _, vap in ipairs(vap_table) do
		if vap.ssid and vap.radio then
			-- Resolved once per VAP and shared by both features -- this used to
			-- be two lookups per VAP through the same ubus status call. An OWE
			-- transition VAP has two netdevs, and a VAP with private
			-- pre-shared keys one more per key VLAN: they all get the rules.
			for _, ifname in ipairs(M.get_ifnames_for_vap(vap.radio, vap.ssid)) do
				entries[#entries + 1] = {
					ifname         = ifname,
					bcfilt_enabled = vap.bcfilt_enabled,
					bcfilt_macs    = vap.bcfilt_macs,
					bcfilt_bypass  = vap.bcfilt_bypass,
					mcast_suppressor = vap.mcast_suppressor,
				}
			end
		end
	end
	reconcile_runtime(entries)
	-- The DAS dispatcher's plan (announce.lua reads it).
	pcall(function()
		local das = require("openwrt.das")
		das.save(das.plan(vap_table))
	end)
end

-- Reapply the Multicast and Broadcast Blocker from UCI.
--
-- It is an nftables ruleset: LIVE KERNEL STATE that a reboot discards, with no
-- UCI option OpenWrt itself understands. apply_config() only ever runs on a
-- setparam, and after a reboot there is no setparam to run it -- cfgversion is
-- persisted, so it matches on the first inform and the controller replies noop
-- with no system_cfg at all. The blocker therefore stayed switched off
-- indefinitely while the controller UI went on showing it as on.
--
-- The openuf_bcfilt* options wlan_add stamps onto each managed section are
-- the record this reads back.
--
-- Called at startup by inform.M.run, alongside the blocked-client and LED
-- reconciliation, and for the same reason. Returns the number of managed VAPs
-- it found, for the caller's log line.
-- Radio options only openUF writes, deleted outright on Forget, and the
-- stamped ones rf_config writes only under its markers, deleted only where
-- the marker is.
local FORGET_RADIO_OPTS  = {"minrssi_enabled", "minrssi_rssi", "loadbalance_maxsta"}
local FORGET_RADIO_STAMP = {
	openuf_minrssi  = {"rssi_reject_assoc_rssi", "rssi_ignore_probe_request"},
	openuf_rates    = {"basic_rate", "supported_rates", "legacy_rates", "beacon_rate"},
	openuf_maxassoc = {"maxassoc"},
}

-- Undo what apply_config wrote, for a controller "Forget" (setdefault) or a
-- reset-inform. UniFi firmware answers setdefault with `syswrapper.sh
-- restore-default`, a factory reset and reboot that leaves no SSID on the air
-- (firmware-confirmed for 4.0.15, upstream); this is the same end state for
-- the WiFi without the reboot, limited to what openUF itself put there:
--   * every openuf_ wifi-iface, with its private-key sections (wlan_clear)
--   * every openuf_ VLAN network and bridge (prune_vlan_networks)
--   * the radio options above
--   * the board's own SSIDs use_only_unifi_wlan switched off come back on
--     (ones own_config deleted are in WIRELESS_PRISTINE: syswrapper.sh
--     netmodel-restore puts them back)
--   * the Multicast and Broadcast Blocker's ruleset
-- A radio's channel, width, transmit power, country and enable stay as the
-- controller last set them, and so does the controller-owned bridge
-- (netmodel): taking the management path away on a Forget could strand the
-- AP. netmodel-restore is the explicit way back to the board's own network.
function M.forget()
	local cursor = get_uci().cursor()
	local radios = {}
	cursor:foreach("wireless", "wifi-device", function(s) radios[#radios + 1] = s end)
	for _, s in ipairs(radios) do
		local name = s[".name"]
		for _, opt in ipairs(FORGET_RADIO_OPTS) do
			if s[opt] ~= nil then cursor:delete("wireless", name, opt) end
		end
		for stamp, opts in pairs(FORGET_RADIO_STAMP) do
			if s[stamp] == "1" then
				for _, opt in ipairs(opts) do cursor:delete("wireless", name, opt) end
				cursor:delete("wireless", name, stamp)
			end
		end
	end
	cursor:commit("wireless")
	M.wlan_clear()
	M.prune_vlan_networks({})
	M.set_wlan_exclusive(false)
	if M._network_dirty then
		M._run_cmd("/etc/init.d/network reload 2>/dev/null")
		M._network_dirty = false
	end
	M._run_cmd("wifi reload")
	M._ws_cache   = nil
	M._pass_cache = nil
	reconcile_runtime({})
end

function M.reapply_runtime_rules()
	local uci = get_uci()
	local cursor = uci.cursor()
	local entries = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		local name = s[".name"]
		if not name or name:sub(1, #OPENUF_PREFIX) ~= OPENUF_PREFIX then return end
		-- A disabled VAP has no netdev to attach a rule to. It also needs no
		-- teardown: the reload that disabled it took its interface, and with it
		-- every qdisc and every nft rule that named it.
		if s.disabled == "1" then return end
		local ok_if, ifnames = pcall(M.get_ifnames_for_vap, s.device, s.ssid)
		if not (ok_if and type(ifnames) == "table") then return end
		local macs = {}
		for mac in (s.openuf_bcfilt_macs or ""):gmatch("%S+") do
			macs[#macs + 1] = mac
		end
		local bypass
		for t in (s.openuf_bcfilt_bypass or ""):gmatch("%S+") do
			bypass = bypass or {}
			bypass[#bypass + 1] = t
		end
		for _, ifname in ipairs(ifnames) do
			entries[#entries + 1] = {
				ifname         = ifname,
				bcfilt_enabled = (s.openuf_bcfilt == "1"),
				bcfilt_macs    = macs,
				bcfilt_bypass  = bypass,
				mcast_suppressor = s.openuf_mcast_suppressor,
			}
		end
	end)
	reconcile_runtime(entries)
	return #entries
end

-- ─── Read helpers (for inform payload builder) ───────────────────────────────

-- Every wifi-device in UCI, unfiltered, read once per pass.
--
-- get_radio_table was called TWICE per heartbeat -- once by build_json with
-- dev.conf.hwassign, and once by get_vap_table with none, to build its
-- band lookup -- so /etc/config/wireless was loaded through a fresh
-- uci.cursor() twice for one answer, on config that changes only when the
-- controller pushes one.
--
-- The rows are held UNFILTERED and hwassign is applied per call: the two
-- callers want different filtering of the same rows, and a memo that held the
-- filtered result would change which radios vap_table can resolve
-- radio/channel/tx_power against.
local function radio_rows()
	return pass_memo("radio_rows", function()
	local uci = get_uci()
	local cursor = uci.cursor()
	local radios = {}
	cursor:foreach("wireless", "wifi-device", function(s)
		radios[#radios + 1] = {
			name             = s[".name"],
			radio            = band_for_device(s),
			-- Numbers as numbers; the literal "auto" passes through as the
			-- honest config intent until build_json overrides it with the
			-- live negotiated channel.
			channel          = tonumber(s.channel) or s.channel,
			ht               = s.htmode,
			tx_power         = s.txpower,
			-- UCI regdomain (e.g. "CZ"); build_json maps it to the numeric
			-- ISO 3166 country_code. Internal -- stripped before serializing.
			-- openuf_country wins where it exists: the regdomain the
			-- CONTROLLER set, stamped by rf_config under a country_override.
			country          = s.openuf_country or s.country,
			disabled         = (s.disabled == "1"),
			builtin_antenna  = M.RADIO_DEFAULTS.builtin_antenna,
			builtin_ant_gain = M.RADIO_DEFAULTS.builtin_ant_gain,
			-- Real per-band driver limit where `iw` can supply one: this is
			-- what bounds the controller's TX Power slider, so the static
			-- default made every radio claim 20 dBm regardless of hardware
			-- and regdomain. Falls back to the default when unknown.
			max_txpower      = (M.phy_caps()[band_for_device(s)] or {}).max_txpower
				or M.RADIO_DEFAULTS.max_txpower,
			-- min_rssi_enabled/min_rssi_raw: raw UCI echo of rf_config()'s
			-- minrssi_enabled/minrssi_rssi options. min_rssi_raw is still
			-- wire-encoded units at this point (not dBm) -- inform.lua's
			-- build_json converts it to the real outbound "min_rssi" dBm
			-- field once a live noise-floor reading is available, then
			-- discards this raw field.
			min_rssi_enabled = (s.minrssi_enabled == "1"),
			min_rssi_raw     = tonumber(s.minrssi_rssi),
			-- Load balance's cap, nil when off. Internal: report.lua
			-- consumes it and strips it before serializing.
			loadbalance_maxsta = tonumber(s.loadbalance_maxsta),
			-- Load balance's cap, nil when off. Internal: build_json
			-- consumes it and strips it before serializing.
			loadbalance_maxsta = tonumber(s.loadbalance_maxsta),
		}
	end)
	return radios
	end)
end

-- Return a table of radio info for the inform payload.
-- hwassign: dev.conf.hwassign (UCI list openuf.board.hwassign) -- the radio names to
-- report. That matters on a board with a radio openUF should not present as
-- part of the emulated model (a third radio, a mesh-only or monitor phy): the
-- controller would show and try to configure a radio the emulated model does
-- not have. nil/empty reports every radio.
function M.get_radio_table(hwassign)
	local allowed = nil
	if type(hwassign) == "table" and #hwassign > 0 then
		allowed = {}
		for _, name in ipairs(hwassign) do allowed[name] = true end
	end
	local radios = {}
	for _, row in ipairs(radio_rows()) do
		if not allowed or allowed[row.name] then
			-- A COPY per call. build_json writes the hardware caps, the
			-- re-derived band and the payload's own fields onto the rows it
			-- gets back and strips the internal ones; sharing the memoized
			-- tables would let that reach the copy get_vap_table is reading
			-- from -- and the next heartbeat's.
			local copy = {}
			for k, v in pairs(row) do copy[k] = v end
			radios[#radios + 1] = copy
		end
	end
	return radios
end

-- The cjson binding used to parse `ubus call network.wireless status` for
-- the live ifname lookups below. Injectable (M._load_cjson) and cached; a
-- missing binding warns ONCE, loudly: without it every ifname resolution
-- returns nil and the Multicast/Broadcast Blocker AND the WiFi Speed Limit
-- silently become no-ops while apply_config still reports success -- the
-- kind of quiet degradation nothing would ever surface otherwise.
M._load_cjson = function()
	local ok, mod = pcall(require, "cjson")
	return ok and mod or nil
end
local cjson_checked, cjson_mod = false, nil
local function get_cjson()
	if not cjson_checked then
		cjson_checked = true
		cjson_mod = M._load_cjson()
		if not cjson_mod then
			io.stderr:write("ucihelper: lua-cjson unavailable -- live ifname "
				.. "resolution disabled; Multicast/Broadcast Blocker and WiFi "
				.. "Speed Limit will NOT be enforced\n")
		end
	end
	return cjson_mod
end

-- Resolve a UCI radio name (e.g. "radio0") to its live wireless netdev name
-- (e.g. "wlan0"), as assigned at runtime by netifd. Needed because sta_table()/
-- radio_stats() operate on the live `iw`-visible interface, not the UCI config
-- name. Returns nil if unresolvable (e.g. off-target, radio disabled).
-- The decoded `ubus call network.wireless status`, shared by the two lookups
-- below. Cached only INSIDE a pass opened by begin_pass() -- inform.lua's
-- build_json opens one per payload and closes it on return -- and dropped by
-- end_pass() and after every `wifi reload`, so a netdev name read before
-- netifd rebuilt the interfaces is never reused after. Outside a pass every
-- call forks ubus exactly as before, which is also what keeps the test suite's
-- per-test _popen stubs independent of one another. Inside one, what used to
-- be ten identical forks per heartbeat on a two-radio, four-SSID box is one.
M._ws_cache = nil      -- {status = <decoded table> | false} while a pass is open
M._ws_pass  = false
function M.begin_pass() M._ws_pass = true;  M._ws_cache = nil; M._pass_cache = {} end
function M.end_pass()   M._ws_pass = false; M._ws_cache = nil; M._pass_cache = nil end

local function wireless_status()
	if M._ws_pass and M._ws_cache then
		return M._ws_cache.status or nil
	end
	local status = nil
	local output = M._popen("ubus call network.wireless status")
	if output ~= "" then
		local cjson = get_cjson()
		if cjson then
			local ok_d, decoded = pcall(cjson.decode, output)
			if ok_d and type(decoded) == "table" then status = decoded end
		end
	end
	if M._ws_pass then M._ws_cache = {status = status or false} end
	return status
end

-- The wireless uplink's sections (backhaul_apply below) and how to tell one
-- in netifd's status: by section name, or by `wds` -- a 4-address link
-- carries other devices' frames and BPDUs by design, and is no client VAP.
M.BACKHAUL_PREFIX    = OPENUF_PREFIX .. "bh_"
M.BACKHAUL_DL_PREFIX = OPENUF_PREFIX .. "bh_dl_"
M.BACKHAUL_UL_PREFIX = OPENUF_PREFIX .. "bh_ul_"

local function is_backhaul_iface(iface)
	if type(iface) ~= "table" then return false end
	if type(iface.section) == "string"
			and iface.section:sub(1, #M.BACKHAUL_PREFIX) == M.BACKHAUL_PREFIX then
		return true
	end
	local wds = type(iface.config) == "table" and iface.config.wds or nil
	return wds == true or wds == 1 or wds == "1"
end

-- The radio's first interface -- an access point's where there is one, so
-- the per-radio reads (survey, scan cache, capabilities) never land on the
-- uplink station while the radio has a VAP.
function M.get_ifname_for_radio(radio)
	if not radio then return nil end
	local status = wireless_status()
	if not status then return nil end
	local dev = status[radio]
	if type(dev) == "table" and type(dev.interfaces) == "table" then
		local fallback
		for _, iface in ipairs(dev.interfaces) do
			if type(iface) == "table" and iface.ifname then
				if not is_backhaul_iface(iface) then return iface.ifname end
				fallback = fallback or iface.ifname
			end
		end
		return fallback
	end
	return nil
end

-- The second netdev of an Enhanced Open transition section, or nil.
--
-- owe_transition=1 makes the generator bring up TWO BSSes from one section:
-- the section's own netdev is the hidden OWE BSS, and the open BSS gets a
-- netdev netifd's status never lists (25.12's ucode mac80211.sh assigns it as
-- owe_transition_ifname and hands it only to hostapd). hostapd reports it in
-- its bss_info, which is where OpenWrt's own iwinfo.uc reads it too. Asked
-- only for sections that have the option, so no other VAP pays for a ubus
-- call, and once per lookup pass.
local function owe_transition_ifname(iface)
	local on = type(iface) == "table" and type(iface.config) == "table"
		and iface.config.owe_transition
	if not (on == true or on == 1 or on == "1") then return nil end
	-- Interpolated into a shell command line.
	if type(iface.ifname) ~= "string" or not iface.ifname:match("^[%w%-%._]+$") then
		return nil
	end
	return pass_memo("owe_peer:" .. iface.ifname, function()
		local cjson = get_cjson()
		if not cjson then return nil end
		local out = M._popen("ubus call hostapd bss_info '{\"iface\":\"" .. iface.ifname .. "\"}'")
		local ok, info = pcall(cjson.decode, out or "")
		local peer = ok and type(info) == "table" and info.owe_transition_ifname
		if type(peer) == "string" and peer:match("^[%w%-%._]+$") and peer ~= iface.ifname then
			return peer
		end
		return nil
	end)
end

-- Resolve a specific VAP to its live wireless netdev name, by matching the
-- SSID within the radio's interface list. get_ifname_for_radio() above returns
-- the radio's FIRST interface, which is the same thing only when the radio
-- hosts a single SSID -- not good enough for per-WLAN features like the
-- Multicast and Broadcast Blocker, where picking the wrong VAP's netdev would
-- silently apply one SSID's filter to another. Returns nil if unresolvable.
local function find_vap_iface(radio, ssid)
	if not radio or not ssid then return nil end
	local status = wireless_status()
	if not status then return nil end
	local dev = status[radio]
	if type(dev) ~= "table" or type(dev.interfaces) ~= "table" then return nil end
	for _, iface in ipairs(dev.interfaces) do
		if type(iface) == "table" and iface.ifname
			and type(iface.config) == "table" and iface.config.ssid == ssid then
			return iface
		end
	end
	-- Fall back to the radio's only interface when the SSID could not be
	-- matched but there is exactly one candidate: netifd does report
	-- config.ssid per interface, but nothing guarantees every build/version
	-- does, and with a single VAP on the radio there is no other interface it
	-- could be. Deliberately not extended to the multi-interface case -- there
	-- a wrong guess would apply one SSID's filter to another, which is worse
	-- than not applying it at all.
	if #dev.interfaces == 1 and type(dev.interfaces[1]) == "table" then
		return dev.interfaces[1]
	end
	return nil
end

function M.get_ifname_for_vap(radio, ssid)
	local iface = find_vap_iface(radio, ssid)
	return iface and iface.ifname
end

-- The VLAN netdevs of one VAP, appended to `out`. A client whose private
-- pre-shared key carries a VLAN is associated on <vap ifname>-<vid>, not on
-- the VAP's own netdev, and `iw dev <vap> station dump` does not list it.
-- netifd reports them under the interface's vlans[] (one without an ifname
-- is not up yet). Each is remembered against its VAP for M.bss_ifname.
M._vlan_parent = {}
local function vlan_ifnames(iface, out)
	for _, v in ipairs(type(iface.vlans) == "table" and iface.vlans or {}) do
		if type(v) == "table" and type(v.ifname) == "string" and v.ifname ~= "" then
			out[#out + 1] = v.ifname
			M._vlan_parent[v.ifname] = iface.ifname
		end
	end
	return out
end

-- The netdev whose hostapd serves a station seen on `ifname`: the VAP itself
-- for a VLAN netdev from get_ifnames_for_vap, else ifname unchanged (the open
-- BSS of an OWE transition section is a hostapd BSS of its own). hostapd has
-- a control socket and a ubus object per BSS only, so a kick or a BSS
-- transition request aimed at the VLAN netdev would reach nothing.
function M.bss_ifname(ifname)
	return M._vlan_parent[ifname] or ifname
end

-- Every live netdev of one VAP: its own, the open BSS of an OWE transition
-- section, and the VLAN netdev of each private pre-shared key's VLAN.
-- Per-VAP features (station reporting, the blocker, the speed limit) have to
-- cover them all, or those clients would fall outside them. Empty when the
-- VAP cannot be resolved.
function M.get_ifnames_for_vap(radio, ssid)
	local iface = find_vap_iface(radio, ssid)
	if not (iface and iface.ifname) then return {} end
	local out = {iface.ifname}
	local peer = owe_transition_ifname(iface)
	if peer then out[#out + 1] = peer end
	return vlan_ifnames(iface, out)
end

-- "Minimum RSSI" enforcement: send a single 802.11 deauthentication frame to
-- mac on ifname. Deliberately standalone from firewall.lua's block-sta
-- feature -- confirmed via web research that Minimum RSSI is a roaming aid,
-- not a block: it's a one-shot deauth with no persistent drop rule, and the
-- client is free to reassociate immediately (even back to the same radio).
-- No state.json persistence either, unlike blocked_stas -- there's nothing
-- to reconcile on restart since this is fully re-derived every inform cycle
-- from live UCI config + sta_table.
-- Every VAP netdev netifd reports, across all radios, sorted, plus the open
-- BSS of an OWE transition section, which netifd does not list (see
-- owe_transition_ifname). ap_only leaves out station and mesh interfaces (see
-- ap_ifnames) and the wireless uplink's downlink AP; with_vlans adds each VAP's private-pre-shared-key VLAN
-- netdevs, which carry clients but no hostapd of their own.
function M.all_vap_ifnames(ap_only, with_vlans)
	local status = wireless_status()
	local out = {}
	for _, dev in pairs(status or {}) do
		if type(dev) == "table" and type(dev.interfaces) == "table" then
			for _, iface in ipairs(dev.interfaces) do
				local mode = type(iface) == "table" and type(iface.config) == "table"
					and iface.config.mode or nil
				if type(iface) == "table" and type(iface.ifname) == "string" and iface.ifname ~= ""
						and not (ap_only and ((mode ~= nil and mode ~= "ap")
							or is_backhaul_iface(iface))) then
					out[#out + 1] = iface.ifname
					out[#out + 1] = owe_transition_ifname(iface)
					if with_vlans then vlan_ifnames(iface, out) end
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- The live netdev of every AP-mode VAP, and of each VAP's private-pre-shared-
-- key VLANs, whose clients l2guard has to cover too. A station or mesh
-- interface -- a wireless backhaul -- is not a VAP: l2guard's tag drop on an
-- uplink would cut the AP off. Empty when wireless is not up or ubus cannot
-- be asked; callers treat that as "nothing to protect yet", never as "no
-- VAPs".
function M.ap_ifnames()
	return M.all_vap_ifnames(true, true)
end

-- The live netdevs of the AP-mode VAPs broadcasting one of `ssids`, on any
-- radio, with their OWE-transition peer and private-pre-shared-key VLAN
-- netdevs (guestguard: the guest WLANs). Sorted; empty when wireless is not
-- answering or no such VAP is up yet.
function M.ap_ifnames_for_ssids(ssids)
	local want = {}
	for _, s in ipairs(ssids or {}) do want[s] = true end
	local out = {}
	for _, dev in pairs(wireless_status() or {}) do
		if type(dev) == "table" and type(dev.interfaces) == "table" then
			for _, iface in ipairs(dev.interfaces) do
				local c = type(iface) == "table" and type(iface.config) == "table" and iface.config or nil
				if c and want[c.ssid] and (c.mode == nil or c.mode == "ap")
						and not is_backhaul_iface(iface)
						and type(iface.ifname) == "string" and iface.ifname ~= "" then
					out[#out + 1] = iface.ifname
					out[#out + 1] = owe_transition_ifname(iface)
					vlan_ifnames(iface, out)
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- Disconnect a station from whichever VAP it is on, through hostapd's own ubus
-- object -- present on every hostapd build, unlike hostapd_cli, which needs the
-- optional hostapd-utils. ban_time 0: the client may come straight back, which
-- is what the controller's "Reconnect" means. `mac` must already be validated
-- (it is spliced into a command line).
function M.disconnect_station(mac)
	for _, ifname in ipairs(M.all_vap_ifnames()) do
		M._run_cmd(("ubus call hostapd.%s del_client "
			.. "'{\"addr\":\"%s\",\"reason\":5,\"deauth\":true,\"ban_time\":0}' 2>/dev/null")
			:format(ifname, mac))
	end
	return true
end

function M.kick_station(ifname, mac)
	M._run_cmd("hostapd_cli -i " .. ifname .. " deauthenticate " .. mac .. " 2>/dev/null")
	return true
end

-- ─── Wireless uplink (mesh backhaul) ─────────────────────────────────────────
--
-- Written by apply_config from unifi/mesh.lua's plan. Both carry the openuf_
-- prefix, so wlan_clear() rewrites them on every push like the WLANs, plus
-- `openuf_backhaul` (downlink|uplink) so get_vap_table reports them typed and
-- ap_ifnames leaves them out. Every option checked against 25.12's
-- wireless.wifi-iface schema and wifi-scripts (ported from yesrab/openUF):
--
-- Downlink: the hidden WPA2-PSK AP children join. `wds 1` makes ap.uc write
-- wds_sta=1, so hostapd accepts a 4-address station and parks it on its own
-- netdev <bss>.sta<N> in the AP's bridge.
-- Uplink: the 4-address station (supplicant.uc: '4addr': !!wds, and wds is
-- what lets a station sit in a bridge at all), in the same network.
-- Disabled unless the uplink policy (openwrt/backhaul.lua) says the wire is
-- gone: a wired AP with the station up is a bridge loop.
local function bh_section_name(prefix, radio)
	return prefix .. (tostring(radio):gsub("[^%w_]", "_"))
end

-- bh:      BackhaulPlan (unifi/mesh.lua plan)
-- network: the UCI interface both join -- the management network, which is
--          where the inform runs over the hop
-- peer_ie: the sibling element (sysinfo.peer_ie_hex), so a child's scan
--          knows the downlink for a site AP's
-- Returns the section names written.
function M.backhaul_apply(bh, network, peer_ie)
	if type(bh) ~= "table" then return {} end
	local uci = get_uci()
	local cursor = uci.cursor()
	local written = {}
	network = network or "lan"
	local dl = bh.downlink
	if type(dl) == "table" and dl.radio and dl.ssid and type(dl.key) == "string" and #dl.key >= 8 then
		local s = bh_section_name(M.BACKHAUL_DL_PREFIX, dl.radio)
		cursor:set("wireless", s, "wifi-iface")
		cursor:set("wireless", s, "device", dl.radio)
		cursor:set("wireless", s, "mode", "ap")
		cursor:set("wireless", s, "ssid", dl.ssid)
		cursor:set("wireless", s, "hidden", "1")
		cursor:set("wireless", s, "encryption", "psk2")
		cursor:set("wireless", s, "key", dl.key)
		cursor:set("wireless", s, "wds", "1")
		cursor:set("wireless", s, "network", network)
		-- The push's aaa block says pmf.status=disabled.
		cursor:set("wireless", s, "ieee80211w", "0")
		cursor:set("wireless", s, "isolate", "0")
		if type(peer_ie) == "string" and peer_ie ~= "" then
			cursor:set("wireless", s, "vendor_elements", peer_ie)
		end
		if dl.devname then cursor:set("wireless", s, "openuf_devname", dl.devname) end
		cursor:set("wireless", s, "openuf_backhaul", "downlink")
		written[#written + 1] = s
	end
	local ul = bh.uplink
	if type(ul) == "table" and ul.radio and ul.ssid and type(ul.key) == "string" and #ul.key >= 8 then
		local s = bh_section_name(M.BACKHAUL_UL_PREFIX, ul.radio)
		cursor:set("wireless", s, "wifi-iface")
		cursor:set("wireless", s, "device", ul.radio)
		cursor:set("wireless", s, "mode", "sta")
		cursor:set("wireless", s, "wds", "1")
		cursor:set("wireless", s, "ssid", ul.ssid)
		cursor:set("wireless", s, "encryption", "psk2")
		cursor:set("wireless", s, "key", ul.key)
		cursor:set("wireless", s, "network", network)
		if ul.devname then cursor:set("wireless", s, "openuf_devname", ul.devname) end
		cursor:set("wireless", s, "disabled", ul.enabled and "0" or "1")
		cursor:set("wireless", s, "openuf_backhaul", "uplink")
		written[#written + 1] = s
	end
	if #written > 0 then cursor:commit("wireless") end
	return written
end

-- Every backhaul section of one role: {name, radio, ssid, devname, disabled}.
local function backhaul_sections(role)
	local uci = get_uci()
	local cursor = uci.cursor()
	local out = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		if s[".name"] and s.openuf_backhaul == role then
			out[#out + 1] = {name = s[".name"], radio = s.device, ssid = s.ssid,
				devname = s.openuf_devname, disabled = (s.disabled == "1")}
		end
	end)
	return out
end
function M.backhaul_uplink_sections() return backhaul_sections("uplink") end

-- Switch every uplink station section on or off, and reload wireless once
-- when anything changed (netifd restarts only the radio whose config did).
-- Returns true when something changed.
function M.backhaul_set_uplink_enabled(enabled)
	local uci = get_uci()
	local cursor = uci.cursor()
	local want = enabled and "0" or "1"
	local changed = false
	for _, s in ipairs(M.backhaul_uplink_sections()) do
		if (s.disabled and "1" or "0") ~= want then
			cursor:set("wireless", s.name, "disabled", want)
			changed = true
		end
	end
	if changed then
		cursor:commit("wireless")
		M._run_cmd("wifi reload")
		M._ws_cache, M._pass_cache = nil, nil
	end
	return changed
end

-- The live netdev of a wifi-iface section, from netifd's wireless status
-- (each interface names its `section`). nil when it is not up.
function M.ifname_for_section(section)
	if type(section) ~= "string" then return nil end
	for _, dev in pairs(wireless_status() or {}) do
		for _, i in ipairs(type(dev) == "table" and type(dev.interfaces) == "table"
				and dev.interfaces or {}) do
			if type(i) == "table" and i.section == section
					and type(i.ifname) == "string" and i.ifname ~= "" then
				return i.ifname
			end
		end
	end
	return nil
end

-- One backhaul section as a vap_table entry, the way the controller's VAP
-- processor reads it (decompiled from 10.6.106 by yesrab/openUF,
-- PROTOCOL-VALIDATION.md § Wireless uplink): `usage` uplink or downlink,
-- `name` the controller's own devname (ath4 / vwire3) so the top-level
-- `uplink` string and connectivity.uplink_wds tie to it, `essid` the site's
-- mesh ESSID (what marks mesh v3), `up` and a non-zero channel or it is
-- dropped, `state` RUN/INIT, `bssid` the interface's own address.
-- _ifnames (internal, removed by report.lua) are the netdevs whose
-- `station dump` is this VAP's sta_table: the uplink's own (whose one
-- "station" is the parent's downlink BSS) or, for a downlink, its own plus
-- each child's WDS netdev <bss>.sta<N>, where hostapd parks a 4-address peer.
local function backhaul_vap(s, radio)
	local rec = {
		name       = s.openuf_devname or s[".name"],
		essid      = s.ssid,
		radio      = radio and radio.radio,
		radio_name = s.device,
		encryption = s.encryption,
		disabled   = (s.disabled == "1"),
		bssid      = "",
		channel    = radio and radio.channel,
		tx_power   = radio and radio.tx_power,
		usage      = s.openuf_backhaul,
		hidden     = true,
		up         = false,
		state      = "INIT",
		_ifnames   = {},
	}
	local ifname = M.ifname_for_section(s[".name"])
	if not (type(ifname) == "string" and ifname:match("^[%w%-%._]+$")) then return rec end
	rec._ifnames[1] = ifname
	local addr = M._read_file("/sys/class/net/" .. ifname .. "/address")
	addr = addr and addr:match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	if addr then rec.bssid, rec.mac = addr:lower(), addr:lower() end
	if s.openuf_backhaul == "downlink" then
		rec.up, rec.state = true, "RUN"
		local prefix = ifname .. ".sta"
		for dev in (M._popen("ls /sys/class/net") or ""):gmatch("%S+") do
			if dev:sub(1, #prefix) == prefix and dev:sub(#prefix + 1):match("^%d+$") then
				rec._ifnames[#rec._ifnames + 1] = dev
			end
		end
	else
		local link = M._popen("iw dev " .. ifname .. " link") or ""
		if link:match("Connected to %x%x:") then rec.up, rec.state = true, "RUN" end
	end
	return rec
end

-- Return a table of VAP (virtual AP) info for the inform payload.
function M.get_vap_table()
	local uci = get_uci()
	local cursor = uci.cursor()

	local radio_by_name = {}
	for _, r in ipairs(M.get_radio_table()) do radio_by_name[r.name] = r end

	local vaps = {}
	cursor:foreach("wireless", "wifi-iface", function(s)
		-- Skip foreign SSIDs that are switched off: a disabled section with no
		-- wlanconf id is not openUF's and is not on the air (typically
		-- OpenWrt's stock "OpenWrt" default_radioN sections, which
		-- use_only_unifi_wlan disables during provisioning). Reporting them
		-- claimed a VAP per radio that has no BSS, and -- because the nested
		-- sta_table is built per radio, not per BSS -- attributed every one of
		-- that radio's real stations to the phantom VAP as well, duplicating
		-- their traffic and retry counters across two vap_table entries.
		-- Confirmed on real hardware: a device with one live SSID reported
		-- four VAPs, the two "OpenWrt" ones carrying identical station counts
		-- and counters to the live ones.
		--
		-- A disabled vap that IS openUF-managed stays in the report: that is
		-- how a WLAN the controller itself disabled keeps showing up as
		-- disabled rather than vanishing.
		--
		-- The wireless uplink's sections come first: the station is a VAP of
		-- its own kind here (usage=uplink), disabled or not.
		if s.openuf_backhaul == "uplink" or s.openuf_backhaul == "downlink" then
			vaps[#vaps + 1] = backhaul_vap(s, radio_by_name[s.device])
			return
		end
		if s.disabled == "1" and not s.openuf_wlanconf_id then return end
		-- Only access points are VAPs. A mesh point or a station interface has
		-- no SSID to report and is not a BSS the controller can provision; it
		-- went out as a nameless phantom VAP with no clients. An absent mode
		-- is OpenWrt's default of "ap".
		if s.mode ~= nil and s.mode ~= "ap" then return end
		local radio = radio_by_name[s.device]
		-- THIS VAP's netdev, not the radio's first one. Two SSIDs on a radio
		-- have two BSSIDs -- netifd derives the second from the first with the
		-- locally-administered bit set -- so resolving the radio here reported
		-- both VAPs on one BSSID, and the controller saw two BSSes claiming the
		-- same address. The per-VAP lookup already existed for sta_table; this
		-- field was left on the per-radio one. Unresolvable stays "", never a
		-- neighbour's address.
		local bssid = ""
		local ok_if, ifname = pcall(M.get_ifname_for_vap, s.device, s.ssid)
		if ok_if and ifname then
			local mac_raw = M._read_file("/sys/class/net/" .. ifname .. "/address")
			if mac_raw then bssid = mac_raw:match("^([%x:]+)") or "" end
		end
		vaps[#vaps + 1] = {
			name          = s[".name"],
			essid         = s.ssid,
			-- "radio" must be the band identifier ("ng"/"na"), not the UCI
			-- device name -- confirmed via the controller's own stats
			-- pipeline (com.ubnt.service.system.QDcGUYAmLvJwylXw), which
			-- feeds vap_table's "radio" field through the same band-parsing
			-- enum (com.ubnt.g.f.e.rYtJfMBbtgWvku) already fixed for
			-- radio_table -- sending "radio0" here instead of "ng" logs
			-- "unexpected radio[radio0] while processing stats" on every
			-- inform and silently drops that vap's per-station stats
			-- aggregation. "radio_name" (the UCI device name) is a
			-- separate, real field on the same DTO -- kept here unchanged.
			radio         = radio and radio.radio,
			radio_name    = s.device,
			encryption    = s.encryption,
			disabled      = (s.disabled == "1"),
			bssid         = bssid,
			channel       = radio and radio.channel,
			tx_power      = radio and radio.tx_power,
			usage         = "user",
			-- "id" must echo the controller's wlanconf ObjectId (delivered in
			-- system_cfg as aaa.<n>.id, stashed by wlan_add): the controller's
			-- vapInformProcessor silently drops any usage=user vap whose "id"
			-- is missing -- discarding the nested sta_table with it, which
			-- kept every wireless client out of the Clients list. The
			-- controller derives wlanconf_id itself from "id", but the real
			-- DTO carries both, so send both. (Previously this sent the
			-- *networkconf* id as wlanconf_id -- a different object; that id
			-- stays in its own UCI option for the VLAN/mobility-domain logic.)
			id            = s.openuf_wlanconf_id,
			wlanconf_id   = s.openuf_wlanconf_id,
			-- Internal, never serialized: report.lua collects Roaming
			-- Assistant's observations from it and removes it.
			roam_assist_rssi = tonumber(s.openuf_roam_assist),
			-- Internal, never serialized: WiFi Speed Limit (kbps), for
			-- inform's _shaper_resync.
			ratelimit_down = tonumber(s.openuf_ratelimit_down),
			ratelimit_up   = tonumber(s.openuf_ratelimit_up),
		}
	end)
	return vaps
end

return M
