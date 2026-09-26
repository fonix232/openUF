-- Tests for src/openwrt/switchvlan.lua (per-port VLAN assignment).
-- Run from project root: lua tests/run_tests.lua
--
-- In-memory mock UCI cursor, same shape as test_ucihelper.lua's plus the
-- cursor:get() switchvlan.lua needs for its no-op check.

local switchvlan = dofile("src/openwrt/switchvlan.lua")

local function new_mock_uci()
	local db, order = {}, {}
	local cursor = {}

	function cursor:set(config, section, a, b)
		-- libuci accepts only [A-Za-z0-9_] in a section name, and enforces it
		-- SILENTLY: set() returns true, commit() returns true, and the section
		-- is discarded before it ever reaches /etc/config. A permissive mock
		-- therefore hides the one bug this can cause -- and did: wlan_add's
		-- sanitizer kept "-", so every SSID with a hyphen provisioned nothing
		-- while every test passed. Fail loudly here instead.
		if not tostring(section):match("^[%w_]+$") then
			error("mock uci: invalid section name '" .. tostring(section)
				.. "' -- libuci would silently discard this", 2)
		end
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
		local s = db[config] and db[config][section]
		local v = s and s[key]
		-- Real libuci returns (nil, "Entry not found") for a miss. Mirroring
		-- that matters: a caller writing tonumber(cursor:get(...)) without
		-- parens passes the message string as tonumber's base and throws on
		-- the very first run. A single-value mock made that unreachable in
		-- tests and it only surfaced on real hardware.
		if v == nil then return nil, "Entry not found" end
		return v
	end

	function cursor:foreach(config, stype, fn)
		for _, name in ipairs(order[config] or {}) do
			local s = db[config][name]
			if s and s[".type"] == stype then fn(s) end
		end
	end

	function cursor:delete(config, section)
		if db[config] then db[config][section] = nil end
		for i, name in ipairs(order[config] or {}) do
			if name == section then table.remove(order[config], i) break end
		end
	end

	-- Recorded, not applied -- the counter lets tests catch a dropped commit.
	local commits = {}
	function cursor:commit(config)
		commits[config] = (commits[config] or 0) + 1
	end

	return {mock = {cursor = function() return cursor end}, db = db, cursor = cursor,
		commits = commits}
end

-- A DSA board: no `config switch`, no `config bridge-vlan`, a br-lan device
-- section holding the four sockets, and the bridge a tagged SSID already
-- built for VLAN 10. Modelled on the Xiaomi AX3000T.
local function dsa_board()
	local u = new_mock_uci()
	u.cursor:set("network", "brlan", "device")
	u.cursor:set("network", "brlan", "type", "bridge")
	u.cursor:set("network", "brlan", "name", "br-lan")
	u.cursor:set("network", "brlan", "ports", {"lan2", "lan3", "lan4", "wan"})
	u.cursor:set("network", "openuf_brdev10", "device")
	u.cursor:set("network", "openuf_brdev10", "type", "bridge")
	u.cursor:set("network", "openuf_brdev10", "name", "br-openuf10")
	u.cursor:set("network", "openuf_brdev10", "ports", {"wan.10"})
	return u
end

local DSA_CFG = {
	net = {lan_name = "lan", lan_cpueth = "wan", lan_vlanid = 1, ports = {
		{idx = 1, ifname = "wan"},
		{idx = 2, ifname = "lan2"},
		{idx = 3, ifname = "lan3"},
		{idx = 4, ifname = "lan4"},
	}},
}

-- Port 3 (lan3) assigned native VLAN 10.
local function dsa_push(port_idx, vid)
	return {
	{
		name = "switchvlan: apply is a no-op when gated off or absent",
		fn = function()
			with_capture(function(cmds)
				switchvlan._uci = dsa_board().mock
				assert_false(switchvlan.apply(nil, DSA_CFG, {}, "wan"), "nil block")
				local off = dsa_push(3, 10)
				off.enabled = false
				assert_false(switchvlan.apply(off, DSA_CFG, {}, "wan"), "gated off")
				assert_false(switchvlan.apply(dsa_push(3, 10), nil, {}, "wan"), "no board")
				assert_eq(#cmds, 0, "no command in any case")
			end)
		end
	},
		enabled = true,
		vlans   = {[vid] = {mode = "tagged", enabled = true}},
		ports   = {[port_idx] = {pvid = vid,
			vlans = {[1] = "exclude", [vid] = "untagged"}}},
	}
end

local function ports_of(u, section)
	local v = u.db.network[section].ports
	if type(v) == "string" then return {v} end
	return v or {}
end

local function joined(u, section)
	return table.concat(ports_of(u, section), ",")
end

local function with_capture(fn)
	local cmds = {}
	local orig = switchvlan._exec
	switchvlan._exec = function(c) cmds[#cmds + 1] = c return true end
	local ok, err = pcall(fn, cmds)
	switchvlan._exec = orig
	switchvlan._uci = nil
	if not ok then error(err, 0) end
end

local function silently(fn)
	local real = io.stderr
	io.stderr = {write = function() end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
end

return {
	{
		name = "switchvlan/dsa: an assigned socket moves from br-lan into the VLAN's bridge",
		fn = function()
			-- The whole feature. lan3 leaves br-lan and joins br-openuf10 --
			-- the same bridge the tagged SSID's wan.10 is already in, because
			-- a wired and a wireless client on VLAN 10 are one broadcast
			-- domain and the controller models them as one network.
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				local st = {}
				local changed = switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_true(changed, "UCI changed")
				assert_eq(joined(u, "brlan"), "lan2,lan4,wan", "lan3 left br-lan")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10,lan3",
					"and joined the VLAN 10 bridge, behind its tagged uplink")
				-- Searched for rather than taken as the last command: the tap
				-- reconcile runs after the reload, so position is not the
				-- claim being made here -- "exactly once" is.
				local reloads = 0
				for _, c in ipairs(cmds) do
					if c == "/etc/init.d/network reload 2>/dev/null" then
						reloads = reloads + 1
					end
				end
				assert_eq(reloads, 1, "network reloaded once")
				assert_eq(table.concat(st.dsa_brlan_ports, ","), "lan2,lan3,lan4,wan",
					"br-lan's original ports are in the ledger, pristine")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a moved socket gets an nft tap to report its hosts from",
		fn = function()
			-- The other half of `learning '0'`. With the FDB emptied for this
			-- socket there is nothing left for port_table to read, so the
			-- assignment also installs the bridge-family tap sysinfo reads
			-- instead -- otherwise the port silently reports no clients and
			-- the controller credits them to the gateway.
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, {}, "wan")
				local nft = {}
				for _, c in ipairs(cmds) do
					if c:find("^nft ") then nft[#nft + 1] = c end
				end
				assert_eq(#nft, 8, "delete, table, two sets, chain, three rules")
				assert_eq(nft[1], "nft delete table bridge openuf_learn 2>/dev/null",
					"rebuilt from scratch, like firewall.reconcile")
				assert_eq(nft[2], "nft add table bridge openuf_learn", "the table")
				assert_eq(nft[3], "nft add set bridge openuf_learn portmacs "
					.. "'{ type ifname . ether_addr; flags dynamic,timeout; timeout 5m; }'",
					"who is behind the socket")
				assert_eq(nft[4], "nft add set bridge openuf_learn portips "
					.. "'{ type ifname . ether_addr . ipv4_addr; flags dynamic,timeout; timeout 5m; }'",
					"and which address they hold -- what the network label needs")
				assert_eq(nft[5], "nft add chain bridge openuf_learn learn "
					.. "'{ type filter hook prerouting priority -300; policy accept; }'",
					"observing, never deciding")
				assert_eq(nft[6], "nft add rule bridge openuf_learn learn "
					.. "'iifname { \"lan3\" } update @portmacs "
					.. "{ iifname . ether saddr }'",
					"and only the socket that actually lost its learning")
				assert_eq(nft[7], "nft add rule bridge openuf_learn learn "
					.. "'iifname { \"lan3\" } arp saddr ip != 0.0.0.0 "
					.. "update @portips { iifname . ether saddr . arp saddr ip }'",
					"addresses from ARP, excluding the 0.0.0.0 of a probe")
			end)
		end
	},
	{
		name = "switchvlan/dsa: addresses are harvested from IPv4 as well as ARP",
		fn = function()
			-- A host that has finished DHCP may never ARP again inside the set
			-- timeout, and would then be reported with no address at all.
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, {}, "wan")
				local last
				for _, c in ipairs(cmds) do
					if c:find("^nft add rule") then last = c end
				end
				assert_eq(last, "nft add rule bridge openuf_learn learn "
					.. "'iifname { \"lan3\" } ip saddr != 0.0.0.0 "
					.. "update @portips { iifname . ether saddr . ip saddr }'",
					"the IPv4 source rule, excluding a DHCP DISCOVER's 0.0.0.0")
			end)
		end
	},
	{
		name = "switchvlan/dsa: every tapped socket shares one set and one rule",
		fn = function()
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				local push = dsa_push(3, 10)
				push.ports[2] = {pvid = 10, vlans = {[1] = "exclude", [10] = "untagged"}}
				switchvlan.apply(push, DSA_CFG, {}, "wan")
				local rule
				for _, c in ipairs(cmds) do
					if c:find("add rule", 1, true) then rule = c end
				end
				assert_not_nil(rule, "a rule was written")
				assert_true(rule:find('{ "lan2", "lan3" }', 1, true) ~= nil,
					"both sockets in one iifname set, sorted -- not a rule each")
			end)
		end
	},
	{
		name = "switchvlan/dsa: restore takes the tap down with the assignment",
		fn = function()
			-- A tap left standing would keep filing MACs for a socket that is
			-- back in br-lan and learning again, and mac_table prefers the FDB
			-- -- so it would leak rather than mislead. Tear it down anyway:
			-- an observer nothing reads is a per-frame cost for nothing.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, {dsa_brlan_ports = nil}, "wan")
			end)
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				switchvlan.restore({dsa_brlan_ports = {"lan2", "lan3", "lan4", "wan"}}, DSA_CFG)
				local nft = {}
				for _, c in ipairs(cmds) do
					if c:find("^nft ") then nft[#nft + 1] = c end
				end
				assert_eq(#nft, 1, "only the teardown")
				assert_eq(nft[1], "nft delete table bridge openuf_learn 2>/dev/null",
					"the table goes and nothing replaces it")
			end)
		end
	},
	{
		name = "switchvlan/dsa: the tap is rebuilt from UCI alone, for startup",
		fn = function()
			-- nftables state does not survive a reboot. inform.run calls this
			-- with no push and no state, so the sections dsa_apply left behind
			-- have to be the whole record of what to reinstall.
			local u = dsa_board()
			u.cursor:set("network", "openuf_brport10_lan3", "device")
			u.cursor:set("network", "openuf_brport10_lan3", "name", "lan3")
			u.cursor:set("network", "openuf_brport10_lan3", "learning", "0")
			-- ucihelper's tagged-uplink section is the same prefix without the
			-- socket suffix, and is NOT a tapped socket.
			u.cursor:set("network", "openuf_brport10", "device")
			u.cursor:set("network", "openuf_brport10", "name", "wan.10")
			u.cursor:set("network", "openuf_brport10", "learning", "0")
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				assert_true(switchvlan.reconcile_mac_taps(u.cursor), "a tap was installed")
				local rule
				for _, c in ipairs(cmds) do
					if c:find("add rule", 1, true) then rule = c end
				end
				assert_not_nil(rule, "a rule was written")
				assert_true(rule:find('{ "lan3" }', 1, true) ~= nil,
					"the moved socket is tapped")
				assert_true(rule:find("wan.10", 1, true) == nil,
					"the tagged uplink sub-device is not a socket and is not tapped")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a tap that already matches is left alone",
		fn = function()
			-- Rebuilding empties both sets, and everything in them was learned
			-- from traffic that has already happened -- so the socket reports
			-- NO clients until each host next speaks, and a host reported
			-- before its address is known is filed under the wrong network.
			-- openUF restarts far more often than an assignment changes.
			local u = dsa_board()
			u.cursor:set("network", "openuf_brport10_lan3", "device")
			u.cursor:set("network", "openuf_brport10_lan3", "name", "lan3")
			u.cursor:set("network", "openuf_brport10_lan3", "learning", "0")
			local orig = switchvlan._popen
			switchvlan._popen = function()
				return "table bridge openuf_learn {\n\tchain learn {\n"
					.. "\t\ttype filter hook prerouting priority dstnat; policy accept;\n"
					.. "\t\tiifname \"lan3\" update @portmacs { iifname . ether saddr }\n"
					.. "\t\tiifname \"lan3\" arp saddr ip != 0.0.0.0 update @portips "
					.. "{ iifname . ether saddr . arp saddr ip }\n\t}\n}\n"
			end
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				assert_true(switchvlan.reconcile_mac_taps(u.cursor), "the tap stands")
				assert_eq(#cmds, 0, "and not one nft command was run")
			end)
			switchvlan._popen = orig
		end
	},
	{
		name = "switchvlan/dsa: a tap covering the wrong sockets is rebuilt",
		fn = function()
			-- The converse, and the reason the check compares the socket list
			-- rather than merely noticing that a table exists.
			local u = dsa_board()
			u.cursor:set("network", "openuf_brport10_lan3", "device")
			u.cursor:set("network", "openuf_brport10_lan3", "name", "lan3")
			u.cursor:set("network", "openuf_brport10_lan3", "learning", "0")
			local orig = switchvlan._popen
			switchvlan._popen = function()
				return "table bridge openuf_learn {\n\tchain learn {\n"
					.. "\t\tiifname \"lan4\" update @portmacs { iifname . ether saddr }\n"
					.. "\t\tiifname \"lan4\" arp saddr ip != 0.0.0.0 update @portips "
					.. "{ iifname . ether saddr . arp saddr ip }\n\t}\n}\n"
			end
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				switchvlan.reconcile_mac_taps(u.cursor)
				assert_true(#cmds > 0, "a stale tap is replaced")
				assert_eq(cmds[1], "nft delete table bridge openuf_learn 2>/dev/null",
					"starting with the teardown")
			end)
			switchvlan._popen = orig
		end
	},
	{
		name = "switchvlan/dsa: nothing to tap tears the table down and adds nothing",
		fn = function()
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				assert_true(switchvlan.reconcile_mac_taps(u.cursor) == false,
					"no sockets, no tap")
				assert_eq(#cmds, 1, "one command")
				assert_eq(cmds[1], "nft delete table bridge openuf_learn 2>/dev/null",
					"and it is the teardown")
			end)
		end
	},
	{
		name = "switchvlan/dsa: the uplink socket is never reassigned",
		fn = function()
			-- The rule that keeps the AP reachable. Moving the socket the
			-- gateway is behind into an isolated bridge strands the device at
			-- the far end of a cable with no way back.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				silently(function()
					local changed = switchvlan.apply(dsa_push(1, 10), DSA_CFG, {}, "wan")
					assert_false(changed, "nothing applied")
				end)
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan", "br-lan untouched")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10", "and the uplink stayed put")
			end)
		end
	},
	{
		name = "switchvlan/dsa: an unknown uplink refuses every port, not just the uplink",
		fn = function()
			-- Fail closed. If the bridge FDB cannot say which socket faces the
			-- gateway -- an ARP cache that has not populated yet is enough --
			-- then applying ANY assignment is a coin flip on whether the one
			-- being moved is the uplink.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				silently(function()
					assert_false(switchvlan.apply(dsa_push(3, 10), DSA_CFG, {}, nil),
						"nothing applied without a known uplink")
				end)
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan", "br-lan untouched")
			end)
		end
	},
	{
		name = "switchvlan/dsa: un-assigning a socket brings it back to br-lan",
		fn = function()
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_eq(joined(u, "brlan"), "lan2,lan4,wan", "moved out")

				-- Same push with the port assignment removed.
				local off = {enabled = true, vlans = {}, ports = {}}
				local changed = switchvlan.apply(off, DSA_CFG, st, "wan")
				assert_true(changed, "the reconcile changed UCI")
				assert_eq(joined(u, "brlan"), "lan2,lan4,wan,lan3", "lan3 is back in br-lan")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10",
					"and out of the VLAN bridge, which keeps its tagged uplink")
			end)
		end
	},
	{
		name = "switchvlan/dsa: restore puts br-lan back exactly as the board shipped it",
		fn = function()
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_true(switchvlan.restore(st, DSA_CFG), "restore ran")
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan", "original port list, in order")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10",
					"the VLAN bridge survives -- a tagged SSID may still need it")
				assert_nil(st.dsa_brlan_ports, "ledger spent")
			end)
		end
	},
	{
		name = "switchvlan/dsa: restore names the bridge from the modelmap, not a constant",
		fn = function()
			-- dsa_apply moves sockets out of br-<lan_name>; a restore that
			-- went looking for a hardcoded "br-lan" would put nothing back on
			-- a board named anything else -- and report success while doing
			-- it, which is the worst shape a teardown can have.
			local u = new_mock_uci()
			u.cursor:set("network", "brhome", "device")
			u.cursor:set("network", "brhome", "type", "bridge")
			u.cursor:set("network", "brhome", "name", "br-home")
			u.cursor:set("network", "brhome", "ports", {"lan2", "lan3", "wan"})
			u.cursor:set("network", "openuf_brdev10", "device")
			u.cursor:set("network", "openuf_brdev10", "type", "bridge")
			u.cursor:set("network", "openuf_brdev10", "name", "br-openuf10")
			u.cursor:set("network", "openuf_brdev10", "ports", {"wan.10"})

			local cfg = {net = {lan_name = "home", lan_cpueth = "wan", lan_vlanid = 1,
				ports = {{idx = 1, ifname = "wan"}, {idx = 2, ifname = "lan2"},
					{idx = 3, ifname = "lan3"}}}}
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), cfg, st, "wan")
				assert_eq(joined(u, "brhome"), "lan2,wan", "lan3 moved out of br-home")
				assert_true(switchvlan.restore(st, cfg), "restore ran")
				assert_eq(joined(u, "brhome"), "lan2,lan3,wan", "and br-home got its list back")
			end)
		end
	},
	{
		name = "switchvlan/dsa: tearing down per-port VLAN leaves a tagged SSID's bridge alone",
		fn = function()
			-- The VLAN bridge belongs to ucihelper, restore() only hands
			-- br-lan its port list back, and the tagged uplink sub-device was
			-- never br-lan's to take. Gating restore on the wireless VLANs
			-- left the ledger unspent and br-lan holding the port order
			-- openUF had left behind -- unticking Port VLAN looked like a no-op.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10,lan3", "socket moved in")

				assert_true(switchvlan.restore(st, DSA_CFG), "restore ran")
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan",
					"br-lan back to the board's own list, in the board's own order")
				assert_eq(joined(u, "openuf_brdev10"), "wan.10",
					"the tagged SSID keeps its bridge and its uplink sub-device")
				assert_nil(st.dsa_brlan_ports, "and the ledger is spent")
			end)
		end
	},
	{
		name = "switchvlan/dsa: the ledger records the board's config, never openUF's own",
		fn = function()
			-- The failure this guards is silent and unrecoverable: snapshot
			-- after the first mutation and restore() faithfully puts back a
			-- br-lan that is already missing the moved socket, while
			-- reporting success.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				local first = table.concat(st.dsa_brlan_ports, ",")
				-- A second push moves another socket; the ledger must not move.
				switchvlan.apply(dsa_push(4, 10), DSA_CFG, st, "wan")
				assert_eq(table.concat(st.dsa_brlan_ports, ","), first,
					"still the pristine list after a second mutation")
				assert_eq(first, "lan2,lan3,lan4,wan", "which is the board's own")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a tagged assignment is refused rather than half-applied",
		fn = function()
			-- A bridge gives a port exactly one untagged home, which is what a
			-- Native VLAN is. Tagged membership would need a <ifname>.<vid>
			-- sub-device; no AP port control emits it, so it is declined out
			-- loud instead of shipped unverified.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local push = {enabled = true, vlans = {[10] = {mode = "tagged"}},
					ports = {[3] = {pvid = 1, vlans = {[10] = "tagged"}}}}
				silently(function()
					assert_false(switchvlan.apply(push, DSA_CFG, {}, "wan"),
						"nothing applied")
				end)
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan", "br-lan untouched")
			end)

			-- ...but a port that DID get a native VLAN is not "refused"
			-- anything just because other VLANs came through tagged. The
			-- controller's default Tagged VLAN Management is "Allow All",
			-- which marks every non-native VLAN tagged -- warning on that
			-- logged a line per VLAN on every inform about a default nobody
			-- chose. Confirmed live: "port lan3 tagged into VLAN 1" fired
			-- twice a push for a port that had been assigned correctly.
			local u2 = dsa_board()
			with_capture(function()
				switchvlan._uci = u2.mock
				local push = {enabled = true, vlans = {[10] = {mode = "tagged"}},
					ports = {[3] = {pvid = 10,
						vlans = {[1] = "tagged", [10] = "untagged"}}}}
				local warned = false
				local real = io.stderr
				io.stderr = {write = function(_, t)
					if tostring(t):find("tagged") then warned = true end
				end}
				local ok = pcall(switchvlan.apply, push, DSA_CFG, {}, "wan")
				io.stderr = real
				assert_true(ok, "applied")
				assert_false(warned, "no tagged warning for a port with a native VLAN")
				assert_eq(joined(u2, "openuf_brdev10"), "wan.10,lan3", "and it moved")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a port left on the management VLAN stays in br-lan",
		fn = function()
			-- Its native VLAN already IS br-lan; moving it into a bridge of
			-- its own would cut it off from the AP's own network for nothing.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local push = {enabled = true, vlans = {[1] = {mode = "untagged"}},
					ports = {[3] = {pvid = 1, vlans = {[1] = "untagged"}}}}
				assert_false(switchvlan.apply(push, DSA_CFG, {}, "wan"),
					"no change")
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan", "lan3 stayed home")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a steady-state re-push changes nothing and reloads nothing",
		fn = function()
			-- Every inform carries the same switch block. Rewriting the
			-- bridges each time would reload the network every ~10s and bounce
			-- the wired client the feature exists to serve.
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				local n = #cmds
				assert_false(switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan"),
					"second identical push is a no-op")
				assert_eq(#cmds, n, "and issues no reload")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a moved socket gets MAC learning turned off",
		fn = function()
			-- The ASIC has one address table shared with br-lan's uplink. Let
			-- it learn the attached device against the moved socket and a
			-- reply arriving tagged on the uplink resolves in hardware to a
			-- port that is no longer in the uplink's bridge, so the switch
			-- drops it instead of punting it to the CPU. Outbound stays
			-- perfect throughout, which is why nothing else catches this.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, {}, "wan")
				local sec = u.db.network["openuf_brport10_lan3"]
				assert_true(sec ~= nil, "the socket has a bridge-port section")
				assert_eq(sec.name, "lan3", "naming the socket")
				assert_eq(sec.learning, "0", "with MAC learning off")
				assert_true(u.db.network["openuf_brport10"] == nil,
					"and it does not collide with ucihelper's uplink override")
			end)
		end
	},
	{
		name = "switchvlan/dsa: the learning override does not re-dirty a steady push",
		fn = function()
			-- Same reasoning as the bridge lists above: a write that looks
			-- like a change on every inform reloads the network every ~10 s.
			local u = dsa_board()
			with_capture(function(cmds)
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				local n = #cmds
				assert_false(switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan"),
					"second identical push is a no-op")
				assert_eq(#cmds, n, "and issues no reload")
				assert_eq(u.db.network["openuf_brport10_lan3"].learning, "0",
					"the override is still there, just not rewritten")
			end)
		end
	},
	{
		name = "switchvlan/dsa: a socket sent home loses its learning override",
		fn = function()
			-- An override that outlives the assignment leaves a port back in
			-- br-lan with learning off, which silently costs that port its
			-- host list in port_table -- a regression with no symptom.
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_true(u.db.network["openuf_brport10_lan3"] ~= nil, "applied")
				switchvlan.apply({enabled = true, vlans = {}, ports = {}},
					DSA_CFG, st, "wan")
				assert_eq(joined(u, "brlan"), "lan2,lan4,wan,lan3", "lan3 came home")
				assert_true(u.db.network["openuf_brport10_lan3"] == nil,
					"and its learning override went with it")
			end)
		end
	},
	{
		name = "switchvlan/dsa: restore leaves no learning override behind",
		fn = function()
			local u = dsa_board()
			with_capture(function()
				switchvlan._uci = u.mock
				local st = {}
				switchvlan.apply(dsa_push(3, 10), DSA_CFG, st, "wan")
				assert_true(u.db.network["openuf_brport10_lan3"] ~= nil, "applied")
				switchvlan.restore(st, DSA_CFG)
				assert_true(u.db.network["openuf_brport10_lan3"] == nil,
					"teardown removed it")
				assert_eq(joined(u, "brlan"), "lan2,lan3,lan4,wan",
					"and br-lan is back as the board shipped it")
			end)
		end
	},
}
