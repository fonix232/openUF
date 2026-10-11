--[[
	migrate.lua -- moves a tarball install's conf.lua (openUF before it was an
	OpenWrt package) into UCI, once. The package's pre-install keeps the old
	file as /etc/openuf/conf.lua.legacy and its uci-defaults runs

	    cd /usr/share/openuf && lua migrate.lua /etc/openuf/conf.lua.legacy

	Only what differs from config.lua's defaults is written, so later default
	changes still reach an upgraded device. The research options go where
	they now live: debug_caps's numbers to the `debug` section, and
	debug_payload_extra (an arbitrary table) to /etc/openuf/local.json.
]]--

local M = {}

local config = require("config")
M._config = config

-- The legacy options that were off when the line was missing: the old daemon
-- tested these two for truth, every other boolean for `== false`.
M.ABSENT_MEANS_OFF = {use_only_unifi_wlan = true, rrm_enrichment = true}

-- The legacy file's config table and the model map it named. Evaluated with
-- dofile stubbed: the model map ran board detection, which is not wanted here.
function M.read(src)
	local name = src:match('\ndev%s*=%s*dofile%(%s*"modelmap/([%w_.-]+)%.lua"%s*%)')
	local env = setmetatable({dofile = function() return {openuf = {uap = {}}, conf = {net = {}}} end},
		{__index = _G})
	local chunk = loadstring(src, "=conf.lua")
	if not chunk then return {}, name end
	setfenv(chunk, env)
	pcall(chunk)
	return type(env.config) == "table" and env.config or {}, name
end

-- UCI option -> string, for everything that differs from the defaults.
function M.options(legacy, modelmap)
	local out = {}
	-- Hand-written model maps are gone: every board is described from its
	-- own board.json (openwrt/board.lua). Worth a line in the log.
	if modelmap and modelmap ~= "auto" then
		io.stderr:write("openuf: conf.lua named model map " .. modelmap .. "; the board is now "
			.. "described automatically (openwrt/board.lua)\n")
	end
	for _, o in ipairs(config.OPTIONS) do
		local name, kind, default = o[1], o[2], o[3]
		local v = legacy[name]
		if v == nil and M.ABSENT_MEANS_OFF[name] then v = false end
		if v ~= nil and v ~= default then
			if kind == "bool" then
				out[name] = v and "1" or "0"
			elseif type(v) == "string" or type(v) == "number" then
				out[name] = tostring(v)
			end
		end
	end
	local g = legacy.controller_system
	for _, part in ipairs({"timezone", "ntp", "cron"}) do
		if g == false or (type(g) == "table" and g[part] == false) then
			out["system_" .. part] = "0"
		end
	end
	if legacy.unhandled_file == false then out.unhandled_file = "off" end
	if legacy.bootstrap_adopt_user then out.ssh_adopt = "1" end
	return out
end

-- The `debug` section's options for a legacy debug_caps table: only the
-- numbers (anything else was never claimed: report.lua took tonumber()).
function M.debug_options(legacy)
	local out = {}
	if type(legacy.debug_caps) ~= "table" then return out end
	for _, o in ipairs(config.DEBUG_OPTIONS) do
		local v = legacy.debug_caps[o[1]]
		local n = type(v) == "number" and config.CHECK.caps(v) or nil
		if n then out[o[1]] = string.format("0x%x", n) end
	end
	return out
end

-- local.json text for a legacy debug_payload_extra, or nil when unset.
function M.local_json(legacy)
	local extra = legacy.debug_payload_extra
	if type(extra) ~= "table" or next(extra) == nil then return nil end
	local ok, s = pcall(require("cjson").encode, {config = {debug_payload_extra = extra}})
	return ok and (s .. "\n") or nil
end

-- Write it all. Returns the options set, for the log.
function M.apply(path, cursor)
	local f = io.open(path, "r")
	if not f then return nil end
	local legacy, modelmap = M.read(f:read("*a"))
	f:close()
	local opts = M.options(legacy, modelmap)
	cursor = cursor or require("uci").cursor()
	if not cursor:get(config.PACKAGE, config.SECTION) then
		cursor:set(config.PACKAGE, config.SECTION, "openuf")
	end
	local keys = {}
	for k, v in pairs(opts) do
		cursor:set(config.PACKAGE, config.SECTION, k, v)
		keys[#keys + 1] = k .. "=" .. v
	end
	local dbg = M.debug_options(legacy)
	if next(dbg) then
		if not cursor:get(config.PACKAGE, "debug") then cursor:set(config.PACKAGE, "debug", "debug") end
		for k, v in pairs(dbg) do
			cursor:set(config.PACKAGE, "debug", k, v)
			keys[#keys + 1] = "debug." .. k .. "=" .. v
		end
	end
	cursor:commit(config.PACKAGE)
	local extra = M.local_json(legacy)
	local lf_path = M._config.JSON_FILE
	if extra and not config._exists(lf_path) then
		local lf = io.open(lf_path, "w")
		if lf then lf:write(extra); lf:close() end
	end
	table.sort(keys)
	return keys
end

if not OPENUF_TEST_MODE and arg and arg[1] then
	local keys = M.apply(arg[1])
	if keys then
		print("openuf: moved " .. arg[1] .. " into /etc/config/openuf"
			.. (#keys > 0 and (": " .. table.concat(keys, " ")) or " (all defaults)"))
	end
end

return M
