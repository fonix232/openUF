--[[
	migrate.lua -- moves a tarball install's conf.lua (openUF before it was an
	OpenWrt package) into UCI, once. The package's pre-install keeps the old
	file as /etc/openuf/conf.lua.legacy and its uci-defaults runs

	    cd /usr/share/openuf && lua migrate.lua /etc/openuf/conf.lua.legacy

	Only what differs from config.lua's defaults is written, so later default
	changes still reach an upgraded device. The table-valued research options
	(debug_caps, debug_payload_extra) go to /etc/openuf/local.lua instead.
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
	if modelmap and modelmap ~= "auto" then out.modelmap = modelmap end
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

local function serialize(v, indent)
	indent = indent or ""
	if type(v) == "table" then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(keys) do
			local key = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k
				or ("[" .. serialize(k) .. "]")
			parts[#parts + 1] = indent .. "\t" .. key .. " = " .. serialize(v[k], indent .. "\t") .. ","
		end
		return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
	elseif type(v) == "string" then
		return ("%q"):format(v)
	end
	return tostring(v)
end

-- local.lua source for the research options, or nil when neither is set.
function M.local_lua(legacy)
	local lines = {}
	for _, k in ipairs({"debug_caps", "debug_payload_extra"}) do
		if legacy[k] ~= nil then
			lines[#lines + 1] = "config." .. k .. " = " .. serialize(legacy[k])
		end
	end
	if #lines == 0 then return nil end
	return "-- Moved from conf.lua by the openuf package (research-only options).\n"
		.. table.concat(lines, "\n") .. "\n"
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
	cursor:commit(config.PACKAGE)
	local extra = M.local_lua(legacy)
	local lf_path = M._config.LOCAL_FILE
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
