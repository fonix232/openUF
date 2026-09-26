--[[
	board.lua -- what this device is, derived from the device itself.

	Reads OpenWrt's own /etc/board.json (written by its board.d scripts from
	the device tree), the running bridge and /sys/class/leds, and settles on:

	  • sockets     network.wan.device + network.lan.ports (or lan.device on a
	                single-port board), in that order
	  • uplink      the socket the default gateway's MAC is learned on (bridge
	                FDB), else board.json's wan device, else the first socket
	  • identity    the closest UniFi AP (unifi/identity.lua, against the
	                controller's own model registry)
	  • numbering   that model's registry order: a model with a built-in
	                switch takes its uplink on the LAST port (U6IW: port 5,
	                "PoE In + Data") and the others from 1 in socket order; a
	                plain AP takes it on port 1 -- the controller stores
	                per-port settings against these numbers
	  • MAC         the MAC the network already knows this AP by: the bridge
	                the uplink sits in, else board.json's label MAC. NOT the
	                uplink socket's own MAC, which on some boards (a Netgear
	                WAX220's eth0) is random on every boot
	  • LED         the first of status/power/system/run, preferring blue,
	                white, green
	  • radios      every wifi-device in /etc/config/wireless

	Both choices are kept: the layout in /etc/openuf/modelmap-auto.json once
	the uplink could actually be DETECTED, the identity in
	/etc/openuf/ufmodel-auto.json. Numbering and identity must not move under
	an adopted device just because someone moved a cable; delete the files to
	derive again.

	DSA boards only: on a swconfig board the sockets are not netdevs.
	/etc/openuf/local.lua can still change or replace what this returns.
]]--

local identity = require("unifi.identity")

local M = {}

M.LAYOUT_FILE   = "/etc/openuf/modelmap-auto.json"
M.IDENTITY_FILE = "/etc/openuf/ufmodel-auto.json"
M.BOARD_FILE    = "/etc/board.json"

local ok_json, cjson = pcall(require, "cjson")

M._read = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

M._write = function(path, s)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(s)
	f:close()
	return true
end

M._sh = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end

local function decode(s)
	if not (ok_json and s and s ~= "") then return nil end
	local ok, t = pcall(cjson.decode, s)
	return ok and type(t) == "table" and t or nil
end

local function mac_of(ifname)
	local m = (M._read("/sys/class/net/" .. ifname .. "/address") or "")
		:match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	return m and m:lower() or nil
end

local function master_of(ifname)
	local m = M._sh("readlink /sys/class/net/" .. ifname .. "/master"):match("([^/%s]+)%s*$")
	return (m and m ~= "") and m or nil
end

-- The UniFi identity, kept once chosen.
function M.identity(board)
	local saved = decode(M._read(M.IDENTITY_FILE))
	local uap, code, fresh, score = identity.choose(board, saved and saved.model)
	if fresh and ok_json then
		io.stderr:write(string.format("openuf: identity: %s (%s), closest UniFi AP to this board "
			.. "(score %.1f)\n", code, uap.model_display or code, score or 0))
		M._write(M.IDENTITY_FILE, cjson.encode({model = code, uidb = identity.uidb()}))
	end
	return uap
end

-- Sockets, uplink, MAC, LED and radios, and whether the uplink was detected
-- (only then is the layout worth keeping).
function M.derive(board, uplink_idx)
	local net = (board or {}).network or {}

	local sockets, seen = {}, {}
	local function add(i)
		if type(i) == "string" and i ~= "" and not seen[i] then
			seen[i] = true
			sockets[#sockets + 1] = i
		end
	end
	if net.wan then add(net.wan.device) end
	if net.lan then
		for _, p in ipairs(net.lan.ports or {}) do add(p) end
		add(net.lan.device)
	end
	if #sockets == 0 then add("eth0") end

	-- The gateway's MAC, then the socket it was learned on.
	local uplink, detected = nil, false
	local gw_ip = M._sh("ip -4 route show default"):match("via%s+(%d+%.%d+%.%d+%.%d+)")
	local gw_mac = gw_ip and (M._read("/proc/net/arp") or ""):match(
		gw_ip:gsub("%.", "%%.") .. "%s+%S+%s+%S+%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	if gw_mac then
		for line in M._sh("bridge fdb show"):gmatch("[^\n]+") do
			local mac, dev = line:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+dev%s+(%S+)")
			if mac and mac:lower() == gw_mac:lower() and seen[dev] and line:find("master") then
				uplink, detected = dev, true
				break
			end
		end
	end
	if not uplink then uplink = (net.wan and net.wan.device) or sockets[1] end
	-- A board whose one socket IS the uplink needs no detection to be sure.
	if #sockets == 1 then detected = true end

	-- The uplink's port number comes from the model's registry layout; the
	-- other sockets fill the remaining numbers in order.
	local up_idx = tonumber(uplink_idx) or 5
	local ports, idx = {}, 1
	for _, s in ipairs(sockets) do
		if s ~= uplink then
			if idx == up_idx then idx = idx + 1 end
			ports[#ports + 1] = {idx = idx, ifname = s}
			idx = idx + 1
		end
	end
	ports[#ports + 1] = {idx = up_idx, ifname = uplink}

	local br = master_of(uplink)
	local mac = (br and mac_of(br))
		or ((board or {}).system and board.system.label_macaddr)
		or (net.lan and net.lan.macaddr)
		or mac_of(uplink)

	local leds = {}
	for name in M._sh("ls /sys/class/leds"):gmatch("%S+") do leds[#leds + 1] = name end
	local led
	for _, fn in ipairs({"status", "power", "system", "run"}) do
		for _, colour in ipairs({"blue", "white", "green", ""}) do
			for _, n in ipairs(leds) do
				if not led and n:find(fn, 1, true) and n:find(colour, 1, true) then led = n end
			end
		end
	end

	local radios = {}
	for name in M._sh("uci -q show wireless"):gmatch("wireless%.([%w_]+)=wifi%-device") do
		radios[#radios + 1] = name
	end
	if #radios == 0 then radios = {"radio0", "radio1"} end

	return {
		ports = ports, uplink = uplink, identity_mac = mac and mac:lower(),
		led = led, radios = radios,
	}, detected
end

-- The device description the daemon works from: dev.conf (net, led),
-- dev.openuf.uap (radios) and dev.identity (the UniFi model presented).
---@return Dev
function M.describe()
	local board = decode(M._read(M.BOARD_FILE))
	local uap = M.identity(board)

	local layout = decode(M._read(M.LAYOUT_FILE))
	if not (layout and layout.ports and layout.uplink) then
		local fresh, detected = M.derive(board, uap.uplink_idx)
		layout = fresh
		if detected and ok_json then M._write(M.LAYOUT_FILE, cjson.encode(fresh)) end
	end

	local dev = {conf = {}, openuf = {}, identity = uap}
	dev.conf.net = {
		lan_name     = "lan",
		lan_cpueth   = layout.uplink,
		lan_vlanid   = 1,
		wan_cpueth   = layout.uplink,
		identity_mac = layout.identity_mac,
		ports        = {},
	}
	for _, p in ipairs(layout.ports) do
		dev.conf.net.ports[#dev.conf.net.ports + 1] = {idx = p.idx, ifname = p.ifname}
	end
	dev.conf.led = layout.led
	dev.openuf.uap = {
		ufmodel  = "auto",
		hwassign = layout.radios,
	}
	return dev
end

return M
