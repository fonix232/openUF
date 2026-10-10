--[[
	backhaul.lua -- the wireless uplink ("mesh") on the device: which uplink
	is in use, and who is at the other end of each backhaul link.

	The controller's side (the push's mesh block and backhaul VAPs, the plan,
	the payload fields) is unifi/mesh.lua; the UCI sections are written by
	ucihelper.backhaul_apply. This module owns:

	  tick()/decide()      the uplink policy the controller's `connectivity`
	                       block leaves to the device: wired first, the WDS
	                       station only while the wired uplink has no link --
	                       never both, which would be a bridge loop (every
	                       UniFi push runs STP off)
	  parent_for_bssid()   the parent device behind the BSS the station joined,
	                       the `serialno` of the uplink VAP's one station
	  child_serialno()     the child device behind a downlink's WDS netdev
	  uplink_link()        the uplink interface's name and the BSS it joined,
	                       while the device is on its wireless uplink

	Ported from yesrab/openUF (backhaul.lua, 2026-10-03). Everything is
	best-effort and pcall-wrapped by the caller; nothing here may cost a
	heartbeat.
]]--

local M = {}

-- Injectable seams (tests replace them).
M._popen = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a") or ""
	h:close()
	return s
end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
M._log = function(msg) io.stderr:write("backhaul: " .. msg .. "\n") end

-- Consecutive heartbeats without a wired link before the station is enabled.
-- Two (~20 s) ride out a switch reboot or a re-seated cable without taking
-- the radio's SSIDs down for nothing; the link coming back disables the
-- station on the very next heartbeat.
M.DOWN_TICKS = 2

M._down_ticks = 0

local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function safe_ifname(s)
	return type(s) == "string" and s:match("^[%w%-%._]+$") ~= nil
end

-- One policy step. carrier: true/false, or nil when it cannot be read.
-- Returns the mode now in effect and the updated down-tick counter.
---@param carrier boolean?
---@param mode string?   "wired" | "wireless"
---@param ticks integer?
---@return string mode, integer ticks
function M.decide(carrier, mode, ticks)
	mode  = (mode == "wireless") and "wireless" or "wired"
	ticks = tonumber(ticks) or 0
	if carrier == true then return "wired", 0 end
	if carrier == false then
		ticks = ticks + 1
		if ticks >= M.DOWN_TICKS then return "wireless", ticks end
		return mode, ticks
	end
	return mode, 0  -- unknown: hold what we have, and do not accumulate
end

-- The link state of a wired socket. operstate first: a pulled cable reads
-- "lowerlayerdown" (carrier 0), an administratively downed port "down" with
-- NO readable carrier file, and both mean "no wired uplink". Falls back to
-- the carrier file for drivers that leave operstate at "unknown".
function M.carrier_of(ifname)
	if not safe_ifname(ifname) then return nil end
	local op = M._read_file("/sys/class/net/" .. ifname .. "/operstate")
	op = op and op:match("%S+") or nil
	if op == "up" then return true end
	if op == "down" or op == "lowerlayerdown" or op == "notpresent" or op == "dormant" then
		return false
	end
	local v = M._read_file("/sys/class/net/" .. ifname .. "/carrier")
	v = v and v:match("%d") or nil
	if v == "1" then return true elseif v == "0" then return false end
	return nil
end

-- A netdev that is a radio's, never a wired socket.
local function looks_wireless(ifname)
	return type(ifname) == "string"
		and (ifname:match("^phy%d+%-") or ifname:match("^wlan") or ifname:match("^ath")) ~= nil
end

-- One heartbeat of the policy. ufuci: the backhaul_* section helpers;
-- sysinfo: which bridge port the gateway is behind. Persists the mode and the
-- remembered wired socket in state so a restart does not flap the radio.
-- Returns the mode in effect, or nil on a device with no uplink station.
function M.tick(st, cfg, ufuci, sysinfo, state_mod)
	if not (st and ufuci and ufuci.backhaul_uplink_sections) then return nil end
	local secs = ufuci.backhaul_uplink_sections()
	if #secs == 0 then
		-- No station any more (the push dropped it, or the option went off):
		-- whatever the device runs on now is wired, and a station written by
		-- a later push must start disabled.
		M._down_ticks = 0
		if st.backhaul_mode == "wireless" then
			st.backhaul_mode = "wired"
			if state_mod and state_mod.save then pcall(state_mod.save, st) end
		end
		return nil
	end
	local sta_if = ufuci.ifname_for_section and ufuci.ifname_for_section(secs[1].name) or nil
	local dirty = false

	-- Remember the wired socket the gateway is behind while there is one. The
	-- board's own uplink socket (cfg.net.lan_cpueth) is the fallback for a
	-- device that has never seen its gateway since the option was turned on.
	local lan = cfg and cfg.net and cfg.net.lan_cpueth
	if sysinfo and sysinfo.bridge_of and sysinfo.uplink_bridge_port then
		local ok, br = pcall(sysinfo.bridge_of, lan)
		if ok and br then
			local ok2, p = pcall(sysinfo.uplink_bridge_port, br)
			if ok2 and type(p) == "string" and p ~= sta_if and not looks_wireless(p) then
				if st.backhaul_wired_port ~= p then
					st.backhaul_wired_port = p
					dirty = true
				end
			end
		end
	end
	local wired_port = st.backhaul_wired_port
	if type(wired_port) ~= "string" or wired_port == "" then
		wired_port = (type(lan) == "string" and lan ~= "") and lan or nil
	end
	-- Not `wired_port and M.carrier_of(...) or nil`: a false carrier would
	-- turn into nil (unknown) and the station would never come up.
	local carrier = nil
	if wired_port then carrier = M.carrier_of(wired_port) end
	local mode = (st.backhaul_mode == "wireless") and "wireless" or "wired"
	local new_mode, ticks = M.decide(carrier, mode, M._down_ticks)
	M._down_ticks = ticks
	if new_mode ~= mode then
		M._log(("wired uplink %s on %s -- %s the WDS station"):format(
			new_mode == "wireless" and "lost" or "back", tostring(wired_port or "?"),
			new_mode == "wireless" and "enabling" or "disabling"))
		local ok, err = pcall(ufuci.backhaul_set_uplink_enabled, new_mode == "wireless")
		if not ok then M._log("could not switch the station: " .. tostring(err)) end
		st.backhaul_mode = new_mode
		dirty = true
	end
	if dirty and state_mod and state_mod.save then pcall(state_mod.save, st) end
	return new_mode
end

-- The parent device behind the downlink BSS the station joined. The BSS
-- actually joined decides:
--   1. its sibling element in the station's scan cache. sysinfo.scan_table
--      hands back RAW entries, where the element is `peer_mac`; is_unifi/
--      serialno are stamped on only later, by report.lua's scan_radio_table
--      (both shapes are read);
--   2. the sibling exchange (openwrt/siblings.lua): every openUF AP
--      announces its BSSIDs on the LAN, the hidden downlink among them, and
--      the hop is on that LAN;
--   3. only then the parent the controller's last push named (mesh.serial1,
--      kept in state). It describes the push's topology, not the BSS the
--      station roamed to, and a device that boots straight onto the air with
--      a matching cfgversion gets no push at all.
-- nil when none knows -- never a guess: the controller would attribute the
-- link to the wrong device. yesrab/openUF found the cold-boot case on
-- hardware (666f59e): station up, informs fine, no serialno, and the
-- controller fell back to the gateway's MAC table, "wired via port 2".
function M.parent_for_bssid(st, bssid, ifname, sysinfo)
	if is_mac(bssid) and sysinfo then
		local b = bssid:lower()
		if sysinfo.scan_table and safe_ifname(ifname) then
			local ok_s, entries = pcall(sysinfo.scan_table, ifname)
			for _, e in ipairs((ok_s and type(entries) == "table") and entries or {}) do
				if type(e) == "table" and type(e.bssid) == "string" and e.bssid:lower() == b then
					local sn = e.peer_mac or (e.is_unifi and e.serialno) or nil
					if is_mac(sn) then return sn:lower() end
				end
			end
		end
		if sysinfo.sibling_bssids then
			local ok_b, by_bssid = pcall(sysinfo.sibling_bssids)
			local sn = ok_b and type(by_bssid) == "table" and by_bssid[b] or nil
			if is_mac(sn) then return sn:lower() end
		end
	end
	if st and is_mac(st.backhaul_parent) then return st.backhaul_parent:lower() end
	return nil
end

-- The child device behind one of a downlink's per-station WDS netdevs
-- (hostapd parks each 4-address peer on <bss>.sta<N>): the one sibling AP
-- whose identity MAC the bridge learnt behind that netdev. `siblings` is a
-- set of sibling identity MACs (lower-case). nil when none, or more than one
-- -- a grandchild on a multi-hop path is learnt behind the same netdev, and
-- a wrong attribution is worse than none.
function M.child_serialno(sta_dev, siblings, cfg, sysinfo)
	if not safe_ifname(sta_dev) or type(siblings) ~= "table" or next(siblings) == nil then
		return nil
	end
	if not (sysinfo and sysinfo.bridge_fdb_ports and sysinfo.bridge_of) then return nil end
	local ok_b, bridge = pcall(sysinfo.bridge_of, sta_dev)
	if not (ok_b and bridge) then
		ok_b, bridge = pcall(sysinfo.bridge_of, cfg and cfg.net and cfg.net.lan_cpueth)
	end
	if not (ok_b and bridge) then return nil end
	local ok_f, fdb = pcall(sysinfo.bridge_fdb_ports, bridge)
	if not (ok_f and type(fdb) == "table") then return nil end
	local found = nil
	for mac, port in pairs(fdb) do
		local m = type(mac) == "string" and mac:lower() or nil
		if port == sta_dev and m and siblings[m] then
			if found and found ~= m then return nil end
			found = m
		end
	end
	return found
end

-- {name, bssid, ifname} of the wireless uplink while the device is on it and
-- the station is associated; nil otherwise (the default "eth0" and the
-- gateway's LLDP then describe the wired uplink, as before). `name` is the
-- controller's own devname for the station (ath4, its
-- connectivity.uplink_wds) when known, which is also the uplink VAP's name in
-- vap_table (ucihelper.get_vap_table) -- the two must match.
function M.uplink_link(st, ufuci)
	if not (st and st.backhaul_mode == "wireless" and ufuci and ufuci.backhaul_uplink_sections) then
		return nil
	end
	local secs = ufuci.backhaul_uplink_sections()
	if #secs == 0 then return nil end
	local ifname = ufuci.ifname_for_section and ufuci.ifname_for_section(secs[1].name) or nil
	if not safe_ifname(ifname) then return nil end
	local link = M._popen("iw dev " .. ifname .. " link") or ""
	local bssid = link:match("Connected to (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
	if not bssid then return nil end
	return {name = secs[1].devname or secs[1].name, bssid = bssid:lower(), ifname = ifname}
end

return M
