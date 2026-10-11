-- Tests for the controller features behind the capability bits claimed on
-- 2026-10-10: MAC-based VLANs, the Multicast Suppressor, WLAN Schedule,
-- Hotspot 2.0, RADIUS Filter-Id, SNMP, and the roam topology events
-- (sta_roam / assoc_status). Wire shapes are from the decompiled 10.6.106
-- controller (PROTOCOL-VALIDATION.md); consumers are replayed into a
-- recording mock UCI and recorded nft/shell commands.
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true

local inform    = dofile("src/inform.lua")
local ucihelper = require("openwrt.ucihelper")
local schedule  = require("unifi.schedule")
local wlansched = require("openwrt.wlansched")
local hotspot2  = require("openwrt.hotspot2")
local bcfilter  = require("openwrt.bcfilter")
local snmp_p    = require("unifi.snmp")
local snmp      = require("openwrt.snmp")
local staevents = require("unifi.staevents")
local roamassist = require("openwrt.roamassist")
local wlan      = require("unifi.wlan")
local hotspot2_p = require("unifi.hotspot2")

local function new_mock_uci()
	local db, order, commits = {}, {}, {}
	local cursor = {}
	function cursor:set(config, section, a, b)
		if not tostring(section):match("^[%w_]+$") then
			error("mock uci: invalid section name '" .. tostring(section) .. "'", 2)
		end
		db[config] = db[config] or {}
		order[config] = order[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
			order[config][#order[config] + 1] = section
		end
		if b == nil then
			db[config][section][".type"] = a
		elseif type(b) == "table" then
			local list = {}
			for i, v in ipairs(b) do list[i] = tostring(v) end
			db[config][section][a] = list
		else
			db[config][section][a] = b
		end
	end
	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		if option == nil then return s and s[".type"] end
		return s and s[option]
	end
	function cursor:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, name in ipairs(order[config] or {}) do
			if name == section then table.remove(order[config], i); break end
		end
	end
	function cursor:foreach(config, stype, fn)
		local names = {}
		for _, n in ipairs(order[config] or {}) do names[#names + 1] = n end
		for _, name in ipairs(names) do
			local s = db[config] and db[config][name]
			if s and (stype == nil or s[".type"] == stype) then fn(s) end
		end
	end
	function cursor:commit(config) commits[config] = (commits[config] or 0) + 1 end
	return {cursor = function() return cursor end}, db, commits
end

local function quiet(fn)
	local real = io.stderr
	local log = {}
	io.stderr = {write = function(_, s) log[#log + 1] = s end}
	local ok, err = pcall(fn, log)
	io.stderr = real
	if not ok then error(err, 0) end
	return log
end

-- ucihelper against a mock UCI; files and shell commands recorded.
local function with_uci(fn)
	local mock, db = new_mock_uci()
	local saved = {}
	for _, k in ipairs({"_uci", "_popen", "_read_file", "_write_file", "_remove_file",
			"_run_cmd", "_bcfilter", "_shaper", "_date"}) do saved[k] = ucihelper[k] end
	local files, removed, rules = {}, {}, {}
	ucihelper._uci = mock
	ucihelper._popen = function(cmd)
		if cmd:find("^ls ") then
			local out = {}
			for p in pairs(files) do out[#out + 1] = p:match("[^/]+$") end
			out[#out + 1] = "macvlan-openuf_radio0_Gone.list"
			out[#out + 1] = "state.json"
			return table.concat(out, "\n")
		end
		return ""
	end
	ucihelper._read_file = function(p) return files[p] end
	ucihelper._write_file = function(p, c) files[p] = c; return true end
	ucihelper._remove_file = function(p) removed[#removed + 1] = p; files[p] = nil end
	ucihelper._run_cmd = function() return true end
	ucihelper._bcfilter = {reconcile = function(r) rules[#rules + 1] = r end}
	ucihelper._shaper = {reconcile = function() end}
	ucihelper._date = function() return {wday = 2, hour = 12, min = 0} end   -- Monday noon
	ucihelper._phy_caps_cache = nil
	local c = mock.cursor()
	c:set("wireless", "radio0", "wifi-device")
	c:set("wireless", "radio0", "band", "2g")
	c:set("wireless", "radio1", "wifi-device")
	c:set("wireless", "radio1", "band", "5g")
	local log
	local ok, err = pcall(function()
		log = quiet(function(l) fn(db, {files = files, removed = removed, rules = rules, log = l}) end)
	end)
	for k, v in pairs(saved) do ucihelper[k] = v end
	ucihelper._phy_caps_cache = nil
	if not ok then error(err, 2) end
	return log
end

-- A PSK WLAN on radio1 (aaa/wireless 1) and an Enterprise one on radio0 (2).
local function cfg(extra)
	local lines = {
		"radio.1.phyname=radio0", "radio.2.phyname=radio1",
		"aaa.1.devname=ath0", "aaa.1.wpa=2", "aaa.1.wpa.key.1.mgmt=WPA-PSK",
		"aaa.1.wpa.psk=hunter2222", "aaa.1.br.devname=br0",
		"wireless.1.ssid=home", "wireless.1.parent=radio1", "wireless.1.devname=ath0",
		"aaa.2.devname=ath1", "aaa.2.wpa=2", "aaa.2.wpa.key.1.mgmt=WPA-EAP",
		"aaa.2.wpa.1.pairwise=CCMP",
		"aaa.2.radius.auth.1.ip=192.0.2.1", "aaa.2.radius.auth.1.port=1812",
		"aaa.2.radius.auth.1.secret=s3cret", "aaa.2.br.devname=br0",
		"wireless.2.ssid=corp", "wireless.2.parent=radio0", "wireless.2.devname=ath1",
	}
	for _, l in ipairs(extra or {}) do lines[#lines + 1] = l end
	return table.concat(lines, "\n") .. "\n"
end

local function parse(extra)
	local vaps
	quiet(function() local _; _, vaps = inform._parse_wifi_system_cfg(cfg(extra)) end)
	return vaps[1], vaps[2]
end

local function apply(sys, conf)
	local radio_table, vap_table
	quiet(function() radio_table, vap_table = inform._parse_wifi_system_cfg(sys) end)
	ucihelper.apply_config({radio_table = radio_table, vap_table = vap_table},
		conf or {net = {lan_cpueth = "eth1"}})
	return vap_table
end

local MACVLAN = {
	"aaa.1.accept_mac.status=enabled",
	"aaa.1.accept_mac.1.mac=00:00:5E:00:53:02", "aaa.1.accept_mac.1.vlanid=20",
	"aaa.1.accept_mac.2.mac=00:00:5e:00:53:01", "aaa.1.accept_mac.2.vlanid=30",
	"aaa.1.accept_mac.3.mac=00:00:5e:00:53:03", "aaa.1.accept_mac.3.vlanid=1",
	"aaa.1.accept_mac.4.mac=bogus", "aaa.1.accept_mac.4.vlanid=40",
}

return {
	-- ─── MAC-based VLANs ─────────────────────────────────────────────────────
	{
		name = "caps: MAC-based VLANs parse per aaa block, sorted, lowercase, malformed dropped",
		fn = function()
			local home, corp = parse(MACVLAN)
			assert_eq(#home.mac_vlans, 3, "three good entries")
			assert_eq(home.mac_vlans[1].mac, "00:00:5e:00:53:01", "sorted by MAC")
			assert_eq(home.mac_vlans[1].vid, 30, "with its VLAN")
			assert_eq(home.mac_vlans[2].mac, "00:00:5e:00:53:02", "lowercased")
			assert_eq(home.mac_vlans[3].vid, 1, "VLAN 1 = untagged LAN kept")
			assert_nil(corp.mac_vlans, "absent block: nil")
			local h2 = parse({"aaa.1.accept_mac.1.mac=00:00:5e:00:53:02", "aaa.1.accept_mac.1.vlanid=20"})
			assert_nil(h2.mac_vlans, "entries without accept_mac.status=enabled are not read")
		end
	},
	{
		name = "caps: MAC-based VLANs become an accept_mac_file with VLAN ids and wifi-vlan sections",
		fn = function()
			with_uci(function(db, io_)
				apply(cfg(MACVLAN))
				local s = db.wireless.openuf_radio1_home
				local path = ucihelper.macvlan_path("openuf_radio1_home",
					"00:00:5e:00:53:01 30\n00:00:5e:00:53:02 20\n")
				assert_true(path:match("^/etc/openuf/macvlan%-openuf_radio1_home%-%x%x%x%x%x%x%x%x%.list$") ~= nil,
					"the list's name carries its hash: " .. path)
				assert_eq(io_.files[path], "00:00:5e:00:53:01 30\n00:00:5e:00:53:02 20\n",
					"one '<mac> <vid>' line per client; VLAN 1 on an untagged WLAN changes nothing")
				assert_contains(table.concat(s.hostapd_bss_options, "|"),
					"accept_mac_file=" .. path, "hostapd reads it")
				assert_eq(s.dynamic_vlan, "1", "dynamic_vlan, so ap.uc writes vlan_no_bridge")
				assert_nil(s.macfilter, "no MAC filter of its own: macaddr_acl stays 0")
				local v20 = db.wireless.openuf_radio1_home_vlan20
				assert_eq(v20[".type"], "wifi-vlan", "a wifi-vlan per VLAN")
				assert_eq(v20.vid, "20", "vid")
				assert_eq(v20.network[1], "openuf_vlan20", "on that VLAN's network")
				assert_nil(db.wireless.openuf_radio1_home_vlan1, "no VLAN-1 section for it")
				assert_eq(io_.removed[1], "/etc/openuf/macvlan-openuf_radio0_Gone.list",
					"a list no WLAN uses any more is removed, nothing else")
				assert_eq(#io_.removed, 1, "state.json untouched")
			end)
		end
	},
	{
		name = "caps: MAC-based VLANs never widen a MAC filter or bypass RADIUS MAC auth",
		fn = function()
			local function plan(over)
				local v = {ssid = "x", security = "wpa2", mac_vlans = {
					{mac = "00:00:5e:00:53:01", vid = 20}, {mac = "00:00:5e:00:53:02", vid = 30},
					{mac = "00:00:5e:00:53:03", vid = 1}}}
				for k, val in pairs(over) do v[k] = val end
				local p
				quiet(function() p = ucihelper.macvlan_plan(v, function(vid) return "net" .. vid end) end)
				return p
			end
			assert_eq(plan({vlan_enabled = true, vlan = 40}).macs, 3, "no filter: all (tagged VAP)")
			assert_eq(plan({}).macs, 2, "untagged VAP: the VLAN-1 entry is its own network")
			local deny = plan({mac_filter_policy = "deny", mac_filter_list = {"00:00:5E:00:53:01"},
				vlan_enabled = true, vlan = 40})
			assert_eq(deny.content, "00:00:5e:00:53:02 30\n00:00:5e:00:53:03 1\n",
				"a denied (or lock2ap) MAC stays out of the accept list, which hostapd checks first")
			local allow = plan({mac_filter_policy = "allow", mac_filter_list = {"00:00:5e:00:53:02"}})
			assert_eq(allow.content, "00:00:5e:00:53:02 30\n", "only allow-listed MACs keep a VLAN")
			assert_nil(plan({radius_mac_auth = true}), "RADIUS MAC auth: not applied")
			assert_nil(plan({security = "open"}), "open WLAN: not applied")
			assert_nil(plan({security = "owe"}), "OWE: not applied")
			local own = plan({vlan_enabled = true, vlan = 20})
			assert_eq(own.content, "00:00:5e:00:53:02 30\n00:00:5e:00:53:03 1\n",
				"an entry on the VAP's own VLAN is left out")
			assert_eq(plan({vlan_enabled = true, vlan = 40}).networks[1], "net1", "VLAN 1 resolved")
			local nonet
			quiet(function()
				nonet = ucihelper.macvlan_plan({ssid = "x", security = "wpa2",
					mac_vlans = {{mac = "00:00:5e:00:53:01", vid = 20}}}, function() return nil end)
			end)
			assert_nil(nonet, "no network for the VLAN: left out")
		end
	},
	{
		name = "caps: MAC-based VLAN lists are rewritten only on change, and go with the block",
		fn = function()
			with_uci(function(db, io_)
				apply(cfg(MACVLAN))
				local path = ucihelper.macvlan_path("openuf_radio1_home",
					"00:00:5e:00:53:01 30\n00:00:5e:00:53:02 20\n")
				local writes = 0
				local w = ucihelper._write_file
				ucihelper._write_file = function(p, c) writes = writes + 1; return w(p, c) end
				apply(cfg(MACVLAN))
				assert_eq(writes, 0, "same push: flash untouched")
				apply(cfg())
				assert_nil(io_.files[path], "block gone: list removed")
				assert_nil(db.wireless.openuf_radio1_home.hostapd_bss_options, "and its raw line")
				assert_nil(db.wireless.openuf_radio1_home_vlan20, "and its wifi-vlan")
			end)
		end
	},
	{
		name = "caps: MAC-based VLANs hand their VLANs to the vlan_filtering plan",
		fn = function()
			-- provision.lua collects key_vids for netmodel from the vap table.
			local src = io.open("src/openwrt/provision.lua"):read("*a")
			assert_contains(src, "for _, e in ipairs(vap.mac_vlans or {}) do", "the vids are collected")
			with_uci(function(db)
				local radio_table, vap_table
				local lines = {"aaa.1.br.devname=br0.20"}
				for _, l in ipairs(MACVLAN) do lines[#lines + 1] = l end
				quiet(function() radio_table, vap_table = inform._parse_wifi_system_cfg(cfg(lines)) end)
				ucihelper.apply_config({radio_table = radio_table, vap_table = vap_table}, {net = {}},
					{netmodel = {bridge = {name = "br-lan"}, mgmt = {iface = "lan", device = "br-lan"},
						net_for_bridge = {br0 = "lan", ["br0.20"] = "openuf_v20"},
					vlan_ifaces = {[20] = "openuf_v20", [30] = "openuf_v30"}}})
				assert_eq(db.wireless.openuf_radio1_home.network, "openuf_v20", "the VAP on VLAN 20")
				assert_eq(db.wireless.openuf_radio1_home_vlan30.network[1], "openuf_v30", "plan interface")
				assert_nil(db.wireless.openuf_radio1_home_vlan20, "its own VLAN: no override")
				assert_eq(db.wireless.openuf_radio1_home_vlan1.network[1], "lan", "VLAN 1 = br0's network")
			end)
		end
	},

	-- ─── Multicast Suppressor ────────────────────────────────────────────────
	{
		name = "caps: Multicast Suppressor parses Conservative and Aggressive apart",
		fn = function()
			local home = parse({"wireless.1.multicast.suppressor=enabled"})
			assert_eq(home.mcast_suppressor, "conservative", "suppressor alone = Conservative")
			assert_nil(home.bcfilt_enabled, "no blocker")
			home = parse({"wireless.1.multicast.suppressor=enabled", "wireless.1.bcfilt.status=enabled",
				"wireless.1.bcfilt.bypass_types=ARP|NSNA|DHCPV4|DHCPV6|BOGUS",
				"wireless.1.bcfilt.1.status=enabled", "wireless.1.bcfilt.1.mac=00:00:5e:00:53:09"})
			assert_eq(home.mcast_suppressor, "aggressive", "bypass types = Aggressive")
			assert_eq(table.concat(home.bcfilt_bypass, ","), "ARP,NSNA,DHCPV4,DHCPV6", "known types only")
			assert_true(home.bcfilt_enabled, "the blocker carries it")
			assert_nil(parse({}).mcast_suppressor, "off")
		end
	},
	{
		name = "caps: Multicast Suppressor reaches the nft rules and the reboot record",
		fn = function()
			with_uci(function(db, io_)
				ucihelper.get_ifnames_for_vap = function(radio) return {radio == "radio1" and "phy1-ap0" or "phy0-ap0"} end
				apply(cfg({"wireless.1.multicast.suppressor=enabled", "wireless.2.multicast.suppressor=enabled",
					"wireless.2.bcfilt.status=enabled", "wireless.2.bcfilt.bypass_types=ARP|DHCPV4",
					"wireless.2.bcfilt.1.status=enabled", "wireless.2.bcfilt.1.mac=00:00:5e:00:53:09"}))
				local rules = io_.rules[#io_.rules]
				local by = {}
				for _, r in ipairs(rules) do by[r.ifname] = r end
				assert_true(by["phy1-ap0"].storm, "Conservative: storm limiter")
				assert_eq(by["phy1-ap0"].block, false, "and no blocker")
				assert_eq(by["phy0-ap0"].block, true, "Aggressive: the blocker")
				assert_eq(table.concat(by["phy0-ap0"].bypass, ","), "ARP,DHCPV4", "with its exemptions")
				assert_nil(by["phy0-ap0"].storm, "no limiter on Aggressive")
				local s = db.wireless.openuf_radio1_home
				assert_eq(s.openuf_mcast_suppressor, "conservative", "recorded for the restart")
				assert_eq(db.wireless.openuf_radio0_corp.openuf_bcfilt_bypass, "ARP DHCPV4", "bypass recorded")
				-- The startup rebuild reads the same back.
				local n = ucihelper.reapply_runtime_rules()
				assert_true(n >= 2, "two VAPs")
				local re = io_.rules[#io_.rules]
				local rb = {}
				for _, r in ipairs(re) do rb[r.ifname] = r end
				assert_true(rb["phy1-ap0"].storm, "Conservative rebuilt")
				assert_eq(table.concat(rb["phy0-ap0"].bypass, ","), "ARP,DHCPV4", "exemptions rebuilt")
			end)
		end
	},
	{
		name = "caps: bcfilter writes the accepts first, then the limiter, then the drop",
		fn = function()
			local exec, r = fake_nft()
			local saved = bcfilter._exec
			bcfilter._exec = exec
			bcfilter.reconcile({
				{ifname = "phy0-ap0", macs = {"00:00:5e:00:53:09"}, block = true,
					bypass = {"ARP", "NSNA", "DHCPV4", "DHCPV6"}},
				{ifname = "phy1-ap0", macs = {}, block = false, storm = true},
				{ifname = "phy2-ap0", macs = {}, block = true, storm = true, bypass = {"DHCPV4"}},
			})
			bcfilter._exec = saved
			local all = table.concat(r.cmds, "\n")
			local m = [[bcfilt oifname "phy0-ap0" meta pkttype { broadcast, multicast } ]]
			local i_arp = all:find(m .. "ether type arp accept", 1, true)
			local i_ns = all:find(m .. "ether type ip6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept", 1, true)
			local i_d4 = all:find(m .. "ether type ip udp dport { 67, 68 } accept", 1, true)
			local i_d6 = all:find(m .. "ether type ip6 udp dport { 546, 547 } accept", 1, true)
			local i_drop = all:find(m .. "ether saddr != @allow_phy0_ap0 drop", 1, true)
			assert_true(i_arp and i_ns and i_d4 and i_d6 and i_drop, "all four accepts and the drop")
			assert_true(i_arp < i_drop and i_d6 < i_drop, "accepts before the drop")
			assert_contains(all, [[oifname "phy1-ap0" meta pkttype { broadcast, multicast } limit rate over 200/second burst 400 packets drop]],
				"Conservative: the storm limiter")
			assert_true(not all:find("allow_phy1_ap0", 1, true), "Conservative alone: no allow set, no drop")
			local m2 = [[bcfilt oifname "phy2-ap0" meta pkttype { broadcast, multicast } ]]
			local j_acc = all:find(m2 .. "ether type ip udp dport { 67, 68 } accept", 1, true)
			local j_lim = all:find(m2 .. "limit rate over", 1, true)
			local j_drop = all:find(m2 .. "ether saddr != @allow_phy2_ap0 drop", 1, true)
			assert_true(j_acc and j_lim and j_drop and j_acc < j_lim and j_lim < j_drop,
				"both on: the DHCP accept ahead of the limiter, the limiter ahead of the drop")
			for line in all:gmatch("[^\n]+") do
				if line:find("add rule", 1, true) then
					assert_contains(line, "oifname", "every rule is scoped to a VAP, never a wired port")
				end
			end
		end
	},

	-- ─── WLAN Schedule ───────────────────────────────────────────────────────
	{
		name = "caps: schedule blocks parse with both key shapes, ends of day, and bad blocks named",
		fn = function()
			local s, bad = schedule.parse({schedule_enabled = "enabled",
				["schedule_mon.0"] = "0800-1200", ["schedule_mon.1"] = "1300-2359",
				schedule_tue = "0000-2359", ["schedule_wed.0"] = "2500-2600",
				["schedule_xyz.0"] = "0800-0900"})
			assert_eq(#s.days.mon, 2, "two Monday blocks")
			assert_eq(s.days.mon[2].e, 1440, "2359 = the end of the day")
			assert_eq(s.days.tue[1].s, 0, "single-block key shape")
			assert_nil(s.days.wed, "invalid block dropped")
			assert_eq(bad[1], "schedule_wed.0=2500-2600", "and named")
			assert_false(s.invert, "no invert key")
			assert_nil(schedule.parse({schedule_mon = "0800-1200"}), "no schedule_enabled: no schedule")
		end
	},
	{
		name = "caps: a plain schedule's blocks are ON times, an inverted one's OFF times",
		fn = function()
			local on = {invert = false, days = {mon = {{s = 480, e = 1020}}}}
			assert_true(schedule.is_on(on, 2, 600), "Monday 10:00 inside an ON block")
			assert_false(schedule.is_on(on, 2, 1020), "end exclusive")
			assert_false(schedule.is_on(on, 3, 600), "a day without blocks is off (controller: fully blacked out)")
			local inv = {invert = true, days = {mon = {{s = 0, e = 480}}}}
			assert_false(schedule.is_on(inv, 2, 60), "inside a blackout")
			assert_true(schedule.is_on(inv, 2, 600), "outside it")
			assert_true(schedule.is_on(inv, 4, 60), "a day without blackout is on")
			local enc = schedule.encode({invert = true, days = {mon = {{s = 0, e = 480}, {s = 1320, e = 1440}}}})
			assert_eq(enc, "inv|mon=0000-0800,2200-2359", "encoded for UCI")
			local back = schedule.decode(enc)
			assert_true(back.invert, "round trip: invert")
			assert_eq(back.days.mon[2].e, 1440, "round trip: end of day")
		end
	},
	{
		name = "caps: a scheduled WLAN starts in the schedule's state and carries it on its section",
		fn = function()
			with_uci(function(db)
				-- Monday noon (with_uci's clock).
				apply(cfg({"wireless.1.schedule_enabled=enabled", "wireless.1.schedule_invert=enabled",
					"wireless.1.schedule_mon.0=1100-1300",
					"wireless.2.schedule_enabled=enabled", "wireless.2.schedule_mon.0=0800-1700"}))
				local home, corp = db.wireless.openuf_radio1_home, db.wireless.openuf_radio0_corp
				assert_eq(home.openuf_schedule, "inv|mon=1100-1300", "stamped")
				assert_eq(home.disabled, "1", "in a blackout: down")
				assert_eq(home.openuf_sched_off, "1", "marked as the schedule's doing")
				assert_eq(corp.openuf_schedule, "on|mon=0800-1700", "plain schedule stamped")
				assert_nil(corp.disabled, "inside its ON block: up")
				-- The controller's own disable wins over the schedule.
				apply(cfg({"wireless.1.status=disabled", "wireless.1.schedule_enabled=enabled",
					"wireless.1.schedule_mon.0=0000-0100"}))
				assert_eq(db.wireless.openuf_radio1_home.disabled, "1", "controller-disabled")
				assert_nil(db.wireless.openuf_radio1_home.openuf_sched_off, "not the schedule's mark")
				-- Teardown: the schedule gone, the SSID back up.
				apply(cfg())
				assert_nil(db.wireless.openuf_radio1_home.openuf_schedule, "stamp gone")
				assert_nil(db.wireless.openuf_radio1_home.disabled, "up again")
			end)
		end
	},
	{
		name = "caps: the schedule tick flips only what changed, never a controller-disabled WLAN, one reload",
		fn = function()
			local mock, db = new_mock_uci()
			local c = mock.cursor()
			c:set("wireless", "openuf_radio0_a", "wifi-iface")
			c:set("wireless", "openuf_radio0_a", "ssid", "a")
			c:set("wireless", "openuf_radio0_a", "openuf_schedule", "on|mon=0800-1700")
			c:set("wireless", "openuf_radio0_b", "wifi-iface")
			c:set("wireless", "openuf_radio0_b", "ssid", "b")
			c:set("wireless", "openuf_radio0_b", "openuf_schedule", "on|mon=0800-1700")
			c:set("wireless", "openuf_radio0_b", "disabled", "1")   -- the controller's
			c:set("wireless", "user_c", "wifi-iface")
			c:set("wireless", "user_c", "openuf_schedule", "on|mon=0800-1700")
			local cmds = {}
			local s_uci, s_run = wlansched._uci, wlansched._run_cmd
			wlansched._uci = mock
			wlansched._run_cmd = function(cmd) cmds[#cmds + 1] = cmd end
			quiet(function()
				assert_eq(wlansched.tick({wday = 2, hour = 18, min = 0}), 1, "18:00 Monday: a goes down")
				assert_eq(db.wireless.openuf_radio0_a.disabled, "1", "a down")
				assert_eq(db.wireless.openuf_radio0_a.openuf_sched_off, "1", "a marked")
				assert_nil(db.wireless.user_c.disabled, "a user section is not openUF's")
				assert_eq(#cmds, 1, "one reload")
				assert_eq(wlansched.tick({wday = 2, hour = 18, min = 1}), 0, "steady: nothing")
				assert_eq(#cmds, 1, "no reload")
				assert_eq(wlansched.tick({wday = 3, hour = 9, min = 0}), 0, "Tuesday 9:00 has no block: stays down")
			end)
			wlansched._uci, wlansched._run_cmd = s_uci, s_run
			-- Back on the next Monday morning; b was never ours to bring up.
			wlansched._uci = mock
			wlansched._run_cmd = function(cmd) cmds[#cmds + 1] = cmd end
			quiet(function()
				-- Tuesday's tick above marked nothing new (a was already down).
				assert_eq(wlansched.tick({wday = 2, hour = 9, min = 0}), 1, "a back up")
			end)
			wlansched._uci, wlansched._run_cmd = s_uci, s_run
			assert_eq(db.wireless.openuf_radio0_a.disabled, "0", "a up")
			assert_nil(db.wireless.openuf_radio0_a.openuf_sched_off, "mark spent")
			assert_eq(db.wireless.openuf_radio0_b.disabled, "1", "b stays as the controller set it")
		end
	},
	{
		name = "caps: the inform loop runs the schedule at most once a minute",
		fn = function()
			local calls = 0
			local s_tick, s_time, s_next = inform._wlansched.tick, inform._time, inform._wlansched_next
			inform._wlansched.tick = function() calls = calls + 1; return 0 end
			local t = 1000
			inform._time = function() return t end
			inform._wlansched_next = 0
			inform._wlansched_tick()
			t = 1030; inform._wlansched_tick()
			t = 1061; inform._wlansched_tick()
			inform._wlansched.tick, inform._time, inform._wlansched_next = s_tick, s_time, s_next
			assert_eq(calls, 2, "0 s and 61 s, not 30 s")
		end
	},

	-- ─── Hotspot 2.0 ─────────────────────────────────────────────────────────
	{
		name = "caps: Hotspot 2.0 parses on an Enterprise WLAN and becomes hostapd lines",
		fn = function()
			local hs = {
				"aaa.2.hs20.status=enabled", "aaa.2.hs20.access_network_type=2",
				"aaa.2.hs20.internet=enabled", "aaa.2.hs20.asra=disabled", "aaa.2.hs20.esr=disabled",
				"aaa.2.hs20.uesa=disabled", "aaa.2.hs20.venue_group=2", "aaa.2.hs20.venue_type=8",
				"aaa.2.hs20.disable_dgaf=disabled", "aaa.2.hs20.deauth_req_timeout=60",
				"aaa.2.hs20.network_availability=13", "aaa.2.hs20.network_auth_type=2",
				"aaa.2.hs20.network_auth_url=https://example.com/tc", "aaa.2.hs20.anqp_domain_id=7",
				"aaa.2.hs20.hessid=00:00:5E:00:53:10",
				"aaa.2.hs20.venue_name.1.lang=eng", "aaa.2.hs20.venue_name.1.name=Example Cafe",
				"aaa.2.hs20.venue_name.1.url=https://example.com/info",
				"aaa.2.hs20.hs20_domain_name_list=example.com,example.net",
				"aaa.2.hs20.nai_realm.1.status=enabled", "aaa.2.hs20.nai_realm.1.encoding=0",
				"aaa.2.hs20.nai_realm.1.name=example.com", "aaa.2.hs20.nai_realm.1.eap_method=21",
				"aaa.2.hs20.nai_realm.1.eap_method.auth.1.id=2", "aaa.2.hs20.nai_realm.1.eap_method.auth.1.val=4",
				"aaa.2.hs20.nai_realm.1.eap_method.auth.2.id=5", "aaa.2.hs20.nai_realm.1.eap_method.auth.2.val=7",
				"aaa.2.hs20.nai_realm.2.status=disabled", "aaa.2.hs20.nai_realm.2.name=off.example",
				"aaa.2.hs20.1.roaming_consortium=5A03BA0000", "aaa.2.hs20.2.roaming_consortium=zz",
				"aaa.2.hs20.3gpp.1.mcc=310", "aaa.2.hs20.3gpp.1.mnc=026",
				"aaa.2.hs20.friendly_name.1.language=eng", "aaa.2.hs20.friendly_name.1.text=Example Op",
				"aaa.2.hs20.capab.1.protocol=6", "aaa.2.hs20.capab.1.port=443", "aaa.2.hs20.capab.1.status=open",
				"aaa.2.hs20.metrics.status=enabled", "aaa.2.hs20.metrics.info=1",
				"aaa.2.hs20.metrics.downlink_speed=8000", "aaa.2.hs20.metrics.uplink_speed=1000",
				"aaa.2.hs20.metrics.downlink_load=0", "aaa.2.hs20.metrics.uplink_load=0",
				"aaa.2.hs20.metrics.measurement=0",
				"aaa.2.hs20.icon.1.name=logo", "wireless.2.dgaf_disable=enabled",
			}
			local _, corp = parse(hs)
			assert_not_nil(corp.hs20, "parsed")
			local lines = table.concat(hotspot2.lines(corp.hs20, corp.dgaf_disable), "\n") .. "\n"
			for _, want in ipairs({
				"interworking=1", "hs20=1", "access_network_type=2", "internet=1", "asra=0",
				"venue_group=2", "venue_type=8", "hessid=00:00:5e:00:53:10", "disable_dgaf=1",
				"hs20_deauth_req_timeout=60", "anqp_domain_id=7", "ipaddr_type_availability=0d",
				"network_auth_type=02https://example.com/tc", "venue_name=eng:Example Cafe",
				"venue_url=1:https://example.com/info", "domain_name=example.com,example.net",
				"nai_realm=0,example.com,21[2:4][5:7]", "roaming_consortium=5a03ba0000",
				"anqp_3gpp_cell_net=310,026", "hs20_oper_friendly_name=eng:Example Op",
				"hs20_conn_capab=6:443:1", "hs20_wan_metrics=01:8000:1000:0:0:0"}) do
				assert_contains(lines, want .. "\n", want)
			end
			assert_true(not lines:find("off.example", 1, true), "a disabled realm is not advertised")
			assert_true(not lines:find("roaming_consortium=zz", 1, true), "a malformed OI is not")
			assert_true(corp.hs20.osu_dropped, "OSU/icons noted as not carried")
			local home = parse({"aaa.1.hs20.status=enabled"})
			assert_nil(home.hs20, "never on a PSK WLAN")
			with_uci(function(db)
				apply(cfg(hs))
				local raw = table.concat(db.wireless.openuf_radio0_corp.hostapd_bss_options, "\n")
				assert_contains(raw, "hs20=1", "raw lines on the Enterprise section")
				assert_contains(raw, "nai_realm=0,example.com,21[2:4][5:7]", "all of them")
			end)
		end
	},
	{
		name = "caps: an OSEN WLAN is skipped, not provisioned as keyless WPA2",
		fn = function()
			local vaps
			local log = quiet(function()
				local _; _, vaps = inform._parse_wifi_system_cfg(cfg({"aaa.2.wpa.key.1.mgmt=OSEN"}))
			end)
			assert_eq(#vaps, 1, "only the PSK WLAN")
			assert_contains(table.concat(log), "OSEN", "said why")
		end
	},

	-- ─── RADIUS Filter-Id ────────────────────────────────────────────────────
	{
		name = "caps: aaa.<n>.filter_id becomes radius_auth_req_attr 11 on the Enterprise WLAN only",
		fn = function()
			with_uci(function(db)
				apply(cfg({"aaa.2.filter_id=uid-wifi", "aaa.1.filter_id=wpa-eap"}))
				local corp = db.wireless.openuf_radio0_corp
				assert_eq(corp.radius_auth_req_attr[1], "11:s:uid-wifi", "Filter-Id as a string attribute")
				assert_eq(#corp.radius_auth_req_attr, 1, "one element: ap.uc joins a list onto one line")
				assert_nil(db.wireless.openuf_radio1_home.radius_auth_req_attr, "not on PSK")
				apply(cfg({"aaa.2.filter_id=bad value"}))
				assert_nil(db.wireless.openuf_radio0_corp.radius_auth_req_attr, "a malformed one is refused")
				apply(cfg())
				assert_nil(db.wireless.openuf_radio0_corp.radius_auth_req_attr, "gone with the key")
			end)
		end
	},

	-- ─── SNMP ────────────────────────────────────────────────────────────────
	{
		name = "caps: snmp parses versions, community and the v3 user; absence is off",
		fn = function()
			local i = snmp_p.parse("snmp.status=enabled\nsnmp.version=all\nsnmp.community=c0mm\n"
				.. "snmp.location=Lab 1\nsnmp.contact=ops@example.com\nsnmp.user.1.name=mon\n"
				.. "snmp.user.1.password=longenough\n")
			assert_true(i.enabled and i.v1v2c and i.v3, "both versions")
			assert_eq(i.community, "c0mm", "community")
			assert_eq(i.location, "Lab 1", "location")
			assert_eq(i.user, "mon", "user")
			assert_false(snmp_p.parse("system.timezone=UTC\n").enabled, "no block: off")
			assert_nil(snmp_p.parse(nil), "not a system_cfg: nothing")
			local v3 = snmp_p.parse("snmp.status=enabled\nsnmp.version=3\nsnmp.user.1.name=mon\n"
				.. "snmp.user.1.password=longenough\n")
			assert_false(v3.v1v2c, "3 alone: no v1/v2c")
			quiet(function()
				local short = snmp_p.parse("snmp.status=enabled\nsnmp.version=3\nsnmp.user.1.name=mon\n"
					.. "snmp.user.1.password=short\n")
				assert_true(short.enabled, "a password net-snmp would refuse: still on, so the "
					.. "device does not fall back to its stock config")
				assert_false(short.v3, "but no v3 user")
				local q = snmp_p.parse('snmp.status=enabled\nsnmp.version=1_2c\nsnmp.community=a"b\n')
				assert_false(q.v1v2c, "a quote never reaches snmpd.conf")
			end)
		end
	},
	{
		name = "caps: snmp takes over the snmpd config, restarts only on change, and restores on off",
		fn = function()
			local mock, db = new_mock_uci()
			local c = mock.cursor()
			c:set("snmpd", "public", "com2sec")
			c:set("snmpd", "public", "community", "public")
			local files = {["/etc/init.d/snmpd"] = "x", ["/lib/apk/db/installed"] = "P:snmpd-ssl\n",
				["/etc/config/snmpd"] = "config com2sec public\n"}
			local private = {}
			local cmds = {}
			local enabled_rc = 1   -- `snmpd enabled`: not enabled before
			local saved = {snmp._uci, snmp._read_file, snmp._write_file, snmp._exec}
			snmp._uci = mock
			snmp._cache = {}
			snmp._read_file = function(p) return files[p] end
			snmp._write_file = function(p, d, priv) files[p] = d; private[p] = priv; return true end
			snmp._exec = function(cmd)
				cmds[#cmds + 1] = cmd
				if cmd:find(" enabled", 1, true) then return enabled_rc end
				return 0
			end
			local st = {}
			local intent = {enabled = true, v1v2c = true, v3 = true, community = "c0mm",
				user = "mon", password = "longenough", location = "Lab"}
			local ok, err = pcall(function()
				assert_true(snmp.apply(intent, st), "applied")
				assert_eq(files["/etc/openuf/snmpd.orig"], "config com2sec public\n", "original kept")
				assert_true(private["/etc/openuf/snmpd.orig"], "the copy is written 0600")
				assert_false(st.snmp_was_enabled, "snmpd was not enabled before")
				assert_eq(db.snmpd.public.community, "c0mm", "the controller's community only")
				assert_eq(db.snmpd.openuf_v3.username, "mon", "v3 user")
				assert_eq(db.snmpd.openuf_v3.auth_type, "SHA", "SHA")
				assert_eq(db.snmpd.openuf_v3.privacy_type, "AES", "AES")
				assert_eq(db.snmpd.general.snmp_version, "v1/v2c/v3", "both versions for the init script")
				assert_eq(db.snmpd.system.sysLocation, "Lab", "location")
				assert_contains(cmds[#cmds], "/etc/init.d/snmpd restart", "restarted")
				assert_true(st.snmp_owned, "ledger")
				assert_true(st.snmp_applied:find("longenough", 1, true) == nil
					and st.snmp_applied:find("c0mm", 1, true) == nil, "no secret in state.json")
				assert_eq(#st.snmp_applied, 64, "a SHA-256")
				local n = #cmds
				assert_false(snmp.apply(intent, st), "same push: nothing")
				assert_eq(#cmds, n, "no restart")
				files["/etc/config/snmpd"] = "rewritten\n"
				assert_false(snmp.apply({enabled = false}, st, false), "a partial push decides nothing")
				assert_true(st.snmp_owned, "still owned")
				assert_true(quiet(function() snmp.apply({enabled = false}, st, true) end) ~= nil, "off")
				assert_eq(files["/etc/config/snmpd"], "config com2sec public\n", "original back")
				assert_contains(table.concat(cmds, ";", n + 1), "/etc/init.d/snmpd disable",
					"not enabled before: disabled again")
				assert_nil(st.snmp_owned, "ledger spent")
				assert_false(snmp.apply({enabled = false}, st, true), "off again: nothing to restore")
				-- A copy left by a takeover that crashed before the state save
				-- is the real original: never overwritten by openUF's config.
				files["/etc/openuf/snmpd.orig"] = "the real original\n"
				files["/etc/config/snmpd"] = "openUF's config\n"
				enabled_rc = 0
				snmp.apply(intent, st)
				assert_eq(files["/etc/openuf/snmpd.orig"], "the real original\n", "kept as it was")
				assert_true(st.snmp_was_enabled, "enabled before this time")
				n = #cmds
				quiet(function() snmp.apply({enabled = false}, st, true) end)
				assert_contains(table.concat(cmds, ";", n + 1), "restart", "enabled before: restarted")
				-- No ssl build: v3 is not configured, v1/v2c still is.
				files["/lib/apk/db/installed"] = "P:snmpd-nossl\n"
				snmp._cache = {}
				quiet(function() snmp.apply(intent, st) end)
				assert_nil(db.snmpd.openuf_v3, "no v3 without privacy")
				assert_eq(db.snmpd.general.snmp_version, "v1/v2c", "v1/v2c only")
				-- Not installed: nothing at all.
				local st2 = {}
				files["/etc/init.d/snmpd"] = nil
				snmp._cache = {}
				local log = quiet(function() assert_false(snmp.apply(intent, st2), "not installed") end)
				assert_nil(st2.snmp_owned, "untouched")
				assert_contains(table.concat(log), "apk add snmpd-ssl", "said how")
			end)
			snmp._uci, snmp._read_file, snmp._write_file, snmp._exec = saved[1], saved[2], saved[3], saved[4]
			snmp._cache = {}
			if not ok then error(err, 0) end
		end
	},
	{
		name = "caps: snmp on but unusable disables snmpd instead of restoring its stock config",
		fn = function()
			local mock, db = new_mock_uci()
			local files = {["/etc/init.d/snmpd"] = "x", ["/lib/apk/db/installed"] = "P:snmpd-nossl\n",
				["/etc/config/snmpd"] = "config com2sec public\n\toption community public\n"}
			local cmds = {}
			local saved = {snmp._uci, snmp._read_file, snmp._write_file, snmp._exec}
			snmp._uci = mock
			snmp._cache = {}
			snmp._read_file = function(p) return files[p] end
			snmp._write_file = function(p, d) files[p] = d; return true end
			snmp._exec = function(cmd) cmds[#cmds + 1] = cmd; return 0 end
			local st = {}
			local ok, err = pcall(function()
				-- v3 only, on the nossl build: nothing usable.
				local intent = {enabled = true, v1v2c = false, v3 = true, user = "mon",
					password = "longenough"}
				local log = quiet(function() assert_true(snmp.apply(intent, st), "acted") end)
				assert_eq(db.snmpd.general.enabled, "0", "a config that says off")
				assert_nil(db.snmpd.public, "no community left answering")
				local all = table.concat(cmds, ";")
				assert_contains(all, "/etc/init.d/snmpd stop", "stopped")
				assert_contains(all, "/etc/init.d/snmpd disable", "disabled")
				assert_true(all:find("restart", 1, true) == nil, "never restarted on the stock config")
				assert_contains(table.concat(log), "nothing in it is usable", "and says why")
				assert_true(st.snmp_owned, "owned, so SNMP off later restores the original")
				local n = #cmds
				assert_false(snmp.apply(intent, st), "the same push again: nothing")
				assert_eq(#cmds, n, "no further commands")
				-- A v3 password too short for the AES passphrase, on the ssl build.
				files["/lib/apk/db/installed"] = "P:snmpd-ssl\n"
				snmp._cache = {}
				local st3 = {}
				quiet(function() snmp.apply({enabled = true, v3 = true, user = "mon",
					password = "short"}, st3) end)
				assert_eq(st3.snmp_applied, "unusable", "a short passphrase is unusable too")
			end)
			snmp._uci, snmp._read_file, snmp._write_file, snmp._exec = saved[1], saved[2], saved[3], saved[4]
			snmp._cache = {}
			if not ok then error(err, 0) end
		end
	},
	{
		name = "caps: snmp's installed / v3_capable answers are cached, not read every heartbeat",
		fn = function()
			local reads = 0
			local saved = {snmp._read_file, snmp._time}
			local now = 1000
			snmp._cache = {}
			snmp._time = function() return now end
			snmp._read_file = function(p)
				reads = reads + 1
				if p == "/etc/init.d/snmpd" then return "x" end
				return "P:snmpd-ssl\n"
			end
			local first = snmp.v3_capable()
			local after_one = reads
			for _ = 1, 10 do snmp.v3_capable() end
			local cached_reads = reads
			now = now + snmp.CACHE_TTL
			snmp.v3_capable()
			snmp._read_file, snmp._time = saved[1], saved[2]
			snmp._cache = {}
			assert_true(first, "capable")
			assert_eq(cached_reads, after_one, "ten more heartbeats read nothing")
			assert_true(reads > cached_reads, "read again once the cache is old")
		end
	},

	-- ─── Roam topology: sta_roam and assoc_status ────────────────────────────
	{
		name = "caps: departure causes come from the Minimum RSSI kick and the Roaming Assistant",
		fn = function()
			local saved_state, saved_ce = roamassist._state, roamassist.connected_elsewhere
			roamassist._state = {
				["00:00:5e:00:53:02"] = {pending = {ifname = "phy1-ap0", at = 990}, acted_at = 990, seen_at = 990},
				["00:00:5e:00:53:03"] = {acted_at = 995, seen_at = 995},
				["00:00:5e:00:53:05"] = {acted_at = 500, seen_at = 500},
				["00:00:5e:00:53:06"] = {pending = {ifname = "phy1-ap0", at = 992}, acted_at = 992, seen_at = 992},
				["00:00:5e:00:53:07"] = {pending = {ifname = "phy1-ap0", at = 700}, acted_at = 700, seen_at = 700},
			}
			roamassist.connected_elsewhere = function(mac) return mac == "00:00:5e:00:53:02" end
			inform._lockap.kicks = {["00:00:5e:00:53:01"] = 998, ["00:00:5e:00:53:09"] = 100}
			local b1, r1 = inform._lockap.departure_cause("00:00:5e:00:53:01", 1000, staevents, roamassist)
			local b1b = inform._lockap.departure_cause("00:00:5e:00:53:01", 1001, staevents, roamassist)
			local b2, r2 = inform._lockap.departure_cause("00:00:5e:00:53:02", 1000, staevents, roamassist)
			local b2b, r2b = inform._lockap.departure_cause("00:00:5e:00:53:02", 1001, staevents, roamassist)
			local b3, r3 = inform._lockap.departure_cause("00:00:5e:00:53:03", 1000, staevents, roamassist)
			local b3b = inform._lockap.departure_cause("00:00:5e:00:53:03", 1001, staevents, roamassist)
			local b5 = inform._lockap.departure_cause("00:00:5e:00:53:05", 1000, staevents, roamassist)
			local b6, r6 = inform._lockap.departure_cause("00:00:5e:00:53:06", 1000, staevents, roamassist)
			local b7, r7 = inform._lockap.departure_cause("00:00:5e:00:53:07", 1000, staevents, roamassist)
			roamassist._state, roamassist.connected_elsewhere = saved_state, saved_ce
			assert_eq(b1, 16, "kicked")
			assert_false(r1, "a kick is no roam")
			assert_eq(b1b, 0, "a kick is reported once")
			assert_eq(b2, 8192, "BTM pending")
			assert_true(r2, "left on the BTM request and seen on another AP: roam")
			assert_eq(b2b, 0, "reported once")
			assert_false(r2b, "no second roam")
			assert_eq(b3, 8192, "forced disassociation")
			assert_false(r3, "forced: not a roam")
			assert_eq(b3b, 0, "reported once")
			assert_eq(b5, 0, "too long ago")
			assert_eq(b6, 8192, "left on the request, but on no AP usteer knows")
			assert_false(r6, "not claimed as a roam")
			assert_eq(b7, 0, "a request long past its grace is not this departure's cause")
			assert_false(r7, "no roam")
			assert_nil(inform._lockap.kicks["00:00:5e:00:53:09"], "old kicks forgotten")
			inform._lockap.reset()
		end
	},
	{
		name = "caps: the Minimum RSSI kick ledger stays bounded with nothing reading it",
		fn = function()
			local lockap = inform._lockap
			lockap.reset()
			for i = 1, lockap.KICKS_MAX + 10 do
				lockap.kicks[string.format("02:00:00:00:%02x:%02x", math.floor(i / 256), i % 256)] = 1000
			end
			lockap.note_kick("02:00:00:00:ff:ff", 1000)
			local n = 0
			for _ in pairs(lockap.kicks) do n = n + 1 end
			lockap.reset()
			assert_true(n <= lockap.KICKS_MAX, "capped (" .. n .. ")")
		end
	},
	{
		name = "caps: a Minimum RSSI kick is recorded for the departure event",
		fn = function()
			local src = io.open("src/openwrt/report.lua"):read("*a")
			local kick = src:find("pcall(ufuci.kick_station, k.ifname, k.mac)", 1, true)
			local rec = src:find("ctx._lockap.note_kick(k.mac, now)", 1, true)
			assert_true(kick and rec and rec > kick and rec - kick < 200, "recorded next to the kick")
		end
	},

	-- ─── wlan.lua housekeeping ───────────────────────────────────────────────
	{
		name = "caps: the parse_radius header no longer says DAS is unclaimed",
		fn = function()
			local src = io.open("src/unifi/wlan.lua"):read("*a")
			assert_true(not src:find("which openUF does not claim", 1, true), "stale comment gone")
			assert_true(not src:find("function M.parse_hs20", 1, true), "Hotspot 2.0 parsing lives in unifi/hotspot2.lua")
			assert_not_nil(hotspot2_p.parse, "hotspot2.parse exported")
		end
	},
	{
		name = "caps: snmp's private write leaves the file mode 0600",
		fn = function()
			local path = os.tmpname()
			assert_true(snmp._write_file(path, "community secret\n", true), "written")
			local p = io.popen("stat -c %a '" .. path .. "' 2>/dev/null || stat -f %Lp '" .. path .. "'")
			local mode = (p:read("*a") or ""):match("%d+")
			p:close()
			local f = io.open(path, "r")
			local data = f:read("*a")
			f:close()
			os.remove(path)
			assert_eq(mode, "600", "owner only")
			assert_eq(data, "community secret\n", "contents")
		end
	},
	{
		name = "caps: an enabled schedule with no valid block fails open, and says so",
		fn = function()
			local s, bad, empty = schedule.parse({schedule_enabled = "enabled",
				["schedule_mon.0"] = "2500-2600", schedule_tue = "junk"})
			assert_nil(s, "no schedule: the WLAN is not taken off the air")
			assert_eq(#bad, 2, "both blocks named")
			assert_eq(empty, "empty", "and the emptiness reported")
			local s2, _, e2 = schedule.parse({schedule_enabled = "enabled"})
			assert_nil(s2, "no block keys at all: no schedule")
			assert_eq(e2, "empty", "reported")
			with_uci(function(db)
				apply(cfg({"wireless.1.schedule_enabled=enabled", "wireless.1.schedule_mon.0=9999-0000"}))
				local home = db.wireless.openuf_radio1_home
				assert_nil(home.openuf_schedule, "nothing stamped")
				assert_nil(home.disabled, "up")
			end)
			local log = quiet(function() inform._parse_wifi_system_cfg(cfg({
				"wireless.1.schedule_enabled=enabled", "wireless.1.schedule_mon.0=9999-0000"})) end)
			assert_contains(table.concat(log), "no valid block", "logged")
		end
	},
	{
		name = "caps: no schedule is acted on before the clock is set",
		fn = function()
			local mock, db = new_mock_uci()
			local c = mock.cursor()
			c:set("wireless", "openuf_radio0_a", "wifi-iface")
			c:set("wireless", "openuf_radio0_a", "ssid", "a")
			c:set("wireless", "openuf_radio0_a", "openuf_schedule", "on|mon=0800-1700")
			local cmds = {}
			local saved = {wlansched._uci, wlansched._run_cmd, wlansched._now}
			wlansched._uci = mock
			wlansched._run_cmd = function(cmd) cmds[#cmds + 1] = cmd end
			wlansched._now = function() return 86400 * 3 end   -- 1970: no NTP yet
			local n
			local log = quiet(function() n = wlansched.tick({wday = 2, hour = 18, min = 0}) end)
			wlansched._uci, wlansched._run_cmd, wlansched._now = saved[1], saved[2], saved[3]
			assert_eq(n, 0, "nothing changed")
			assert_nil(db.wireless.openuf_radio0_a.disabled, "the WLAN stays up")
			assert_eq(#cmds, 0, "no reload")
			assert_contains(table.concat(log), "clock is not set", "logged")
			-- The push path neither: stamped, but not taken down.
			with_uci(function(udb)
				local s_now = ucihelper._now
				ucihelper._now = function() return 1000 end
				apply(cfg({"wireless.1.schedule_enabled=enabled", "wireless.1.schedule_invert=enabled",
					"wireless.1.schedule_mon.0=1100-1300"}))
				ucihelper._now = s_now
				local home = udb.wireless.openuf_radio1_home
				assert_eq(home.openuf_schedule, "inv|mon=1100-1300", "stamped")
				assert_nil(home.disabled, "but left up until the clock is set")
			end)
		end
	},
	{
		name = "caps: a controller-disabled WLAN drops the schedule's mark, so the schedule never re-enables it",
		fn = function()
			with_uci(function(db)
				-- Monday noon, inside a blackout: the schedule takes it down.
				apply(cfg({"wireless.1.schedule_enabled=enabled", "wireless.1.schedule_invert=enabled",
					"wireless.1.schedule_mon.0=1100-1300"}))
				assert_eq(db.wireless.openuf_radio1_home.openuf_sched_off, "1", "the schedule's doing")
				-- The controller disables the WLAN; the push rebuilds the section.
				apply(cfg({"wireless.1.status=disabled", "wireless.1.schedule_enabled=enabled",
					"wireless.1.schedule_invert=enabled", "wireless.1.schedule_mon.0=1100-1300"}))
				assert_nil(db.wireless.openuf_radio1_home.openuf_sched_off, "mark dropped")
			end)
			-- Then the blackout ends: the tick must leave it down.
			local mock = {cursor = function()
				return {
					foreach = function(_, _, _, fn)
						fn({[".name"] = "openuf_radio1_home", ssid = "home", disabled = "1",
							openuf_schedule = "inv|mon=1100-1300"})
					end,
					set = function() error("must not touch a controller-disabled WLAN") end,
					delete = function() end, commit = function() end,
				}
			end}
			local saved = {wlansched._uci, wlansched._run_cmd}
			wlansched._uci = mock
			wlansched._run_cmd = function() end
			local n = wlansched.tick({wday = 2, hour = 14, min = 0})
			wlansched._uci, wlansched._run_cmd = saved[1], saved[2]
			assert_eq(n, 0, "outside the blackout: still not brought up")
		end
	},
	{
		name = "caps: after the schedule brings a WLAN up, its runtime rules wait for the netdev",
		fn = function()
			local saved = {tick = inform._wlansched.tick, time = inform._time,
				next = inform._wlansched_next, u = inform._ucihelper}
			local t = 1000
			inform._time = function() return t end
			inform._wlansched_next = 0
			inform._wlansched_pending = nil
			inform._wlansched.tick = function() return 1, {"openuf_radio0_a"} end
			local ifname, reapplied = nil, 0
			inform._ucihelper = {
				ifname_for_section = function(n) return n == "openuf_radio0_a" and ifname or nil end,
				reapply_runtime_rules = function() reapplied = reapplied + 1 end,
			}
			inform._wlansched_tick()
			local at_once = reapplied
			inform._wlansched.tick = function() return 0, {} end
			t = 1010; inform._wlansched_tick()
			local before_netdev = reapplied
			ifname = "phy0-ap0"
			t = 1020; inform._wlansched_tick()
			local after_netdev = reapplied
			t = 1030; inform._wlansched_tick()
			local again = reapplied
			-- A netdev that never appears: rebuilt anyway once the wait is over.
			inform._wlansched.tick = function() return 1, {"openuf_radio0_b"} end
			inform._wlansched_next = 0
			t = 2000; inform._wlansched_tick()
			inform._wlansched.tick = function() return 0, {} end
			t = 2000 + inform.WLANSCHED_REAPPLY_WAIT; inform._wlansched_tick()
			local timed_out = reapplied
			inform._wlansched.tick, inform._time = saved.tick, saved.time
			inform._wlansched_next, inform._ucihelper = saved.next, saved.u
			inform._wlansched_pending = nil
			assert_eq(at_once, 0, "not straight after the reload")
			assert_eq(before_netdev, 0, "nor while the netdev is missing")
			assert_eq(after_netdev, 1, "once it exists, on the next heartbeat")
			assert_eq(again, 1, "once")
			assert_eq(timed_out, 2, "a netdev that never comes: rebuilt after the wait")
		end
	},
	{
		name = "caps: a MAC-based VLAN list-only change renames the file, so wifi reload reaches hostapd",
		fn = function()
			with_uci(function(db, io_)
				apply(cfg(MACVLAN))
				local before = table.concat(db.wireless.openuf_radio1_home.hostapd_bss_options, "|")
				local old = before:match("accept_mac_file=(%S+)")
				local changed = {}
				for _, l in ipairs(MACVLAN) do
					changed[#changed + 1] = (l:gsub("vlanid=30", "vlanid=40"))
				end
				apply(cfg(changed))
				local after = table.concat(db.wireless.openuf_radio1_home.hostapd_bss_options, "|")
				local new = after:match("accept_mac_file=(%S+)")
				assert_true(old ~= new, "a new file name, so the section changed and the BSS is reloaded")
				assert_contains(io_.files[new], "00:00:5e:00:53:01 40", "the new list")
				assert_nil(io_.files[old], "the old one goes after the reload")
			end)
		end
	},
	{
		name = "caps: stale MAC-based VLAN lists stay until wifi reload succeeds",
		fn = function()
			with_uci(function(_, io_)
				ucihelper._run_cmd = function(cmd) if cmd == "wifi reload" then return 1 end return true end
				apply(cfg(MACVLAN))
				assert_eq(#io_.removed, 0, "reload failed: nothing removed")
				assert_contains(table.concat(io_.log), "old MAC-based VLAN lists kept", "and said so")
			end)
		end
	},
	{
		name = "caps: one vid -> network lookup for keys, RADIUS and MAC VLANs; no br-trunk guess",
		fn = function()
			local plan = {bridge = {name = "br-lan"}, mgmt = {iface = "mgmt", device = "br-lan.50"},
				vlan_ifaces = {[20] = "openuf_v20"}, net_for_bridge = {["br-trunk"] = "trunk"}}
			assert_eq(ucihelper.plan_network_for_vid(plan, 20), "openuf_v20", "the VLAN's interface")
			assert_eq(ucihelper.plan_network_for_vid(plan, 50), "mgmt", "management's VLAN")
			assert_nil(ucihelper.plan_network_for_vid(plan, 30), "none")
			assert_eq(ucihelper.plan_mgmt_vid(plan), 50, "management VLAN")
			assert_nil(ucihelper.plan_mgmt_vid({bridge = {name = "br-lan"}, mgmt = {device = "br-lan"}}),
				"untagged management")
			with_uci(function(db)
				local radio_table, vap_table
				local lines = {"aaa.1.br.devname=br0.20"}   -- a tagged VAP: VLAN 1 is not its own
				for _, l in ipairs(MACVLAN) do lines[#lines + 1] = l end
				quiet(function() radio_table, vap_table = inform._parse_wifi_system_cfg(cfg(lines)) end)
				quiet(function()
					ucihelper.apply_config({radio_table = radio_table, vap_table = vap_table}, {net = {}},
						{netmodel = plan})
				end)
				assert_nil(db.wireless.openuf_radio1_home_vlan1,
					"no br0 in the plan: the VLAN-1 entry is left out, not guessed onto br-trunk")
			end)
		end
	},
	{
		name = "caps: the Hotspot 2.0 QoS map takes only DSCP 0-63 (or 255,255) and UP 0-7, whole numbers",
		fn = function()
			local function qos(over)
				local a = {["hs20.status"] = "enabled", ["hs20.qos.status"] = "enabled",
					["hs20.qos.exception.1.dcsp"] = "53", ["hs20.qos.exception.1.up"] = "2"}
				local lows = {"8", "0", "255", "16", "24", "32", "40", "48"}
				local highs = {"15", "7", "255", "31", "39", "47", "55", "63"}
				for i = 1, 8 do
					a["hs20.qos.map." .. i .. ".low"] = lows[i]
					a["hs20.qos.map." .. i .. ".high"] = highs[i]
				end
				for k, v in pairs(over or {}) do a[k] = v end
				local h
				quiet(function() h = hotspot2_p.parse(a, "x") end)
				return h and h.qos_map_set
			end
			assert_eq(qos(), "53,2,8,15,0,7,255,255,16,31,24,39,32,47,40,55,48,63", "a valid map")
			assert_nil(qos({["hs20.qos.exception.1.dcsp"] = "64"}), "exception DSCP 64")
			assert_nil(qos({["hs20.qos.exception.1.up"] = "8"}), "exception UP 8")
			assert_nil(qos({["hs20.qos.exception.1.dcsp"] = "5.5"}), "not a whole number")
			assert_nil(qos({["hs20.qos.map.4.high"] = "70"}), "range past 63")
			assert_nil(qos({["hs20.qos.map.4.low"] = "40", ["hs20.qos.map.4.high"] = "30"}), "low above high")
			assert_nil(qos({["hs20.qos.map.3.high"] = "63"}), "255 only as 255,255")
			assert_nil(qos({["hs20.qos.map.1.low"] = "-1"}), "negative")
		end
	},
}
