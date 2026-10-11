--[[
	network.lua -- the controller's own description of the AP's layer 2: its
	bridges, VLANs, Management VLAN and management addressing, out of the
	bridge.*, vlan.*, netconf.*, dhcpc.* blocks of system_cfg
	(docs/GAP-ANALYSIS-10.6.md section 4). openwrt/netmodel.lua turns it into UCI.
]]--

local M = {}

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function lua_pattern_escape(s)
	return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- The topology out of a system_cfg blob, or nil when the blob carries no
-- bridge.* block at all (a partial push says nothing about L2, and "nothing"
-- must not be read as "tear it all down").
--
--   uplink       devname the controller uses for the uplink ("eth0")
--   vids         set of VLAN ids carried on the uplink
--   bridges      list of {devname, ports = {...}} in wire order
--   bridge_vid   devname -> 0 (native/untagged) | vid | nil (no uplink leg)
--   mgmt_bridge  devname of the management bridge
--   mgmt_vid     0 (native) | vid
--   dhcp         true when management is DHCP
--   static       {ip, netmask, gateway, dns = {...}} when it is static
---@param sys_raw string  system_cfg
---@return NetworkModel?
function M.parse(sys_raw)
	if type(sys_raw) ~= "string" then return nil end
	local vlan, bridge, netconf, dhcpc = {}, {}, {}, {}
	local gateway, dns_by_idx = nil, {}
	local seen = false

	local function slot(t, n)
		n = tonumber(n)
		t[n] = t[n] or {}
		return t[n]
	end

	for line in (sys_raw .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^([^=]+)=(.*)$")
		if k then
			local bn, pn, pk = k:match("^bridge%.(%d+)%.port%.(%d+)%.(.+)$")
			if bn then
				seen = true
				local b = slot(bridge, bn)
				b.ports = b.ports or {}
				if pk == "devname" then b.ports[tonumber(pn)] = v end
			else
				local bn2, bk = k:match("^bridge%.(%d+)%.(.+)$")
				if bn2 then
					seen = true
					slot(bridge, bn2)[bk] = v
				else
					local vn, vk = k:match("^vlan%.(%d+)%.(.+)$")
					if vn then slot(vlan, vn)[vk] = v end
					local nn, nk = k:match("^netconf%.(%d+)%.(.+)$")
					if nn then slot(netconf, nn)[nk] = v end
					local dn, dk = k:match("^dhcpc%.(%d+)%.(.+)$")
					if dn then slot(dhcpc, dn)[dk] = v end
					if k == "route.1.gateway" then gateway = v end
					local ri = k:match("^resolv%.nameserver%.(%d+)%.ip$")
					if ri and v ~= "" then dns_by_idx[tonumber(ri)] = v end
				end
			end
		end
	end
	if not seen then return nil end

	-- The uplink: what the vlan.* sub-devices hang off, or failing that the
	-- one bridge port that is neither a VAP nor a sub-device.
	local uplink
	for _, n in ipairs(sorted_keys(vlan)) do
		if vlan[n].devname and vlan[n].devname ~= "" then uplink = vlan[n].devname break end
	end
	local bridges = {}
	for _, n in ipairs(sorted_keys(bridge)) do
		local b = bridge[n]
		if b.devname then
			local ports = {}
			for _, pn in ipairs(sorted_keys(b.ports or {})) do ports[#ports + 1] = b.ports[pn] end
			bridges[#bridges + 1] = {devname = b.devname, ports = ports}
		end
	end
	if not uplink then
		for _, b in ipairs(bridges) do
			for _, p in ipairs(b.ports) do
				if not p:match("^ath") and not p:find(".", 1, true) then uplink = p break end
			end
			if uplink then break end
		end
	end
	uplink = uplink or "eth0"
	local sub = "^" .. lua_pattern_escape(uplink) .. "%.(%d+)$"

	local vids = {}
	for _, v in pairs(vlan) do
		local id = tonumber(v.id)
		if id and (v.devname == nil or v.devname == uplink) then vids[id] = true end
	end

	local bridge_vid, vaps_of = {}, {}
	for _, b in ipairs(bridges) do
		vaps_of[b.devname] = {}
		for _, p in ipairs(b.ports) do
			local vid = tonumber(p:match(sub) or "")
			if p == uplink then
				bridge_vid[b.devname] = 0
			elseif vid then
				bridge_vid[b.devname] = vid
				vids[vid] = true
			else
				vaps_of[b.devname][#vaps_of[b.devname] + 1] = p
			end
		end
	end

	-- Management: the DHCP client's bridge, else the bridge carrying a static
	-- address. A blob with neither leaves addressing to the board.
	local mgmt_bridge, dhcp, static = nil, false, nil
	for _, n in ipairs(sorted_keys(dhcpc)) do
		local d = dhcpc[n]
		if d.status == "enabled" and d.devname then
			mgmt_bridge, dhcp = d.devname, true
			break
		end
	end
	if not mgmt_bridge then
		for _, n in ipairs(sorted_keys(netconf)) do
			local c = netconf[n]
			if c.ip and c.ip ~= "" and c.ip ~= "0.0.0.0" and c.devname then
				local dns = {}
				for _, i in ipairs(sorted_keys(dns_by_idx)) do dns[#dns + 1] = dns_by_idx[i] end
				mgmt_bridge = c.devname
				static = {ip = c.ip, netmask = c.netmask, gateway = gateway, dns = dns}
				break
			end
		end
	end
	if not mgmt_bridge and bridge_vid["br0"] ~= nil then mgmt_bridge = "br0" end

	return {
		uplink      = uplink,
		vids        = vids,
		bridges     = bridges,
		bridge_vid  = bridge_vid,
		vaps_of     = vaps_of,
		mgmt_bridge = mgmt_bridge,
		mgmt_vid    = mgmt_bridge and bridge_vid[mgmt_bridge] or 0,
		dhcp        = dhcp,
		static      = static,
	}
end

return M
