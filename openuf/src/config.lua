--[[
	config.lua -- openUF's settings: the schema, and the three layers it is
	read from, lowest first.

	  1. the board description   openwrt/board.lua, derived from the device
	                             (board.json, the bridge, /sys/class/leds)
	  2. UCI                     /etc/config/openuf
	  3. local.json              /etc/openuf/local.json, a JSON object for
	                             what UCI cannot express (an arbitrary table)

	Each layer overrides the one below it. USAGE.md § 3 is the reference for
	every option, section and key, written so another implementation (the
	Rust daemon) can follow it exactly; this file is the Lua one.

	UCI sections (each has a fixed name; any other section is warned about
	and ignored):

	  config openuf 'main'        M.OPTIONS              -> config.<option>
	  config board 'board'        M.BOARD_OPTIONS        -> dev.conf.led, .hwassign
	  config radio_policy 'ng'|'na'  M.POLICY_OPTIONS    -> dev.conf.radio.<band>
	  config debug 'debug'        M.DEBUG_OPTIONS        -> config.debug_caps

	A value that does not parse is logged and treated as unset (an option's
	default; for board, radio_policy and debug: absent).

	local.json is {"config": {...}, "dev": {...}}, applied as an RFC 7396
	JSON merge patch over the two tables. It is validated as a whole before
	any of it is used: a parse or type error is logged loudly and the file
	is ignored entirely; an unknown key is logged and dropped.

	/etc/openuf/local.lua -- executable Lua with `dev` and `config` as
	globals -- is DEPRECATED: still run, last, for this release, with a
	warning at every start.

	Returns the two tables the daemon has always worked from:
	  dev     the device description: dev.conf (net, led, hwassign, radio)
	          and dev.identity (the UniFi model presented)
	  config  the options, typed
]]--

local M = {}

M.PACKAGE    = "openuf"
M.SECTION    = "main"
M.JSON_FILE  = "/etc/openuf/local.json"
M.LOCAL_FILE = "/etc/openuf/local.lua"   -- deprecated
M.SSH_ADOPT_USER = "ubnt"

-- name, type, default. A string option set to "" counts as unset.
M.OPTIONS = {
	-- Controller
	{"inform_url",              "string", "http://unifi:8080/inform"},
	{"l2_announce",             "bool",   true},
	-- Answer clients' v1 discovery probes (WiFiman, UniFi app). Off: with it
	-- the UniFi app took the APs for standalone devices (needs l2_announce).
	{"discovery_replies",       "bool",   false},
	{"ssh_adopt",               "bool",   false},
	{"stun",                    "bool",   true},
	{"stun_local_port",         "int",    3478},
	{"cfg_retries",             "int",    2},
	-- What the controller owns
	{"use_only_unifi_wlan",     "bool",   true},
	{"own_config",              "bool",   true},
	{"bridge_backend",          "string", "auto"},
	{"bridge_takeover",         "bool",   true},
	{"bridge_rollback_timeout", "int",    180},
	{"bridge_name",             "string", "br-lan"},
	{"port_default",            "string", "all"},
	{"country_override",        "string", nil},
	-- Controller features
	{"sta_events",              "bool",   true},
	{"system_timezone",         "bool",   true},
	{"system_ntp",              "bool",   true},
	{"system_cron",             "bool",   true},
	{"l2guard",                 "bool",   true},
	{"guest_isolation",         "bool",   true},
	{"rrm_enrichment",          "bool",   true},
	{"rrm_request_interval",    "int",    600},
	-- Neighbouring openUF APs: the BSSID exchange (openwrt/siblings.lua) and
	-- the off-channel scan of a radio with no clients (openwrt/idlescan.lua),
	-- seconds between scans, 0 = never.
	{"sibling_exchange",        "bool",   true},
	{"idle_scan_interval",      "int",    1800},
	-- ...and the short scan of only the siblings' channels, which runs with
	-- clients associated.
	{"sibling_scan_interval",   "int",    1800},
	-- The wireless uplink (mesh): claim the controller's mesh bits, so it
	-- pushes the hidden WDS downlink and the 4-address uplink station
	-- (unifi/mesh.lua, openwrt/backhaul.lua). Off: unconfirmed on this
	-- project's hardware, and it changes every AP's 5 GHz radio.
	{"wireless_uplink",         "bool",   false},
	-- Roaming Assistant: how much louder (dB) another AP must hear a weak
	-- client before it is moved there. The threshold is the controller's.
	{"roam_assist_diff_db",     "int",    8},
	-- Firmware upgrades
	{"upgrade_mode",            "string", nil},
	{"advertise_updates",       "bool",   false},
	{"advertise_interval",      "int",    6 * 3600},
	{"version_scheme",          "string", nil},
	-- Files and diagnostics
	{"state_file",              "string", "/etc/openuf/state.json"},
	{"unhandled_file",          "string", "/etc/openuf/unhandled.json"},
	{"debug_dump_file",         "string", nil},
	{"debug_dump_requests",     "bool",   false},
	{"debug_dump_max_bytes",    "int",    4 * 1024 * 1024},
}

-- config board 'board': corrections to the board description (dev.conf).
-- name, type. Absent: board.lua's own answer.
M.BOARD_OPTIONS = {
	{"led",      "led"},          -- the status LED Locate blinks
	{"hwassign", "radio_list"},   -- the radios to report (UCI list)
}

-- config radio_policy '<band>': dev.conf.radio.<band>. UCI name, type, key.
M.BANDS = {"ng", "na"}           -- 2.4 GHz; 5 and 6 GHz
M.POLICY_OPTIONS = {
	{"htmode_max",      "htmode",       "htmode_max"},
	{"htmode_floor",    "htmode",       "htmode_floor"},
	{"acs_exclude_dfs", "bool",         "acs_exclude_dfs"},
	{"channel",         "channel_list", "channels"},
}

-- config debug 'debug': research-only capability overrides (config.debug_caps).
M.DEBUG_OPTIONS = {
	{"fw_caps",    "caps"},
	{"wifi_caps",  "caps"},
	{"wifi_caps2", "caps"},
}

-- Section type -> the name it must have (radio_policy: one of M.BANDS).
M.SECTION_NAMES = {openuf = "main", board = "board", debug = "debug"}

local BOOL = {
	["1"] = true, ["true"] = true, ["yes"] = true, ["on"] = true, ["enabled"] = true,
	["0"] = false, ["false"] = false, ["no"] = false, ["off"] = false, ["disabled"] = false,
}

local HT_WIDTHS = {["20"] = true, ["40"] = true}
local WIDTHS = {["20"] = true, ["40"] = true, ["80"] = true, ["160"] = true, ["320"] = true}
local PHY = {HT = HT_WIDTHS, VHT = WIDTHS, HE = WIDTHS, EHT = WIDTHS}

M._warn = function(msg) io.stderr:write("openuf: config: " .. msg .. "\n") end

M._cursor = function()
	local ok, uci = pcall(require, "uci")
	return ok and uci.cursor() or nil
end

M._exists = function(path)
	local f = io.open(path, "r")
	if f then f:close() end
	return f ~= nil
end

M._read = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

M._dofile = dofile
M._describe = function() return require("openwrt.board").describe() end

-- ─── Value checks, shared by the UCI and the local.json readers ─────────────

local function is_int(v)
	return type(v) == "number" and v == math.floor(v) and v > -math.huge and v < math.huge
end

-- Each returns the value as stored, or nil and why not.
local CHECK = {}

function CHECK.htmode(v)
	if type(v) ~= "string" then return nil, "not a string" end
	local kind, width = v:match("^(%u+)(%d+)$")
	if not (kind and PHY[kind] and PHY[kind][width]) then
		return nil, "not an htmode (HT20/40, VHT/HE/EHT 20/40/80/160/320)"
	end
	return v
end

function CHECK.channel(v)
	local n = v
	if type(v) == "string" and v:match("^%d+$") then n = tonumber(v) end
	if not (is_int(n) and n >= 1 and n <= 233) then return nil, "not a channel number (1-233)" end
	return n
end

function CHECK.radio(v)
	if type(v) ~= "string" or not v:match("^[%w_]+$") then
		return nil, "not a wifi-device name ([A-Za-z0-9_])"
	end
	return v
end

function CHECK.led(v)
	if type(v) ~= "string" or not v:match("^[%w][%w_:%.%-@+]*$") or v:find("..", 1, true) then
		return nil, "not an LED name from /sys/class/leds"
	end
	return v
end

-- A capability bitmask: a whole number >= 0; in UCI also 0x-prefixed hex.
function CHECK.caps(v)
	local n = v
	if type(v) == "string" then
		if v:match("^0[xX]%x+$") then n = tonumber(v:sub(3), 16)
		elseif v:match("^%d+$") then n = tonumber(v)
		else n = nil end
	end
	if not (is_int(n) and n >= 0) then return nil, "not a whole number >= 0 (decimal or 0x hex)" end
	return n
end
M.CHECK = CHECK

-- ─── UCI ─────────────────────────────────────────────────────────────────────

-- One raw UCI value as its option's type; the default for anything unset or
-- unreadable (a typo must not take a feature away silently, so it is logged).
function M.parse(kind, raw, default, name)
	if type(raw) == "table" then raw = raw[#raw] end   -- a list where an option belongs
	if raw == nil or raw == "" then return default end
	if kind == "bool" then
		local v = BOOL[tostring(raw):lower()]
		if v == nil then
			M._warn(("%s: %q is not a boolean, using %s"):format(name, raw, tostring(default)))
			return default
		end
		return v
	elseif kind == "int" then
		local v = tonumber(raw)
		if not v or v ~= math.floor(v) then
			M._warn(("%s: %q is not a whole number, using %s"):format(name, raw, tostring(default)))
			return default
		end
		return v
	end
	return tostring(raw)
end

-- A raw UCI list (or an option holding space-separated words) as a table of
-- checked values; nil, logged, when any element fails (a partial list is a
-- different setting from the one written).
local function parse_list(raw, check, name)
	if raw == nil or raw == "" then return nil end
	local words = {}
	if type(raw) == "table" then
		for _, w in ipairs(raw) do words[#words + 1] = w end
	else
		for w in tostring(raw):gmatch("%S+") do words[#words + 1] = w end
	end
	if #words == 0 then return nil end
	local out = {}
	for _, w in ipairs(words) do
		local v, why = check(w)
		if v == nil then
			M._warn(("%s: %q is %s, ignoring the whole list"):format(name, tostring(w), why))
			return nil
		end
		out[#out + 1] = v
	end
	return out
end

-- A raw scalar for the board/radio_policy/debug sections: the checked value,
-- or nil (absent) when unset or invalid (logged).
local function parse_scalar(kind, raw, name)
	if type(raw) == "table" then raw = raw[#raw] end
	if raw == nil or raw == "" then return nil end
	if kind == "bool" then
		local v = BOOL[tostring(raw):lower()]
		if v == nil then M._warn(("%s: %q is not a boolean, ignored"):format(name, raw)) end
		return v
	end
	local v, why = CHECK[kind](raw)
	if v == nil then M._warn(("%s: %q is %s, ignored"):format(name, tostring(raw), why)) end
	return v
end

-- The raw `main` section, or {} when UCI or the section is missing.
function M.section(cursor)
	cursor = cursor or M._cursor()
	local ok, s = pcall(function() return cursor and cursor:get_all(M.PACKAGE, M.SECTION) end)
	return (ok and type(s) == "table") and s or {}
end

-- Every section of the package, by name ({} when UCI is missing).
function M.sections(cursor)
	cursor = cursor or M._cursor()
	local ok, all = pcall(function() return cursor and cursor:get_all(M.PACKAGE) end)
	return (ok and type(all) == "table") and all or {}
end

local function known_names(list)
	local t = {}
	for _, o in ipairs(list) do t[o[1]] = true end
	return t
end

local function warn_unknown_options(s, known, where)
	local names = {}
	for k in pairs(s) do
		if type(k) == "string" and k:sub(1, 1) ~= "." and not known[k] then names[#names + 1] = k end
	end
	table.sort(names)
	for _, k in ipairs(names) do M._warn(("%s: unknown option '%s', ignored"):format(where, k)) end
end

local function is_band(name)
	for _, b in ipairs(M.BANDS) do if b == name then return true end end
	return false
end

-- The whole package, sorted into its sections: {main = raw, board = raw,
-- debug = raw, policies = {band = raw}}. Sections of an unknown type, or of a
-- known type under any other name, are logged and left out.
function M.classify(all)
	local out = {main = {}, board = {}, debug = {}, policies = {}}
	local names = {}
	for name in pairs(all or {}) do if type(name) == "string" then names[#names + 1] = name end end
	table.sort(names)
	for _, name in ipairs(names) do
		local s = all[name]
		local stype = type(s) == "table" and s[".type"] or nil
		local where = ("section '%s' (%s)"):format(name, tostring(stype))
		if stype == "radio_policy" then
			if is_band(name) then
				out.policies[name] = s
			else
				M._warn(where .. ": a radio_policy is named after its band, "
					.. table.concat(M.BANDS, " or ") .. "; ignored")
			end
		elseif M.SECTION_NAMES[stype] then
			if name == M.SECTION_NAMES[stype] then
				out[stype == "openuf" and "main" or stype] = s
			else
				M._warn(("%s: this section must be named '%s'; ignored")
					:format(where, M.SECTION_NAMES[stype]))
			end
		else
			M._warn(where .. ": unknown section type, ignored")
		end
	end
	return out
end

-- config board 'board' -> {led = ..., hwassign = {...}} (absent keys: none).
function M.board(s)
	s = s or {}
	warn_unknown_options(s, known_names(M.BOARD_OPTIONS), "board")
	local out = {}
	out.led = parse_scalar("led", s.led, "board.led")
	out.hwassign = parse_list(s.hwassign, CHECK.radio, "board.hwassign")
	return out
end

-- One radio_policy section -> a RadioPolicy, or nil when it sets nothing
-- valid: an empty section is no policy (the consumer treats a present entry,
-- even an empty one, as the band's owner of acs_exclude_dfs and channels).
function M.policy(s, band)
	s = s or {}
	local where = "radio_policy." .. band
	warn_unknown_options(s, known_names(M.POLICY_OPTIONS), where)
	local p, any = {}, false
	for _, o in ipairs(M.POLICY_OPTIONS) do
		local v
		if o[2] == "channel_list" then
			v = parse_list(s[o[1]], CHECK.channel, where .. "." .. o[1])
		else
			v = parse_scalar(o[2], s[o[1]], where .. "." .. o[1])
		end
		if v ~= nil then p[o[3]] = v; any = true end
	end
	return any and p or nil
end

-- config debug 'debug' -> debug_caps table, or nil when none is set.
function M.debug_caps(s)
	s = s or {}
	warn_unknown_options(s, known_names(M.DEBUG_OPTIONS), "debug")
	local caps, any = {}, false
	for _, o in ipairs(M.DEBUG_OPTIONS) do
		local v = parse_scalar(o[2], s[o[1]], "debug." .. o[1])
		if v ~= nil then caps[o[1]] = v; any = true end
	end
	return any and caps or nil
end

-- The `main` options, typed, before the derived fields.
function M.typed(s)
	s = s or {}
	local config = {}
	for _, o in ipairs(M.OPTIONS) do
		config[o[1]] = M.parse(o[2], s[o[1]], o[3], o[1])
	end
	return config
end

-- The fields computed from the options, once every layer is in.
function M.derive(config)
	-- sysconf.lua's gate: true, false, or the parts that are on.
	local t, n, c = config.system_timezone, config.system_ntp, config.system_cron
	if t and n and c then
		config.controller_system = true
	elseif not (t or n or c) then
		config.controller_system = false
	else
		config.controller_system = {timezone = t, ntp = n, cron = c}
	end
	-- "off" (or 0/false) keeps the unhandled ledger in memory only.
	if type(config.unhandled_file) == "string" and BOOL[config.unhandled_file:lower()] == false then
		config.unhandled_file = false
	end
	config.bootstrap_adopt_user = config.ssh_adopt and M.SSH_ADOPT_USER or nil
	return config
end

-- The options table the daemon reads (cfg.config), from the `main` section.
function M.options(s)
	return M.derive(M.typed(s))
end

-- ─── local.json ──────────────────────────────────────────────────────────────

local json, NULL
do
	local ok, cjson = pcall(require, "cjson")
	if ok then json, NULL = cjson, cjson.null end
end
M.NULL = NULL

-- `[]` and `{}` both decode to an empty Lua table, and the merge must tell
-- them apart (an array replaces, an object merges). OpenWrt's lua-cjson
-- (2.1.0) has no array marking, so before decoding every empty array outside
-- a string becomes a one-element array holding a sentinel no JSON text can
-- produce by accident, and after decoding each of those becomes an empty
-- table carrying EMPTY_ARRAY as its metatable.
local EMPTY_ARRAY = {}
local EMPTY_SENTINEL = "\0openuf:empty-array"
local EMPTY_JSON = '["\\u0000openuf:empty-array"]'

function M._mark_empty_arrays(text)
	local out, start, i, n, in_str = {}, 1, 1, #text, false
	while i <= n do
		local ch = text:sub(i, i)
		if in_str then
			if ch == "\\" then i = i + 1 elseif ch == '"' then in_str = false end
		elseif ch == '"' then
			in_str = true
		elseif ch == "[" then
			local j = text:find("[^ \t\r\n]", i + 1)
			if j and text:sub(j, j) == "]" then
				out[#out + 1] = text:sub(start, i - 1)
				out[#out + 1] = EMPTY_JSON
				start, i = j + 1, j
			end
		end
		i = i + 1
	end
	out[#out + 1] = text:sub(start)
	return table.concat(out)
end

local function unmark(v)
	if type(v) ~= "table" then return v end
	if v[1] == EMPTY_SENTINEL and next(v, 1) == nil then return setmetatable({}, EMPTY_ARRAY) end
	for k, x in pairs(v) do v[k] = unmark(x) end
	return v
end

function M._decode(text)
	return unmark(json.decode(M._mark_empty_arrays(text)))
end

-- A JSON array, as decoded.
local function is_array(v)
	if type(v) ~= "table" then return false end
	return getmetatable(v) == EMPTY_ARRAY or v[1] ~= nil
end

local function is_object(v)
	return type(v) == "table" and not is_array(v)
end

local function copy(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = copy(x) end
	return setmetatable(t, getmetatable(v))
end

-- RFC 7396 JSON Merge Patch: an object merges key by key, a null member
-- removes the key, anything else (scalar, array) replaces. Returns the result;
-- `target` is changed in place when it is an object.
function M.merge_patch(target, patch)
	if not is_object(patch) then return copy(patch) end
	if not is_object(target) then target = {} end
	for k, v in pairs(patch) do
		if v == NULL then
			target[k] = nil
		else
			target[k] = M.merge_patch(target[k], v)
		end
	end
	return target
end

-- Validation. Each checker takes (value, path, errs, warns) and returns the
-- value to merge (unknown keys dropped), appending to errs (the file is then
-- rejected) or warns (the key is dropped). Null is handled by the caller.

local function err(errs, path, why) errs[#errs + 1] = path .. ": " .. why end

local function keys_sorted(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

-- An object of known keys: spec[key] = {check = fn, nullable = bool}.
local function object_of(spec)
	return function(v, path, errs, warns)
		if not is_object(v) then err(errs, path, "must be an object"); return nil end
		local out = {}
		for _, k in ipairs(keys_sorted(v)) do
			local x, s = v[k], spec[k]
			local p = path .. "." .. tostring(k)
			if not s then
				warns[#warns + 1] = p .. ": unknown key, ignored"
			elseif x == NULL then
				if s.nullable then out[k] = NULL else err(errs, p, "cannot be null") end
			else
				out[k] = s.check(x, p, errs, warns)
			end
		end
		return out
	end
end

-- JSON scalars carry their own type: a number is never a string here.
local function scalar(kind)
	return function(v, path, errs)
		local why
		if kind == "bool" then
			if type(v) ~= "boolean" then why = "must be true or false" end
		elseif kind == "int" then
			if not is_int(v) then why = "must be a whole number" end
		elseif kind == "string" then
			if type(v) ~= "string" then why = "must be a string" end
		elseif (kind == "channel" or kind == "caps") and type(v) ~= "number" then
			why = "must be a number"
		else
			local ok, w = CHECK[kind](v)
			if ok == nil then why = w end
		end
		if why then err(errs, path, why) end
		return v
	end
end

local function array_of(check)
	return function(v, path, errs, warns)
		if not is_array(v) then
			err(errs, path, "must be an array"); return nil
		end
		for i, x in ipairs(v) do check(x, path .. "[" .. (i - 1) .. "]", errs, warns) end
		return v
	end
end

-- Any object, taken as written.
local function any_object(v, path, errs)
	if not is_object(v) then err(errs, path, "must be an object") end
	return v
end

local POLICY_SPEC = {
	htmode_max      = {check = scalar("htmode"),  nullable = true},
	htmode_floor    = {check = scalar("htmode"),  nullable = true},
	acs_exclude_dfs = {check = scalar("bool"),    nullable = true},
	channels        = {check = array_of(scalar("channel")), nullable = true},
}
local RADIO_SPEC = {}
for _, b in ipairs(M.BANDS) do RADIO_SPEC[b] = {check = object_of(POLICY_SPEC), nullable = true} end

local NET_SPEC = {
	lan_name     = {check = scalar("string"), nullable = true},
	lan_cpueth   = {check = scalar("string"), nullable = true},
	wan_cpueth   = {check = scalar("string"), nullable = true},
	lan_vlanid   = {check = scalar("int"),    nullable = true},
	identity_mac = {check = scalar("string"), nullable = true},
	ports        = {check = array_of(object_of({
		idx    = {check = scalar("int")},
		ifname = {check = scalar("string")},
	})), nullable = false},
}

local CONF_SPEC = {
	net      = {check = object_of(NET_SPEC)},
	led      = {check = scalar("led"), nullable = true},
	hwassign = {check = array_of(scalar("radio")), nullable = true},
	radio    = {check = object_of(RADIO_SPEC), nullable = true},
}

local DEV_SPEC = {
	conf     = {check = object_of(CONF_SPEC)},
	identity = {check = any_object},
}

local CONFIG_SPEC = {
	debug_caps = {check = object_of({
		fw_caps    = {check = scalar("caps"), nullable = true},
		wifi_caps  = {check = scalar("caps"), nullable = true},
		wifi_caps2 = {check = scalar("caps"), nullable = true},
	}), nullable = true},
	debug_payload_extra = {check = any_object, nullable = true},
}
for _, o in ipairs(M.OPTIONS) do
	CONFIG_SPEC[o[1]] = {check = scalar(o[2]), nullable = true}
end

local TOP_SPEC = {
	config = {check = object_of(CONFIG_SPEC)},
	dev    = {check = object_of(DEV_SPEC)},
}
M._validate = object_of(TOP_SPEC)

-- Parse and validate local.json text. Returns the patch ({config =, dev =},
-- unknown keys removed) and the warnings, or nil and the errors.
function M.check_json(text)
	if not json then return nil, {"lua-cjson is not available"} end
	local ok, doc = pcall(M._decode, text)
	if not ok then return nil, {"not valid JSON: " .. tostring(doc)} end
	local errs, warns = {}, {}
	local patch = M._validate(doc, "local.json", errs, warns)
	if #errs > 0 then return nil, errs end
	return patch, warns
end

-- The checked patch from M.JSON_FILE, or nil when the file is absent or
-- rejected (said loudly: a whole file of settings is being ignored).
function M.read_json(path)
	path = path or M.JSON_FILE
	if not M._exists(path) then return nil end
	local text = M._read(path)
	if not text then
		M._warn(path .. ": cannot be read; IGNORED")
		return nil
	end
	local patch, notes = M.check_json(text)
	if not patch then
		M._warn(("%s: REJECTED, none of it is applied:"):format(path))
		for _, n in ipairs(notes) do M._warn("  " .. n) end
		return nil
	end
	for _, n in ipairs(notes) do M._warn(path .. ": " .. n) end
	return patch
end

-- Merge a checked patch over config and dev. An option set to null (or a
-- string option to "", as in UCI) goes back to its built-in default;
-- everything else is a merge patch.
function M.apply_json(patch, config, dev)
	local opt = {}
	for _, o in ipairs(M.OPTIONS) do opt[o[1]] = o end
	for k, v in pairs(patch.config or {}) do
		local o = opt[k]
		if o and (v == NULL or (o[2] == "string" and v == "")) then
			config[k] = o[3]
		elseif v == NULL then
			config[k] = nil
		else
			config[k] = M.merge_patch(config[k], v)
		end
	end
	if patch.dev then
		-- The identity is the catalogue's own table: change a copy.
		if patch.dev.identity then dev.identity = copy(dev.identity) end
		M.merge_patch(dev, patch.dev)
		-- A band left with no keys has no policy, as an empty UCI section has
		-- none: rf_config treats any entry as the owner of the band's ACS options.
		local radio = dev.conf and dev.conf.radio
		if type(radio) == "table" then
			for _, b in ipairs(M.BANDS) do
				if type(radio[b]) == "table" and next(radio[b]) == nil then radio[b] = nil end
			end
		end
	end
	return config, dev
end

-- ─── Loading ─────────────────────────────────────────────────────────────────

-- One option, typed, without the board description: for the hooks, which
-- only need a path or two. UCI, then local.json.
function M.get(name, cursor)
	for _, o in ipairs(M.OPTIONS) do
		if o[1] == name then
			local v = M.parse(o[2], M.section(cursor)[name], o[3], name)
			local patch = M.read_json()
			local j = patch and patch.config and patch.config[name]
			if j == NULL or (o[2] == "string" and j == "") then return o[3] end
			if j ~= nil then return j end
			return v
		end
	end
	return nil
end

-- The UCI layer over the board description: config, and dev changed in place.
function M.from_uci(all, dev)
	local secs = M.classify(all)
	warn_unknown_options(secs.main, known_names(M.OPTIONS), "main")
	local config = M.typed(secs.main)
	config.debug_caps = M.debug_caps(secs.debug)
	dev.conf = dev.conf or {}
	local board = M.board(secs.board)
	if board.led then dev.conf.led = board.led end
	if board.hwassign then dev.conf.hwassign = board.hwassign end
	for _, band in ipairs(M.BANDS) do
		local p = secs.policies[band] and M.policy(secs.policies[band], band)
		if p then
			dev.conf.radio = dev.conf.radio or {}
			dev.conf.radio[band] = p
		end
	end
	return config, dev
end

-- The deprecated local.lua: run with `dev` and `config` as globals, as it
-- always was, after everything else.
local function run_local_lua(dev, config)
	M._warn(M.LOCAL_FILE .. " is DEPRECATED and will not be read by the next release. "
		.. "Move its settings to /etc/config/openuf, or to " .. M.JSON_FILE
		.. " for what UCI cannot hold (USAGE.md § 3)")
	local prev_dev, prev_config = rawget(_G, "dev"), rawget(_G, "config")
	_G.dev, _G.config = dev, config
	local ok, e = pcall(M._dofile, M.LOCAL_FILE)
	if not ok then M._warn(M.LOCAL_FILE .. ": " .. tostring(e)) end
	dev, config = _G.dev, _G.config
	_G.dev, _G.config = prev_dev, prev_config
	return dev, config
end

-- dev, config: board description < UCI < local.json (< local.lua, deprecated).
function M.load(cursor)
	local dev = M._describe()
	local config
	config, dev = M.from_uci(M.sections(cursor), dev)
	local patch = M.read_json()
	if patch then M.apply_json(patch, config, dev) end
	M.derive(config)
	if M._exists(M.LOCAL_FILE) then dev, config = run_local_lua(dev, config) end
	return dev, config
end

return M
