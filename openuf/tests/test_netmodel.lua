-- Tests for src/openwrt/netmodel.lua (the controller's L2 model as one
-- vlan-filtering bridge, bridge takeover, rollback).
-- Run from project root: lua tests/run_tests.lua
--
-- Fixtures are real 10.6.106 pushes reduced to their topology keys:
--   system_cfg_10_6_vlans.txt     4 WLANs (untagged, VLAN 2/3/12), Port VLAN on,
--                                 port 2 native VLAN 3 with VLAN 2 excluded
--   system_cfg_10_6_mgmt_vlan.txt the same plus Management VLAN 50

local netmodel = dofile("src/openwrt/netmodel.lua")
local inform_switch_parse
do
	OPENUF_TEST_MODE = true
	local inform = dofile("src/inform.lua")
	inform_switch_parse = inform._parse_switch_system_cfg
end

local function fixture(name)
	local f = assert(io.open("tests/fixtures/" .. name, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

-- In-memory UCI with commit/revert, the same failure-loud section-name check
-- as test_switchvlan.lua's mock.
local function deepcopy(t)
	if type(t) ~= "table" then return t end
	local o = {}
	for k, v in pairs(t) do o[k] = deepcopy(v) end
	return o
end

local function new_mock_uci()
	local state = {db = {}, order = {}}
	local committed = deepcopy(state)
	local cursor = {}
	local commits = {}

	function cursor:set(config, section, a, b)
		if not tostring(section):match("^[%w_]+$") then
			error("mock uci: invalid section name '" .. tostring(section) .. "'", 2)
		end
		local db, order = state.db, state.order
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config] = order[config] or {}
			order[config][#order[config] + 1] = section
		end
		if b == nil then db[config][section][".type"] = a
		else db[config][section][a] = b end
	end
	function cursor:get(config, section, key)
		local s = state.db[config] and state.db[config][section]
		if not s then return nil, "Entry not found" end
		if key == nil then return s[".type"] end
		local v = s[key]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	function cursor:foreach(config, stype, fn)
		local names = {}
		for _, n in ipairs(state.order[config] or {}) do names[#names + 1] = n end
		for _, name in ipairs(names) do
			local s = state.db[config] and state.db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end
	function cursor:delete(config, section, option)
		local db = state.db
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, name in ipairs(state.order[config] or {}) do
			if name == section then table.remove(state.order[config], i) break end
		end
	end
	function cursor:commit(config)
		commits[config] = (commits[config] or 0) + 1
		committed = deepcopy(state)
	end
	function cursor:revert(config)
		state.db[config] = deepcopy(committed.db[config])
		state.order[config] = deepcopy(committed.order[config])
	end

	return {mock = {cursor = function() return cursor end}, cursor = cursor,
		state = state, commits = commits}
end

-- Fake filesystem + clock for the rollback path.
local function stub_io(fs)
	netmodel._read_file = function(p) return fs.files[p] end
	netmodel._write_file = function(p, c) fs.files[p] = c return true end
	netmodel._remove_file = function(p) fs.files[p] = nil end
	netmodel._run_cmd = function(c) fs.cmds[#fs.cmds + 1] = c return "" end
	netmodel._uptime = function() return fs.now end
	netmodel._log = function(m) fs.log[#fs.log + 1] = m end
end

local function new_fs()
	return {files = {["/etc/config/network"] = "config interface 'lan'\n"}, cmds = {}, now = 1000, log = {}}
end

-- An E8450-like board: five DSA sockets, uplink on `wan`, U6IW-style port
-- numbering (1-4 downstream, 5 = uplink).
local function e8450_cfg(extra)
	local cfg = {
		net = {
			lan_name = "lan", lan_cpueth = "wan",
			ports = {
				{idx = 1, ifname = "lan1"}, {idx = 2, ifname = "lan2"},
				{idx = 3, ifname = "lan3"}, {idx = 4, ifname = "lan4"},
				{idx = 5, ifname = "wan"},
			},
		},
		config = {},
	}
	for k, v in pairs(extra or {}) do cfg.config[k] = v end
	return cfg
end

-- This network's real bifrost layout: bridge `switch`, vlan_filtering, four
-- VLANs trunked to every socket, management on switch.1.
local function bifrost_uci()
	local u = new_mock_uci()
	local c = u.cursor
	c:set("network", "loopback", "interface")
	c:set("network", "loopback", "device", "lo")
	c:set("network", "switch", "device")
	c:set("network", "switch", "name", "switch")
	c:set("network", "switch", "type", "bridge")
	c:set("network", "switch", "ports", {"lan1", "lan2", "lan3", "lan4", "wan"})
	-- No vlan_filtering option, exactly as on the real AP: netifd filters any
	-- bridge a bridge-vlan section names.
	for _, v in ipairs({{"lan_vlan", "1", {"lan1", "lan2", "lan3", "lan4", "wan"}},
			{"guest_vlan", "2", {"lan1:t", "lan2:t", "lan3:t", "lan4:t", "wan:t"}},
			{"iot_vlan", "3", {"lan1:t", "lan2:t", "lan3:t", "lan4:t", "wan:t"}},
			{"vpn_vlan", "12", {"lan1:t", "lan2:t", "lan3:t", "lan4:t", "wan:t"}}}) do
		c:set("network", v[1], "bridge-vlan")
		c:set("network", v[1], "device", "switch")
		c:set("network", v[1], "vlan", v[2])
		c:set("network", v[1], "ports", v[3])
	end
	for _, i in ipairs({{"lan", "switch.1", "dhcp"}, {"guest", "switch.2", "none"},
			{"iot", "switch.3", "none"}, {"vpn_se", "switch.12", "dhcp"}}) do
		c:set("network", i[1], "interface")
		c:set("network", i[1], "device", i[2])
		c:set("network", i[1], "proto", i[3])
	end
	c:commit("network")
	return u
end

local function has(list, item)
	for _, v in ipairs(list or {}) do if v == item then return true end end
	return false
end

return {
	{
		name = "netmodel: parse reads the uplink, VLANs and native management",
		fn = function()
			local m = netmodel.parse(fixture("system_cfg_10_6_vlans.txt"))
			assert_eq(m.uplink, "eth0", "uplink devname")
			assert_true(m.vids[2] and m.vids[3] and m.vids[12], "uplink VLANs 2/3/12")
			assert_eq(m.bridge_vid["br0"], 0, "br0 carries the untagged network")
			assert_eq(m.bridge_vid["br0.3"], 3, "br0.3 is VLAN 3")
			assert_eq(m.mgmt_bridge, "br0", "management bridge")
			assert_eq(m.mgmt_vid, 0, "management untagged")
			assert_true(m.dhcp, "management is DHCP")
		end
	},
	{
		name = "netmodel: parse follows a Management VLAN to br0 = eth0.50 and br-trunk",
		fn = function()
			local m = netmodel.parse(fixture("system_cfg_10_6_mgmt_vlan.txt"))
			assert_true(m.vids[50], "VLAN 50 on the uplink")
			assert_eq(m.bridge_vid["br0"], 50, "br0 now holds only eth0.50")
			assert_eq(m.bridge_vid["br-trunk"], 0, "br-trunk carries the untagged network")
			assert_eq(m.mgmt_vid, 50, "management on VLAN 50")
			assert_true(has(m.vaps_of["br-trunk"], "ath0"), "untagged VAPs moved to br-trunk")
		end
	},
	{
		name = "netmodel: parse returns nil for a blob with no bridge block",
		fn = function()
			assert_nil(netmodel.parse("netconf.1.ip=0.0.0.0\nswitch.status=disabled\n"),
				"a partial push says nothing about L2")
		end
	},
	{
		name = "netmodel: plan renders the uplink trunk and the switch matrix",
		fn = function()
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local p = netmodel.plan(netmodel.parse(sys), inform_switch_parse(sys), e8450_cfg())
			assert_true(has(p.vlans[1].ports, "wan:u*"), "uplink native untagged")
			assert_true(has(p.vlans[12].ports, "wan:t"), "uplink trunks VLAN 12")
			assert_true(has(p.vlans[3].ports, "lan2:u*"), "port 2 native VLAN 3")
			assert_true(has(p.vlans[1].ports, "lan2:t"), "port 2 keeps VLAN 1 tagged")
			assert_false(has(p.vlans[2].ports, "lan2:t"), "VLAN 2 excluded on port 2")
			assert_true(has(p.vlans[1].ports, "lan1:u*"), "unconfigured port: device default")
			assert_true(has(p.vlans[2].ports, "lan1:t"), "unconfigured port: others tagged")
			assert_eq(p.mgmt.device, "br-lan.1", "management on the native VLAN")
			assert_eq(p.mgmt.proto, "dhcp", "DHCP management")
			assert_eq(netmodel.network_for(p, "br0"), "lan", "untagged VAPs join lan")
			assert_eq(netmodel.network_for(p, "br0.2"), "openuf_v2", "VLAN 2 VAPs")
		end
	},
	{
		name = "netmodel: plan with a Management VLAN tags it and gives the untagged VAPs their own network",
		fn = function()
			local sys = fixture("system_cfg_10_6_mgmt_vlan.txt")
			local p = netmodel.plan(netmodel.parse(sys), inform_switch_parse(sys), e8450_cfg())
			assert_eq(p.mgmt.device, "br-lan.50", "management on br-lan.50")
			assert_true(has(p.vlans[50].ports, "wan:t"), "VLAN 50 tagged on the uplink")
			assert_eq(netmodel.network_for(p, "br-trunk"), "openuf_v1", "untagged VAPs")
			assert_eq(netmodel.network_for(p, "br0"), "lan", "br0 is management")
			assert_eq(p.vlan_ifaces[1], "openuf_v1", "native VLAN gets an interface")
		end
	},
	{
		name = "netmodel: with Port VLAN off, sockets default to all (or native-only)",
		fn = function()
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local m = netmodel.parse(sys)
			local p = netmodel.plan(m, {enabled = false}, e8450_cfg())
			assert_true(has(p.vlans[1].ports, "lan2:u*"), "native untagged")
			assert_true(has(p.vlans[3].ports, "lan2:t"), "all: others tagged")
			local p2 = netmodel.plan(m, {enabled = false}, e8450_cfg({port_default = "native"}))
			assert_false(has(p2.vlans[3].ports, "lan2:t"), "native: no tagged VLANs")
			assert_true(has(p2.vlans[3].ports, "wan:t"), "the uplink always trunks")
		end
	},
	{
		name = "netmodel: backend auto picks vlan_filtering only where the uplink's bridge filters",
		fn = function()
			local u = bifrost_uci()
			assert_eq(netmodel.backend(e8450_cfg(), u.cursor), "vlan_filtering", "bifrost layout")
			local plain = new_mock_uci()
			plain.cursor:set("network", "br", "device")
			plain.cursor:set("network", "br", "type", "bridge")
			plain.cursor:set("network", "br", "ports", {"wan", "lan1"})
			assert_eq(netmodel.backend(e8450_cfg(), plain.cursor), "bridges", "stock br-lan")
			assert_eq(netmodel.backend(e8450_cfg({bridge_backend = "vlan_filtering"}), plain.cursor),
				"vlan_filtering", "explicit choice wins")
			local flagged = bifrost_uci()
			flagged.cursor:set("network", "switch", "vlan_filtering", "1")
			assert_eq(netmodel.backend(e8450_cfg(), flagged.cursor), "vlan_filtering", "explicit option")
			local sw = e8450_cfg()
			sw.vlan = {ports = {}}
			assert_eq(netmodel.backend(sw, u.cursor), "bridges", "swconfig boards never")
		end
	},
	{
		name = "netmodel: with own_config=false the takeover keeps foreign interfaces working",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local st = {}
			local changed, plan = netmodel.converge(netmodel.parse(sys), inform_switch_parse(sys),
				e8450_cfg({own_config = false}), st, {identity_mac = "00:00:5e:00:53:3e"})
			local c = u.cursor
			assert_true(changed, "network changed")
			assert_nil(c:get("network", "switch"), "the foreign bridge is gone")
			assert_nil(c:get("network", "guest_vlan"), "its bridge-vlan sections too")
			assert_eq(c:get("network", "openuf_br", "name"), "br-lan", "new bridge")
			assert_eq(c:get("network", "openuf_br", "vlan_filtering"), "1", "filtering")
			assert_eq(c:get("network", "openuf_br", "macaddr"), "00:00:5e:00:53:3e", "identity MAC pinned")
			assert_eq(c:get("network", "lan", "device"), "br-lan.1", "management re-homed")
			assert_eq(c:get("network", "iot", "device"), "br-lan.3", "foreign VLAN interface re-pointed")
			assert_eq(c:get("network", "openuf_bv12", "vlan"), "12", "VLAN 12 in the table")
			assert_true(st.netmodel_pending ~= nil, "rollback armed")
			assert_eq(fs.files[netmodel.ROLLBACK_FILE], "config interface 'lan'\n", "previous config saved")
			assert_eq(fs.files[netmodel.PRISTINE_FILE], "config interface 'lan'\n", "pristine copy kept")
			assert_true(has(fs.cmds, "/etc/init.d/network reload"), "network reloaded")
			assert_true(plan ~= nil, "plan returned")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: by default the takeover owns the interfaces too",
		fn = function()
			local u = bifrost_uci()
			local c = u.cursor
			c:set("network", "wan6", "interface")
			c:set("network", "wan6", "device", "wan")
			c:set("network", "wan6", "proto", "dhcpv6")
			c:set("network", "wg0", "interface")
			c:set("network", "wg0", "proto", "wireguard")
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local st = {}
			netmodel.converge(netmodel.parse(sys), inform_switch_parse(sys), e8450_cfg(), st,
				{identity_mac = "00:00:5e:00:53:3e"})
			assert_eq(c:get("network", "lan", "device"), "br-lan.1", "management kept and re-homed")
			assert_nil(c:get("network", "guest"), "foreign VLAN interface removed")
			assert_nil(c:get("network", "iot"), "foreign VLAN interface removed")
			assert_nil(c:get("network", "vpn_se"), "no leftover address on VLAN 12")
			assert_nil(c:get("network", "wan6"), "socket L3 interface removed")
			assert_eq(c:get("network", "wg0"), "interface", "unrelated interfaces untouched")
			assert_eq(#st.netmodel_removed, 4, "recorded")
			assert_eq(fs.files[netmodel.PRISTINE_FILE], "config interface 'lan'\n", "pristine copy kept")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: a DHCP management interface keeps its lease and asks for its address",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_vlans.txt")
			netmodel.converge(netmodel.parse(sys), inform_switch_parse(sys), e8450_cfg(), {},
				{identity_mac = "00:00:5e:00:53:3e", current_ip = "10.0.0.3"})
			local c = u.cursor
			assert_eq(c:get("network", "lan", "proto"), "dhcp", "still DHCP")
			assert_eq(c:get("network", "lan", "norelease"), "1", "no release on restart")
			assert_eq(c:get("network", "lan", "ipaddr"), "10.0.0.3", "asks for the address it had")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: repair_default_route restores a route netifd has and the kernel lost",
		fn = function()
			local cmds = {}
			local orig_run, orig_log = netmodel._run_cmd, netmodel._log
			local kernel_route = ""
			netmodel._log = function() end
			netmodel._run_cmd = function(cmd)
				cmds[#cmds + 1] = cmd
				if cmd:find("ubus call network.interface.lan status", 1, true) then
					return '{"up":true,"l3_device":"br-lan.1","route":[{"target":"0.0.0.0","mask":0,'
						.. '"nexthop":"10.0.0.1","source":"10.0.0.4/32"}]}'
				elseif cmd == "ip -4 route show default" then
					return kernel_route
				end
				return ""
			end
			assert_true(netmodel.repair_default_route("lan"), "repaired")
			assert_eq(cmds[#cmds], "ip -4 route replace default via 10.0.0.1 dev br-lan.1", "route put back")
			kernel_route = "default via 10.0.0.1 dev br-lan.1\n"
			assert_false(netmodel.repair_default_route("lan"), "nothing to do when the kernel has it")
			netmodel._run_cmd, netmodel._log = orig_run, orig_log
		end
	},
	{
		name = "netmodel: converge is idempotent -- a steady-state push changes nothing",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local st = {}
			local m, sw = netmodel.parse(sys), inform_switch_parse(sys)
			netmodel.converge(m, sw, e8450_cfg(), st, {})
			netmodel.check(st, true)
			local commits = u.commits.network
			local changed = netmodel.converge(m, sw, e8450_cfg(), st, {})
			assert_false(changed, "second converge is a no-op")
			assert_eq(u.commits.network, commits, "no extra commit")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: an unconfirmed plan is rolled back and not retried",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_mgmt_vlan.txt")
			local st = {}
			local m, sw = netmodel.parse(sys), inform_switch_parse(sys)
			netmodel.converge(m, sw, e8450_cfg(), st, {})
			fs.files["/etc/config/network"] = "new config"
			assert_nil(netmodel.check(st, false), "inside the window: wait")
			fs.now = fs.now + netmodel.ROLLBACK_TIMEOUT + 1
			assert_eq(netmodel.check(st, false), "rolled_back", "window over: roll back")
			assert_eq(fs.files["/etc/config/network"], "config interface 'lan'\n", "old config restored")
			assert_true(st.netmodel_failed ~= nil, "failed plan remembered")
			local changed = netmodel.converge(m, sw, e8450_cfg(), st, {})
			assert_false(changed, "the same plan is not applied again")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: a successful inform confirms and drops the rollback copy",
		fn = function()
			local fs = new_fs()
			stub_io(fs)
			fs.files[netmodel.ROLLBACK_FILE] = "x"
			local st = {netmodel_pending = {fp = "abc", since = fs.now, timeout = 10}}
			assert_eq(netmodel.check(st, true), "confirmed", "confirmed")
			assert_nil(st.netmodel_pending, "pending cleared")
			assert_nil(fs.files[netmodel.ROLLBACK_FILE], "rollback copy removed")
		end
	},
	{
		name = "netmodel: bridge_takeover=false leaves foreign bridges alone",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local changed, plan = netmodel.converge(netmodel.parse(sys), inform_switch_parse(sys),
				e8450_cfg({bridge_takeover = false}), {}, {})
			assert_false(changed, "nothing written")
			assert_nil(plan, "no plan: the caller keeps its own path")
			assert_eq(u.cursor:get("network", "switch", "type"), "bridge", "foreign bridge kept")
			assert_nil(u.cursor:get("network", "openuf_br"), "no second bridge on the same sockets")
			netmodel._uci = nil
		end
	},
	{
		name = "netmodel: fingerprint stays formattable for hashes >= 2^31 (LNUM Lua)",
		fn = function()
			local sys = fixture("system_cfg_10_6_vlans.txt")
			local m, sw = netmodel.parse(sys), inform_switch_parse(sys)
			-- Walk a few plans; any of them may hash above 2^31.
			for i = 1, 40 do
				local p = netmodel.plan(m, sw, e8450_cfg(), {identity_mac = string.format("02:00:00:00:00:%02x", i)})
				local fp = netmodel.fingerprint(p)
				assert_true(fp:match("^%x%x%x%x%x%x%x%x$") ~= nil, "8 hex digits: " .. fp)
			end
		end
	},
	{
		name = "netmodel: no rollback copy, no change -- the plan is not committed",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			netmodel._write_file = function(p, c)
				if p == netmodel.ROLLBACK_FILE then return false end
				fs.files[p] = c
				return true
			end
			local sys = fixture("system_cfg_10_6_mgmt_vlan.txt")
			local st = {}
			local commits = u.commits.network
			local changed, plan, outcome = netmodel.converge(netmodel.parse(sys),
				inform_switch_parse(sys), e8450_cfg(), st, {})
			netmodel._uci = nil
			assert_false(changed, "nothing applied")
			assert_nil(plan, "no plan for the WiFi pass")
			assert_eq(outcome, "failed", "outcome")
			assert_eq(u.commits.network, commits, "UCI not committed")
			assert_nil(st.netmodel_pending, "no rollback armed")
			assert_eq(#fs.cmds, 0, "network not reloaded")
		end
	},
	{
		name = "netmodel: a failed commit is a failed plan, and its rollback copy goes",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			u.cursor.commit = function() return false end
			local sys = fixture("system_cfg_10_6_mgmt_vlan.txt")
			local st = {}
			local changed, plan, outcome = netmodel.converge(netmodel.parse(sys),
				inform_switch_parse(sys), e8450_cfg(), st, {})
			netmodel._uci = nil
			assert_false(changed, "nothing applied")
			assert_eq(outcome, "failed", "outcome")
			assert_nil(plan, "no plan")
			assert_nil(fs.files[netmodel.ROLLBACK_FILE], "no stale rollback copy")
			assert_nil(st.netmodel_pending, "no rollback armed")
		end
	},
	{
		name = "netmodel: a rollback that cannot write keeps its copy and tries again",
		fn = function()
			local fs = new_fs()
			stub_io(fs)
			fs.files[netmodel.ROLLBACK_FILE] = "the old network"
			local st = {netmodel_pending = {fp = "abc", since = fs.now, timeout = 10}}
			fs.now = fs.now + 11
			local writes_fail = true
			netmodel._write_file = function(p, c)
				if writes_fail then return false end
				fs.files[p] = c
				return true
			end
			assert_eq(netmodel.check(st, false), "rollback_failed", "reported")
			assert_eq(fs.files[netmodel.ROLLBACK_FILE], "the old network", "copy kept")
			assert_not_nil(st.netmodel_pending, "still pending")
			assert_eq(#fs.cmds, 0, "no reload of a network that was not restored")
			writes_fail = false
			assert_eq(netmodel.check(st, false), "rolled_back", "the next try restores")
			assert_eq(fs.files["/etc/config/network"], "the old network", "restored")
			assert_nil(fs.files[netmodel.ROLLBACK_FILE], "copy spent")
			assert_eq(st.netmodel_failed, "abc", "the plan is remembered as failed")
		end
	},
	{
		name = "netmodel: a plan that was rolled back comes back rejected, with no plan",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = fixture("system_cfg_10_6_mgmt_vlan.txt")
			local m, sw = netmodel.parse(sys), inform_switch_parse(sys)
			local st = {}
			local _, plan = netmodel.converge(m, sw, e8450_cfg(), st, {})
			st.netmodel_failed = netmodel.fingerprint(plan)
			local changed, again, outcome = netmodel.converge(m, sw, e8450_cfg(), st, {})
			netmodel._uci = nil
			assert_false(changed, "not applied")
			assert_nil(again, "the refused plan is not handed on")
			assert_eq(outcome, "rejected", "outcome")
		end
	},
	{
		name = "netmodel: a controller network tagged with VLAN 1 is refused, not merged into the untagged one",
		fn = function()
			local u = bifrost_uci()
			local fs = new_fs()
			netmodel._uci = u.mock
			stub_io(fs)
			local sys = table.concat({
				"vlan.1.devname=eth0", "vlan.1.id=1",
				"bridge.1.devname=br0", "bridge.1.port.1.devname=eth0", "bridge.1.port.2.devname=ath0",
				"bridge.2.devname=br0.1", "bridge.2.port.1.devname=eth0.1", "bridge.2.port.2.devname=ath1",
				"dhcpc.1.status=enabled", "dhcpc.1.devname=br0",
			}, "\n") .. "\n"
			local m = netmodel.parse(sys)
			local commits = u.commits.network
			local plan, why = netmodel.plan(m, nil, e8450_cfg(), {})
			assert_nil(plan, "no plan")
			assert_true(tostring(why):find("VLAN 1", 1, true) ~= nil, "says why")
			local changed, p2, outcome = netmodel.converge(m, nil, e8450_cfg(), {}, {})
			netmodel._uci = nil
			assert_false(changed, "nothing written")
			assert_nil(p2, "no plan")
			assert_eq(outcome, "rejected", "rejected")
			assert_eq(u.commits.network, commits, "not committed")
		end
	},
}
