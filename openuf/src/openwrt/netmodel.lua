--[[
	The controller's L2 model of the AP, realised as ONE vlan-filtering bridge.

	Every full system_cfg push describes the AP's whole layer 2 declaratively
	(captured on 10.6.106, see docs/GAP-ANALYSIS-10.6.md §4):

	  vlan.<n>.devname=eth0 / vlan.<n>.id=<vid>     uplink 8021q sub-devices
	  bridge.<n>.devname=br0 | br0.<vid> | br-trunk one bridge per network
	  bridge.<n>.port.<m>.devname=eth0|eth0.<vid>|ath<k>
	  dhcpc.1.devname=br0 / netconf.<n>.ip=...      where management lives
	  switch.*                                      the downstream port matrix

	A bridge holding the bare uplink carries the untagged (native) network; one
	holding `<uplink>.<vid>` carries VLAN <vid>. Management is whichever bridge
	dhcpc.1 (or a static netconf address) names -- `br0`, which holds the bare
	uplink normally and ONLY `eth0.<vid>` once a Management VLAN is set, at
	which point the untagged network's VAPs move to a new `br-trunk`.

	On a DSA board every socket is a netdev, so the faithful rendering is a
	single bridge with `vlan_filtering` on:

	  config device 'openuf_br'         name br-lan, ports = every socket
	  config bridge-vlan 'openuf_bv<v>' one per VLAN; uplink u*/t, sockets per
	                                    the switch.* matrix
	  config interface '<lan_name>'     device br-lan.<mgmt vid>, proto dhcp|static
	  config interface 'openuf_v<v>'    device br-lan.<v>, proto none -- what a
	                                    VAP on VLAN <v> names as its network

	netifd then enslaves each VAP to the bridge with that VLAN as its PVID. The
	switch ASIC does the VLAN work in hardware, trunk ports come for free, and
	nothing needs MAC learning switched off -- the per-VLAN-bridge design in
	ucihelper/switchvlan needs that only because it puts one physical port in
	two broadcast domains through an 8021q sub-device.

	OWNERSHIP ("the controller fully manages the bridge"). With takeover on,
	every bridge that holds one of the board's sockets is replaced: its section
	and its bridge-vlan sections are deleted, interfaces that pointed at it (or
	at `<it>.<vid>`) are re-pointed at the new bridge (a VLAN they referenced is
	kept in the table so they keep working), and openUF's own per-VLAN-bridge
	leftovers are removed. The board's original /etc/config/network is kept once
	in /etc/openuf/network.pre-openuf.

	SAFETY. Rewriting the bridge that carries the management address can strand
	the AP, which is why upstream refused vlan_filtering. Here every change is
	applied with a rollback: the previous /etc/config/network is saved before the
	commit, and unless an inform succeeds within ROLLBACK_TIMEOUT seconds it is
	restored and reloaded. A plan that lost the controller is remembered by hash
	and not applied again until the controller sends a different one.
]]--

local M = {}

M.DEFAULT_BRIDGE   = "br-lan"
M.NATIVE_VID       = 1
M.SECTION_PREFIX   = "openuf_"
M.ROLLBACK_TIMEOUT = 180
M.NETWORK_FILE     = "/etc/config/network"
M.ROLLBACK_FILE    = "/etc/openuf/network.rollback"
M.PRISTINE_FILE    = "/etc/openuf/network.pre-openuf"

-- Injectable seams, as in the other modules.
M._uci = nil
M._run_cmd = function(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local s = h:read("*a")
	h:close()
	return s or ""
end
M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
-- Sibling temp file and rename: a torn /etc/config/network is the one file
-- this module must never leave behind.
M._write_file = function(path, content)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(content)
	f:close()
	local ok = os.rename(tmp, path)
	if not ok then os.remove(tmp) end
	return ok and true or false
end
M._remove_file = function(path) os.remove(path) end
-- Seconds since boot. Monotonic, unlike os.time(), which NTP can step by days
-- on these boards -- and the rollback deadline must not jump with it.
M._uptime = function()
	local s = M._read_file("/proc/uptime")
	return tonumber(s and s:match("^(%d+)")) or os.time()
end
M._log = function(msg) io.stderr:write("netmodel: " .. msg .. "\n") end

local function get_uci()
	if M._uci then return M._uci end
	return require("uci")
end

local function as_list(v)
	if v == nil then return {} end
	if type(v) == "table" then return v end
	local out = {}
	for w in tostring(v):gmatch("%S+") do out[#out + 1] = w end
	return out
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

-- ─── Parsing ─────────────────────────────────────────────────────────────────

-- The controller's model (unifi/network.lua).
M.parse = require("unifi.network").parse


-- ─── Backend selection ───────────────────────────────────────────────────────

-- The bridge a socket is a member of in UCI (not in the kernel -- the kernel
-- answer is stale for exactly as long as a reload is pending), and whether it
-- filters VLANs.
local function uci_bridge_of(cursor, ifname)
	local found
	cursor:foreach("network", "device", function(s)
		if found or s.type ~= "bridge" then return end
		for _, p in ipairs(as_list(s.ports or s.ifname)) do
			if p == ifname then found = s end
		end
	end)
	return found
end

-- "vlan_filtering" | "bridges". config.bridge_backend picks it explicitly; the
-- default "auto" keeps upstream behaviour (per-VLAN bridges) EXCEPT on a board
-- whose uplink socket already sits in a vlan-filtering bridge, where the
-- per-VLAN-bridge path cannot work at all (its 8021q sub-devices fight the
-- filtering bridge for every tagged frame).
function M.backend(cfg, cursor)
	local want = cfg and cfg.config and cfg.config.bridge_backend or "auto"
	if want == "vlan_filtering" or want == "bridges" then return want end
	local ok, c = pcall(function() return cursor or get_uci().cursor() end)
	if not ok or not c then return "bridges" end
	if c:get("network", M.SECTION_PREFIX .. "br") then return "vlan_filtering" end
	local up = cfg and cfg.net and cfg.net.lan_cpueth
	local br = up and uci_bridge_of(c, up)
	if not br then return "bridges" end
	if tostring(br.vlan_filtering or "0") == "1" then return "vlan_filtering" end
	-- netifd turns filtering on for any bridge a `bridge-vlan` section names,
	-- with no vlan_filtering option in sight -- the usual hand-written DSA AP
	-- layout looks exactly like that.
	local filtered = false
	c:foreach("network", "bridge-vlan", function(s)
		if br.name and s.device == br.name then filtered = true end
	end)
	return filtered and "vlan_filtering" or "bridges"
end

-- ─── Planning ────────────────────────────────────────────────────────────────

local function socket_list(cfg)
	local out, seen = {}, {}
	local net = cfg and cfg.net or {}
	for _, p in ipairs(net.ports or {}) do
		if p.ifname and not seen[p.ifname] then
			seen[p.ifname] = true
			out[#out + 1] = {idx = p.idx, ifname = p.ifname}
		end
	end
	local up = net.lan_cpueth
	if up and not seen[up] then out[#out + 1] = {ifname = up} end
	return out
end

-- The desired state, as plain data (pure: no UCI, no files). opts:
--   uplink_ifname  the socket the gateway is behind (detected); defaults to
--                  dev.conf.net.lan_cpueth
--   keep_vids      set of extra VLAN ids to carry (foreign interfaces that
--                  survive a takeover)
--   identity_mac   MAC to pin on the bridge
---@param model NetworkModel
---@param sw PortsIntent?
---@return NetPlan? plan
---@return string? why  set when there is no plan
function M.plan(model, sw, cfg, opts)
	opts = opts or {}
	local net = cfg and cfg.net or {}
	local conf = cfg and cfg.config or {}
	local brname = conf.bridge_name or net.lan_bridge or M.DEFAULT_BRIDGE
	local mgmt_iface = net.lan_name or "lan"
	local port_default = conf.port_default or "all"
	local NATIVE = M.NATIVE_VID
	local function internal(vid) return (vid == nil or vid == 0) and NATIVE or vid end

	-- VLAN 1 is the untagged VLAN inside the bridge. A controller network
	-- TAGGED with VID 1 would land on it too and leave the uplink untagged,
	-- merging the two networks; the controller reserves VLAN 1 for its
	-- untagged Default network, so this is refused rather than remapped.
	local tagged_native = (model.vids or {})[NATIVE] or model.mgmt_vid == NATIVE
	for _, v in pairs(model.bridge_vid or {}) do
		if v == NATIVE then tagged_native = true end
	end
	if tagged_native then
		return nil, "VLAN " .. NATIVE .. " arrives tagged, but it is the untagged VLAN inside the bridge"
	end

	local sockets = socket_list(cfg)
	local uplink = opts.uplink_ifname or net.lan_cpueth or (sockets[1] and sockets[1].ifname)

	local vids = {[NATIVE] = true}
	for v in pairs(model.vids or {}) do vids[internal(v)] = true end
	if sw and sw.enabled then
		for id, v in pairs(sw.vlans or {}) do
			if v.enabled ~= false then vids[id] = true end
		end
	end
	for v in pairs(opts.keep_vids or {}) do vids[tonumber(v) or v] = true end
	vids[internal(model.mgmt_vid)] = true

	-- One socket's membership of one VLAN: "u*" (untagged + PVID), "u"
	-- (untagged egress only), "t" or nil (not a member).
	local function socket_mode(s, vid)
		if sw and sw.enabled then
			local p = s.idx and sw.ports and sw.ports[s.idx]
			local mode = p and p.vlans and p.vlans[vid]
			if not mode then
				local v = sw.vlans and sw.vlans[vid]
				mode = v and v.mode or (vid == NATIVE and "untagged" or "tagged")
			end
			local pvid = p and p.pvid or NATIVE
			if mode == "untagged" then return vid == pvid and "u*" or "u" end
			if mode == "tagged" then return "t" end
			return nil
		end
		if vid == NATIVE then return "u*" end
		return port_default == "all" and "t" or nil
	end

	local vlans = {}
	for _, vid in ipairs(sorted_keys(vids)) do
		local ports = {uplink .. (vid == NATIVE and ":u*" or ":t")}
		for _, s in ipairs(sockets) do
			if s.ifname ~= uplink then
				local mode = socket_mode(s, vid)
				if mode then ports[#ports + 1] = s.ifname .. ":" .. mode end
			end
		end
		vlans[vid] = {ports = ports}
	end

	local mgmt_vid = internal(model.mgmt_vid)
	local mgmt = {
		iface  = mgmt_iface,
		device = brname .. "." .. mgmt_vid,
	}
	if model.dhcp then
		mgmt.proto = "dhcp"
	elseif model.static then
		mgmt.proto   = "static"
		mgmt.ipaddr  = model.static.ip
		mgmt.netmask = model.static.netmask
		mgmt.gateway = model.static.gateway
		mgmt.dns     = model.static.dns
	end

	-- Which interface a VAP on each controller bridge joins.
	local net_for_bridge, vlan_ifaces = {}, {}
	for _, b in ipairs(model.bridges or {}) do
		local bv = model.bridge_vid[b.devname]
		if bv ~= nil then
			local vid = internal(bv)
			if vid == mgmt_vid then
				net_for_bridge[b.devname] = mgmt_iface
			else
				local name = M.SECTION_PREFIX .. "v" .. vid
				net_for_bridge[b.devname] = name
				vlan_ifaces[vid] = name
			end
		end
	end

	local ports = {}
	for _, s in ipairs(sockets) do ports[#ports + 1] = s.ifname end

	return {
		bridge = {name = brname, ports = ports, macaddr = opts.identity_mac},
		uplink = uplink,
		vlans = vlans,
		mgmt = mgmt,
		vlan_ifaces = vlan_ifaces,
		net_for_bridge = net_for_bridge,
	}
end

-- Stable text of a plan, for change detection and the failed-plan memory.
function M.fingerprint(plan)
	local parts = {plan.bridge.name, table.concat(plan.bridge.ports, ","),
		tostring(plan.bridge.macaddr), plan.uplink}
	for _, vid in ipairs(sorted_keys(plan.vlans)) do
		parts[#parts + 1] = vid .. "=" .. table.concat(plan.vlans[vid].ports, ",")
	end
	local m = plan.mgmt
	parts[#parts + 1] = table.concat({m.iface, m.device, tostring(m.proto), tostring(m.ipaddr),
		tostring(m.netmask), tostring(m.gateway), table.concat(m.dns or {}, ",")}, "|")
	for _, vid in ipairs(sorted_keys(plan.vlan_ifaces)) do
		parts[#parts + 1] = plan.vlan_ifaces[vid] .. "@" .. vid
	end
	local s = table.concat(parts, ";")
	-- djb2, kept in 32 bits with plain arithmetic (no bit library needed).
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	-- Two 16-bit halves: OpenWrt's Lua 5.1 is built "double int32" (LNUM), and
	-- its string.format("%x") rejects anything from 2^31 up -- which half of
	-- all hashes are. Found on the real-netifd bench, not by the unit tests.
	return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

-- ─── Applying ────────────────────────────────────────────────────────────────

local function same(a, b)
	if type(a) == "table" or type(b) == "table" then
		a, b = as_list(a), as_list(b)
		if #a ~= #b then return false end
		for i = 1, #a do if tostring(a[i]) ~= tostring(b[i]) then return false end end
		return true
	end
	return tostring(a or "") == tostring(b or "")
end

-- Write one option only when it differs; returns true when it wrote.
local function put(cursor, sec, opt, val)
	local cur = cursor:get("network", sec, opt)
	if val == nil then
		if cur ~= nil then cursor:delete("network", sec, opt) return true end
		return false
	end
	if same(cur, val) then return false end
	cursor:set("network", sec, opt, val)
	return true
end

local function ensure_section(cursor, name, stype)
	if cursor:get("network", name) == stype then return false end
	if cursor:get("network", name) ~= nil then cursor:delete("network", name) end
	cursor:set("network", name, stype)
	return true
end

-- Section names of the bridges, other than ours, that hold one of the plan's
-- sockets or already use its bridge name.
function M.foreign_bridges(cursor, plan)
	local sockets = {}
	for _, p in ipairs(plan.bridge.ports) do sockets[p] = true end
	local out = {}
	cursor:foreach("network", "device", function(s)
		if s[".name"] == M.SECTION_PREFIX .. "br" or s.type ~= "bridge" then return end
		local claims = (s.name == plan.bridge.name)
		for _, p in ipairs(as_list(s.ports or s.ifname)) do
			if sockets[p] then claims = true end
		end
		if claims then out[#out + 1] = s[".name"] end
	end)
	return out
end

-- Replace every bridge that claims a socket (or our bridge's name), and
-- re-point whatever used it. Returns changed, keep_vids.
-- own: the interfaces too (config.own_config, default on). Every interface
-- on the bridges being taken over -- other than management and openUF's own --
-- is deleted instead of re-pointed, and so are L3 interfaces left on a socket
-- (a stock wan/wan6): the controller's networks are the AP's networks, and a
-- leftover would keep an address on a VLAN the controller never gave the AP.
-- The board's file is saved once as PRISTINE_FILE (netmodel-restore).
function M.takeover(cursor, plan, st, own)
	local changed = false
	local keep_vids = {}
	local sockets = {}
	for _, p in ipairs(plan.bridge.ports) do sockets[p] = true end
	local ours = M.SECTION_PREFIX .. "br"

	local foreign, foreign_names, doomed = {}, {}, {}
	cursor:foreach("network", "device", function(s)
		local name = s[".name"]
		if name == ours then return end
		if s.type == "bridge" then
			local claims = (s.name == plan.bridge.name)
			for _, p in ipairs(as_list(s.ports or s.ifname)) do
				if sockets[p] then claims = true end
			end
			if claims then
				foreign[#foreign + 1] = name
				if s.name then foreign_names[s.name] = true end
			end
		elseif name:match("^" .. M.SECTION_PREFIX .. "brport") then
			-- The per-VLAN-bridge backend's learning overrides.
			doomed[#doomed + 1] = name
		end
	end)
	cursor:foreach("network", "bridge-vlan", function(s)
		local name = s[".name"]
		if name:match("^" .. M.SECTION_PREFIX .. "bv%d+$") then return end
		if foreign_names[s.device] or s.device == plan.bridge.name then
			doomed[#doomed + 1] = name
		end
	end)

	local bridge_names = {[plan.bridge.name] = true}
	for n in pairs(foreign_names) do bridge_names[n] = true end
	cursor:foreach("network", "interface", function(s)
		local name = s[".name"]
		if name == "loopback" or name == plan.mgmt.iface then return end
		if name:match("^" .. M.SECTION_PREFIX .. "vlan%d+$") then
			doomed[#doomed + 1] = name   -- per-VLAN-bridge backend's interfaces
			return
		end
		if name:match("^" .. M.SECTION_PREFIX .. "v%d+$") then return end
		local dev = s.device or s.ifname
		if type(dev) ~= "string" then return end
		local base, vid = dev:match("^(.-)%.(%d+)$")
		if own and ((base and bridge_names[base]) or bridge_names[dev] or sockets[dev]) then
			doomed[#doomed + 1] = name
			if st then
				st.netmodel_removed = st.netmodel_removed or {}
				local seen = false
				for _, n in ipairs(st.netmodel_removed) do if n == name then seen = true end end
				if not seen then st.netmodel_removed[#st.netmodel_removed + 1] = name end
			end
		elseif base and bridge_names[base] then
			keep_vids[tonumber(vid)] = true
			changed = put(cursor, name, "device", plan.bridge.name .. "." .. vid) or changed
		elseif bridge_names[dev] then
			changed = put(cursor, name, "device", plan.bridge.name .. "." .. M.NATIVE_VID) or changed
		elseif sockets[dev] and s.disabled ~= "1" then
			-- An L3 interface straight on a socket (a stock `wan`): the socket
			-- is a bridge port now, so the interface is parked, and recorded so
			-- restore_pristine can say what happened.
			changed = put(cursor, name, "disabled", "1") or changed
			if st then
				st.netmodel_parked = st.netmodel_parked or {}
				st.netmodel_parked[#st.netmodel_parked + 1] = name
			end
		end
	end)

	for _, name in ipairs(foreign) do doomed[#doomed + 1] = name end
	-- The per-VLAN-bridge backend's bridges hold `<uplink>.<vid>`, not a
	-- socket, so they are not caught above.
	cursor:foreach("network", "device", function(s)
		if s[".name"]:match("^" .. M.SECTION_PREFIX .. "brdev%d+$") then
			doomed[#doomed + 1] = s[".name"]
		end
	end)
	local gone = {}
	for _, name in ipairs(doomed) do
		if not gone[name] then
			gone[name] = true
			cursor:delete("network", name)
			changed = true
		end
	end
	return changed, keep_vids
end

-- Write the plan into UCI. Returns true when anything changed.
function M.write(cursor, plan)
	local changed = false
	local br = M.SECTION_PREFIX .. "br"
	changed = ensure_section(cursor, br, "device") or changed
	changed = put(cursor, br, "type", "bridge") or changed
	changed = put(cursor, br, "name", plan.bridge.name) or changed
	changed = put(cursor, br, "ports", plan.bridge.ports) or changed
	changed = put(cursor, br, "vlan_filtering", "1") or changed
	if plan.bridge.macaddr then
		changed = put(cursor, br, "macaddr", plan.bridge.macaddr) or changed
	end

	local want_bv = {}
	for vid, v in pairs(plan.vlans) do
		local sec = M.SECTION_PREFIX .. "bv" .. vid
		want_bv[sec] = true
		changed = ensure_section(cursor, sec, "bridge-vlan") or changed
		changed = put(cursor, sec, "device", plan.bridge.name) or changed
		changed = put(cursor, sec, "vlan", tostring(vid)) or changed
		changed = put(cursor, sec, "ports", v.ports) or changed
	end

	local m = plan.mgmt
	changed = ensure_section(cursor, m.iface, "interface") or changed
	changed = put(cursor, m.iface, "device", m.device) or changed
	changed = put(cursor, m.iface, "ifname", nil) or changed
	if m.proto == "dhcp" then
		changed = put(cursor, m.iface, "proto", "dhcp") or changed
		for _, o in ipairs({"netmask", "gateway", "dns"}) do
			changed = put(cursor, m.iface, o, nil) or changed
		end
		-- Keep the lease when the interface restarts. OpenWrt's DHCP client
		-- releases on stop by default, so every rebuild of the bridge gave the
		-- address back and the AP came up on a new one (seen live: 10.0.0.3
		-- -> 10.0.1.88). `ipaddr` is only a hint on a DHCP interface (the
		-- address udhcpc asks for, -r), set by converge() before a reload.
		changed = put(cursor, m.iface, "norelease", "1") or changed
	elseif m.proto == "static" then
		changed = put(cursor, m.iface, "proto", "static") or changed
		changed = put(cursor, m.iface, "ipaddr", m.ipaddr) or changed
		changed = put(cursor, m.iface, "netmask", m.netmask) or changed
		changed = put(cursor, m.iface, "gateway", m.gateway) or changed
		changed = put(cursor, m.iface, "dns", (m.dns and #m.dns > 0) and m.dns or nil) or changed
	end

	local want_if = {}
	for vid, name in pairs(plan.vlan_ifaces) do
		want_if[name] = true
		changed = ensure_section(cursor, name, "interface") or changed
		changed = put(cursor, name, "device", plan.bridge.name .. "." .. vid) or changed
		changed = put(cursor, name, "proto", "none") or changed
	end

	local stale = {}
	cursor:foreach("network", "bridge-vlan", function(s)
		local n = s[".name"]
		if n:match("^" .. M.SECTION_PREFIX .. "bv%d+$") and not want_bv[n] then stale[#stale + 1] = n end
	end)
	cursor:foreach("network", "interface", function(s)
		local n = s[".name"]
		if n:match("^" .. M.SECTION_PREFIX .. "v%d+$") and not want_if[n] then stale[#stale + 1] = n end
	end)
	for _, n in ipairs(stale) do
		cursor:delete("network", n)
		changed = true
	end
	return changed
end

-- Make UCI match the controller's model: plan, take over foreign bridges when
-- allowed (config.bridge_takeover ~= false), write, reload, and arm the
-- rollback. Returns changed, plan, outcome:
--   "applied"    written and committed; rollback armed      (true,  plan)
--   "unchanged"  UCI already matched                         (false, plan)
--   "declined"   bridge takeover is off and a foreign bridge
--                holds the sockets: the caller keeps its own
--                layout                                      (false, nil)
--   "rejected"   this plan once lost the controller, or it
--                cannot be built                              (false, nil)
--   "failed"     it could not be committed with a rollback
--                copy in place                                (false, nil)
-- The plan comes back only when it is what the network now is: the WiFi pass
-- attaches VAPs to its interfaces, and anything else would name interfaces
-- that do not exist.
--   opts.uplink_ifname / opts.identity_mac: see M.plan
---@param model NetworkModel
---@param sw PortsIntent?
---@return boolean changed
---@return NetPlan? plan
---@return ConvergeOutcome outcome
function M.converge(model, sw, cfg, st, opts)
	opts = opts or {}
	local plan, why = M.plan(model, sw, cfg, opts)
	if not plan then
		M._log("NOT applying the controller's network: " .. tostring(why))
		return false, nil, "rejected"
	end
	local before = M._read_file(M.NETWORK_FILE)
	local cursor = get_uci().cursor()
	local takeover = not (cfg and cfg.config and cfg.config.bridge_takeover == false)
	local changed = false
	if not takeover then
		local claimed = M.foreign_bridges(cursor, plan)
		if #claimed > 0 then
			M._log("bridge takeover is off (config.bridge_takeover = false) and "
				.. table.concat(claimed, ", ") .. " already holds this board's sockets;"
				.. " leaving the network alone")
			return false, nil, "declined"
		end
	end
	if takeover then
		local keep
		local own = not (cfg and cfg.config and cfg.config.own_config == false)
		changed, keep = M.takeover(cursor, plan, st, own)
		-- A VLAN a surviving foreign interface uses must stay in the table,
		-- or re-pointing it at the new bridge would leave it on a dead VLAN.
		for vid in pairs(keep or {}) do
			if not plan.vlans[vid] then
				local o = {}
				for k, v in pairs(opts) do o[k] = v end
				o.keep_vids = keep
				plan = assert(M.plan(model, sw, cfg, o))
				break
			end
		end
	end

	local fp = M.fingerprint(plan)
	if st.netmodel_failed == fp then
		cursor:revert("network")
		if st.netmodel_failed_logged ~= fp then
			M._log("NOT applying network plan " .. fp .. ": it lost the controller once and"
				.. " was rolled back. Change the network in the controller, or run"
				.. " `syswrapper.sh netmodel-retry`, to try again.")
			st.netmodel_failed_logged = fp
		end
		return false, nil, "rejected"
	end

	changed = M.write(cursor, plan) or changed
	if not changed then
		st.netmodel_applied = fp
		return false, plan, "unchanged"
	end

	-- The network is about to reload: a DHCP management interface asks for
	-- the address it has now, so the rebuild does not renumber the AP.
	local cur_ip = opts.current_ip
	if plan.mgmt.proto == "dhcp" and type(cur_ip) == "string"
		and cur_ip:match("^%d+%.%d+%.%d+%.%d+$") and cur_ip ~= "0.0.0.0" then
		cursor:set("network", plan.mgmt.iface, "ipaddr", cur_ip)
	end
	-- ...and the running client must not give the lease back as it stops.
	if plan.mgmt.proto == "dhcp" and M._stop_releasing_dhcp_client then
		pcall(M._stop_releasing_dhcp_client, plan.mgmt.iface)
	end

	-- The rollback copy is what makes this change safe to try: no copy, no
	-- change. (The pristine copy only serves an uninstall; losing it is
	-- logged, not fatal.)
	if before and not M._read_file(M.PRISTINE_FILE)
			and not M._write_file(M.PRISTINE_FILE, before) then
		M._log("could not save " .. M.PRISTINE_FILE .. " (the network before openUF)")
	end
	if not (before and M._write_file(M.ROLLBACK_FILE, before)) then
		cursor:revert("network")
		M._log("NOT applying network plan " .. fp .. ": no rollback copy of "
			.. M.NETWORK_FILE .. " could be kept")
		return false, nil, "failed"
	end
	if cursor:commit("network") == false then
		cursor:revert("network")
		M._remove_file(M.ROLLBACK_FILE)
		M._log("NOT applying network plan " .. fp .. ": committing " .. M.NETWORK_FILE .. " failed")
		return false, nil, "failed"
	end
	st.netmodel_pending = {fp = fp, since = M._uptime(),
		timeout = tonumber(cfg and cfg.config and cfg.config.bridge_rollback_timeout)
			or M.ROLLBACK_TIMEOUT}
	st.netmodel_applied = fp
	M._log(("applied network plan %s (bridge %s, %d VLANs, management on %s/%s); "
		.. "rolling back unless the controller is reached within %ds")
		:format(fp, plan.bridge.name, #sorted_keys(plan.vlans), plan.mgmt.device,
			tostring(plan.mgmt.proto or "unchanged"), st.netmodel_pending.timeout))
	M._run_cmd("/etc/init.d/network reload")
	return true, plan, "applied"
end

-- ─── Rollback ────────────────────────────────────────────────────────────────

-- Called after every inform. `ok` is whether the controller answered.
-- Returns "confirmed", "rolled_back", "rollback_failed" (the copy could not
-- be written back: kept, and tried again next time) or nil.
function M.check(st, ok)
	local p = st and st.netmodel_pending
	if not p then return nil end
	if ok then
		st.netmodel_pending = nil
		M._remove_file(M.ROLLBACK_FILE)
		M._log("network plan " .. tostring(p.fp) .. " confirmed: the controller is reachable")
		return "confirmed"
	end
	if M._uptime() - (p.since or 0) < (p.timeout or M.ROLLBACK_TIMEOUT) then return nil end
	local saved = M._read_file(M.ROLLBACK_FILE)
	if not saved then
		st.netmodel_pending = nil
		st.netmodel_failed = p.fp
		st.netmodel_applied = nil
		M._log("network plan " .. tostring(p.fp) .. " lost the controller and there is"
			.. " no rollback copy to restore")
		return nil
	end
	if not M._write_file(M.NETWORK_FILE, saved) then
		M._log("network plan " .. tostring(p.fp) .. " lost the controller, and writing the"
			.. " rollback copy back failed; keeping it and trying again")
		return "rollback_failed"
	end
	st.netmodel_pending = nil
	st.netmodel_failed = p.fp
	st.netmodel_applied = nil
	M._remove_file(M.ROLLBACK_FILE)
	M._log("network plan " .. tostring(p.fp) .. " lost the controller for "
		.. tostring(p.timeout) .. "s -- restored the previous /etc/config/network")
	M._run_cmd("/etc/init.d/network reload")
	return "rolled_back"
end

-- At daemon start: a plan applied just before a reboot gets a fresh window,
-- measured from now (uptime restarted from zero).
function M.on_start(st)
	if st and st.netmodel_pending then st.netmodel_pending.since = M._uptime() end
end

-- Put the board's own network config back (uninstall / manual escape hatch).
-- netifd can believe an interface has its default route while the kernel
-- does not: deleting one of two DHCP interfaces that both installed a default
-- route took the survivor's kernel route with it (seen live after own_config
-- removed a leftover vpn_se), and without a route the AP finds no gateway, so
-- no uplink port, and reports everything upstream as its own wired clients.
-- Puts the route back when netifd has one the kernel lacks. Returns true then.
function M.repair_default_route(iface)
	local ok_j, cjson = pcall(require, "cjson")
	if not ok_j then return false end
	local raw = M._run_cmd("ubus call network.interface." .. tostring(iface) .. " status")
	local ok, st = pcall(cjson.decode, raw or "")
	if not ok or type(st) ~= "table" or not st.up then return false end
	local dev = st.l3_device or st.device
	local via
	for _, r in ipairs(st.route or {}) do
		if r.target == "0.0.0.0" and tonumber(r.mask) == 0 and r.nexthop then via = r.nexthop end
	end
	if not (dev and via and via:match("^%d+%.%d+%.%d+%.%d+$") and dev:match("^[%w%.%-_]+$")) then
		return false
	end
	if (M._run_cmd("ip -4 route show default") or ""):match("%S") then return false end
	M._run_cmd("ip -4 route replace default via " .. via .. " dev " .. dev)
	M._log("restored the default route via " .. via .. " on " .. dev
		.. " (netifd had it, the kernel did not)")
	return true
end

function M.restore_pristine(st)
	local saved = M._read_file(M.PRISTINE_FILE)
	if not saved then return false end
	M._write_file(M.NETWORK_FILE, saved)
	if st then
		st.netmodel_pending, st.netmodel_failed, st.netmodel_applied = nil, nil, nil
		st.netmodel_parked = nil
	end
	M._run_cmd("/etc/init.d/network reload")
	return true
end

return M
