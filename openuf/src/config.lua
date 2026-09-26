--[[
	config.lua -- openUF's settings, from UCI: /etc/config/openuf, section
	`main` (type `openuf`).

	Every option has a default, so an empty or missing section is a working
	configuration; `uci set openuf.main.<option>=<value>` plus a service reload
	(procd reloads on its own when LuCI or `uci commit` changes the file) is
	all a change takes. USAGE.md documents each option.

	Returns the two tables the daemon has always worked from:
	  dev     the device description (openwrt/board.lua): ports, radios, LED,
	          and the UniFi identity presented (dev.identity)
	  config  the options, typed

	/etc/openuf/local.lua, when present, runs after UCI is read, with `dev`
	and `config` as globals, and may change either. It is for what UCI does
	not express well -- the research-only table options (debug_caps,
	debug_payload_extra), a radio policy, or a correction to what the board
	description got wrong -- not for everyday settings.
]]--

local M = {}

M.PACKAGE    = "openuf"
M.SECTION    = "main"
M.LOCAL_FILE = "/etc/openuf/local.lua"
M.SSH_ADOPT_USER = "ubnt"

-- name, type, default. A string option set to "" counts as unset.
M.OPTIONS = {
	-- Controller
	{"inform_url",              "string", "http://unifi:8080/inform"},
	{"l2_announce",             "bool",   true},
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
	{"rrm_enrichment",          "bool",   true},
	{"rrm_request_interval",    "int",    600},
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

local BOOL = {
	["1"] = true, ["true"] = true, ["yes"] = true, ["on"] = true, ["enabled"] = true,
	["0"] = false, ["false"] = false, ["no"] = false, ["off"] = false, ["disabled"] = false,
}

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

M._dofile = dofile
M._describe = function() return require("openwrt.board").describe() end

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

-- The raw `main` section, or {} when UCI or the section is missing.
function M.section(cursor)
	cursor = cursor or M._cursor()
	local ok, s = pcall(function() return cursor and cursor:get_all(M.PACKAGE, M.SECTION) end)
	return (ok and type(s) == "table") and s or {}
end

-- One option, typed, without loading a model map: for the hooks, which only
-- need a path or two.
function M.get(name, cursor)
	for _, o in ipairs(M.OPTIONS) do
		if o[1] == name then return M.parse(o[2], M.section(cursor)[name], o[3], name) end
	end
	return nil
end

-- The options table the daemon reads (cfg.config).
function M.options(s)
	local config = {}
	for _, o in ipairs(M.OPTIONS) do
		config[o[1]] = M.parse(o[2], s[o[1]], o[3], o[1])
	end
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
	if config.unhandled_file and BOOL[config.unhandled_file:lower()] == false then
		config.unhandled_file = false
	end
	config.bootstrap_adopt_user = config.ssh_adopt and M.SSH_ADOPT_USER or nil
	return config
end

-- dev, config: the device description (openwrt/board.lua, derived from the
-- board itself) and the options.
function M.load(cursor)
	local s = M.section(cursor)
	local config = M.options(s)
	local dev = M._describe()
	if M._exists(M.LOCAL_FILE) then
		local prev_dev, prev_config = rawget(_G, "dev"), rawget(_G, "config")
		_G.dev, _G.config = dev, config
		local ok, err = pcall(M._dofile, M.LOCAL_FILE)
		if not ok then M._warn(M.LOCAL_FILE .. ": " .. tostring(err)) end
		dev, config = _G.dev, _G.config
		_G.dev, _G.config = prev_dev, prev_config
	end
	return dev, config
end

return M
