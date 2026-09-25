--[[
	syswrapper.lua — adoption and inform-URL management hook.

	Called by syswrapper.sh when the UniFi controller SSHes in to adopt
	or reconfigure the device.

	Usage (via syswrapper.sh):
	  syswrapper.sh set-adopt  <inform_url> <authkey_hex32>
	  syswrapper.sh set-inform <inform_url>
	  syswrapper.sh reset-inform

	authkey_hex32: exactly 32 hex characters (= 16 bytes, AES-128 key).
	inform_url:    http(s)://host:port/inform

	Exit codes: 0 = success, 1 = invalid arguments.
]]--

local state

-- The state_file option (UCI openuf.main.state_file), so that this hook,
-- inform.lua and announce.lua agree on where state.json is. Read on its own:
-- config.load() would run the model map, which is not needed here.
local function conf_state_file(dir)
	local f = io.open(dir .. "config.lua", "r")
	if not f then return nil end
	f:close()
	local ok, conf = pcall(dofile, dir .. "config.lua")
	if not ok then return nil end
	local v = conf.get("state_file")
	return (type(v) == "string" and v ~= "") and v or nil
end

-- Allow the state module path to be injected for testing
local function load_state()
	if state then return state end
	-- Try relative paths: called from src/ dir or from an absolute install path
	local paths = {"state.lua", "src/state.lua", "/usr/share/openuf/state.lua"}
	for _, p in ipairs(paths) do
		local f = io.open(p, "r")
		if f then
			f:close()
			state = dofile(p)
			local sf = conf_state_file(p:match("^(.*/)") or "")
			if sf then state._state_file = sf end
			return state
		end
	end
	error("syswrapper: cannot find state.lua")
end

local function usage()
	io.stderr:write(
		"Usage: syswrapper.sh set-adopt <url> <key32hex>\n" ..
		"       syswrapper.sh set-inform <url>\n" ..
		"       syswrapper.sh reset-inform\n" ..
		"       syswrapper.sh netmodel-retry     (re-apply a rolled-back network plan)\n" ..
		"       syswrapper.sh netmodel-restore   (put the pre-openUF network and WiFi config back)\n" ..
		"       syswrapper.sh 11k-scan           (the controller's nightly neighbour scan)\n" ..
		"       syswrapper.sh upgrade <url>      (hand an upgrade to owut; the URL is not fetched)\n" ..
		"       syswrapper.sh reprovision        (have the controller re-send its full config)\n" ..
		"\n" ..
		"key32hex: exactly 32 hexadecimal characters (16 bytes, AES-128)\n"
	)
end

local function is_hex32(s)
	return type(s) == "string" and #s == 32 and s:match("^[0-9a-fA-F]+$") ~= nil
end

local function is_url(s)
	return type(s) == "string" and (s:match("^https?://") ~= nil)
end

-- ─── Commands ────────────────────────────────────────────────────────────────

-- set-adopt <url> <key>
-- Called by the controller after clicking Adopt.  Stores the new authkey
-- and marks the device as adopted.
local function cmd_set_adopt(url, key)
	if not is_url(url) then
		io.stderr:write("syswrapper: invalid URL: " .. tostring(url) .. "\n")
		return false
	end
	if not is_hex32(key) then
		io.stderr:write("syswrapper: invalid authkey (expected 32 hex chars): "
			.. tostring(key) .. "\n")
		return false
	end
	local st = load_state()
	local s  = st.load()
	s.inform_url = url
	s.authkey    = key:lower()
	s.adopted    = true
	st.save(s)
	io.stdout:write("syswrapper: adopted; inform_url=" .. url .. "\n")
	return true
end

-- set-inform <url>
-- Manually point the device at a controller URL (pre-adoption L3 setup).
local function cmd_set_inform(url)
	if not is_url(url) then
		io.stderr:write("syswrapper: invalid URL: " .. tostring(url) .. "\n")
		return false
	end
	local st = load_state()
	local s  = st.load()
	s.inform_url = url
	st.save(s)
	io.stdout:write("syswrapper: inform_url set to " .. url .. "\n")
	return true
end

-- reset-inform
-- Return to factory defaults: clears authkey and marks as un-adopted.
local function cmd_reset_inform()
	local st = load_state()
	st.reset()
	io.stdout:write("syswrapper: reset to defaults\n")
	return true
end

-- netmodel-retry
-- Forget that a network plan was rolled back, so the next push re-applies it
-- (netmodel.lua refuses a plan that lost the controller once).
local function cmd_netmodel_retry()
	local st = load_state()
	local s  = st.load()
	s.netmodel_failed, s.netmodel_failed_logged = nil, nil
	st.save(s)
	io.stdout:write("syswrapper: the next network push will be applied again\n")
	return true
end

-- netmodel-restore
-- Put back the board's own /etc/config/network from before openUF took the
-- bridge over (/etc/openuf/network.pre-openuf) and reload -- and its own
-- /etc/config/wireless (/etc/openuf/wireless.pre-openuf), when own_config
-- deleted its SSIDs. The controller will manage the AP again on its next
-- push unless openUF is stopped or the device forgotten first.
local wireless_pristine = "/etc/openuf/wireless.pre-openuf"
local function restore_wireless()
	local f = io.open(wireless_pristine, "r")
	if not f then return false end
	local saved = f:read("*a")
	f:close()
	local o = io.open("/etc/config/wireless", "w")
	if not o then return false end
	o:write(saved)
	o:close()
	os.execute("wifi reload >/dev/null 2>&1")
	return true
end

local function cmd_netmodel_restore()
	local ok, nm = pcall(dofile, "/usr/share/openuf/netmodel.lua")
	if not ok then ok, nm = pcall(dofile, "netmodel.lua") end
	if not ok then
		io.stderr:write("syswrapper: netmodel.lua not found\n")
		return false
	end
	local st = load_state()
	local s  = st.load()
	local net = nm.restore_pristine(s)
	local wifi = restore_wireless()
	if not (net or wifi) then
		io.stderr:write("syswrapper: no " .. nm.PRISTINE_FILE .. " or " .. wireless_pristine
			.. " -- openUF never took the network or the WiFi over\n")
		return false
	end
	st.save(s)
	io.stdout:write("syswrapper: restored the pre-openUF" .. (net and " network" or "")
		.. ((net and wifi) and " and" or "") .. (wifi and " wireless" or "") .. " config\n")
	return true
end

-- reprovision
-- Ask the controller for its full config again. The controller only pushes
-- when the device reports a cfgversion other than the one it expects, and it
-- deduplicates identical pushes for ten minutes, so this forgets the
-- cfgversion: the next inform reports none and the controller sends the whole
-- config. What an openUF update needs to re-apply everything with new logic.
local function cmd_reprovision()
	local st = load_state()
	local s = st.load()
	s.cfgversion = ""
	st.save(s)
	io.stdout:write("syswrapper: cfgversion cleared; the controller re-sends its config on the next inform\n")
	return true
end

-- ─── Entry point ─────────────────────────────────────────────────────────────

-- 11k-scan
-- What the controller's pushed cron job runs every night (see sysconf.lua).
-- The scan belongs to the inform daemon -- it owns the radios and the 802.11k
-- beacon-request machinery, and its next heartbeat carries the result out --
-- so this only leaves a dated request that the daemon picks up within one
-- interval and discards when it is more than ten minutes old.
local scan_request_file = "/tmp/openuf-scan-request"
local function cmd_11k_scan()
	local f = io.open(scan_request_file, "w")
	if not f then
		io.stderr:write("syswrapper: cannot write " .. scan_request_file .. "\n")
		return false
	end
	f:write(tostring(os.time()), "\n")
	f:close()
	io.stdout:write("syswrapper: neighbour scan requested\n")
	return true
end

-- upgrade <url> / upgrade2 <url>
-- The controller's SSH upgrade verb. The URL is UniFi firmware and is never
-- fetched; the inform daemon hands the request to owut when
-- config.upgrade_mode = "owut" (upgrade.lua) and refuses it otherwise.
local upgrade_request_file = "/tmp/openuf-upgrade-request"
local function cmd_upgrade(url)
	local f = io.open(upgrade_request_file, "w")
	if not f then
		io.stderr:write("syswrapper: cannot write " .. upgrade_request_file .. "\n")
		return false
	end
	f:write(tostring(os.time()), "\n")
	f:close()
	io.stdout:write("syswrapper: upgrade requested (" .. tostring(url)
		.. " is not fetched; the inform daemon decides)\n")
	return true
end

local function main(args)
	local cmd = args[1]
	if cmd == "set-adopt" then
		if not cmd_set_adopt(args[2], args[3]) then
			usage(); os.exit(1)
		end
	elseif cmd == "set-inform" then
		if not cmd_set_inform(args[2]) then
			usage(); os.exit(1)
		end
	elseif cmd == "reset-inform" then
		cmd_reset_inform()
	elseif cmd == "netmodel-retry" then
		cmd_netmodel_retry()
	elseif cmd == "netmodel-restore" then
		if not cmd_netmodel_restore() then os.exit(1) end
	elseif cmd == "11k-scan" then
		if not cmd_11k_scan() then os.exit(1) end
	elseif cmd == "reprovision" then
		cmd_reprovision()
	elseif cmd == "upgrade" or cmd == "upgrade2" then
		if not cmd_upgrade(args[2]) then os.exit(1) end
	else
		io.stderr:write("syswrapper: unknown command: " .. tostring(cmd) .. "\n")
		usage()
		os.exit(1)
	end
	os.exit(0)
end

-- When executed as a script, arg[1..] are the command-line arguments.
-- When required/dofile'd in tests, SYSWRAPPER_TEST_MODE must be set.
if not SYSWRAPPER_TEST_MODE then
	main(arg or {})
end

-- Export command functions for unit testing
return {
	cmd_set_adopt  = cmd_set_adopt,
	cmd_set_inform = cmd_set_inform,
	cmd_reset_inform = cmd_reset_inform,
	cmd_netmodel_retry = cmd_netmodel_retry,
	cmd_11k_scan = cmd_11k_scan,
	cmd_upgrade  = cmd_upgrade,
	cmd_reprovision = cmd_reprovision,
	_upgrade_request_file = function(p) upgrade_request_file = p end,
	_scan_request_file = function(p) scan_request_file = p end,
	is_hex32 = is_hex32,
	is_url   = is_url,
	_set_state = function(s) state = s end,
	_conf_state_file = conf_state_file,
}
