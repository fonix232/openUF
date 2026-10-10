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
				local path = "/etc/openuf/macvlan-openuf_radio1_home.list"
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
				local path = "/etc/openuf/macvlan-openuf_radio1_home.list"
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
		name = "caps: bcfilter writes the limiter first, then accepts, then the drop",
		fn = function()
			local cmds = {}
			local saved = bcfilter._exec
			bcfilter._exec = function(c) cmds[#cmds + 1] = c; return 0 end
			bcfilter.reconcile({
				{ifname = "phy0-ap0", macs = {"00:00:5e:00:53:09"}, block = true,
					bypass = {"ARP", "NSNA", "DHCPV4", "DHCPV6"}},
				{ifname = "phy1-ap0", macs = {}, block = false, storm = true},
			})
			bcfilter._exec = saved
			local all = table.concat(cmds, "\n")
			local m = [[bcfilt oifname '"phy0-ap0"' meta pkttype '{ broadcast, multicast }' ]]
			local i_arp = all:find(m .. "ether type arp accept", 1, true)
			local i_ns = all:find(m .. "icmpv6 type '{ nd-neighbor-solicit, nd-neighbor-advert }' accept", 1, true)
			local i_d4 = all:find(m .. "udp dport '{ 67, 68 }' accept", 1, true)
			local i_d6 = all:find(m .. "udp dport '{ 546, 547 }' accept", 1, true)
			local i_drop = all:find(m .. "ether saddr != @allow_phy0_ap0 drop", 1, true)
			assert_true(i_arp and i_ns and i_d4 and i_d6 and i_drop, "all four accepts and the drop")
			assert_true(i_arp < i_drop and i_d6 < i_drop, "accepts before the drop")
			assert_contains(all, [[oifname '"phy1-ap0"' meta pkttype '{ broadcast, multicast }' limit rate over 200/second burst 400 packets drop]],
				"Conservative: the storm limiter")
			assert_true(not all:find("allow_phy1_ap0", 1, true), "Conservative alone: no allow set, no drop")
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
				assert_false(short.enabled, "a password net-snmp would refuse: nothing to enable")
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
			local cmds = {}
			local saved = {snmp._uci, snmp._read_file, snmp._write_file, snmp._exec}
			snmp._uci = mock
			snmp._read_file = function(p) return files[p] end
			snmp._write_file = function(p, d) files[p] = d; return true end
			snmp._exec = function(cmd) cmds[#cmds + 1] = cmd; return 0 end
			local st = {}
			local intent = {enabled = true, v1v2c = true, v3 = true, community = "c0mm",
				user = "mon", password = "longenough", location = "Lab"}
			local ok, err = pcall(function()
				assert_true(snmp.apply(intent, st), "applied")
				assert_eq(files["/etc/openuf/snmpd.orig"], "config com2sec public\n", "original kept")
				assert_eq(db.snmpd.public.community, "c0mm", "the controller's community only")
				assert_eq(db.snmpd.openuf_v3.username, "mon", "v3 user")
				assert_eq(db.snmpd.openuf_v3.auth_type, "SHA", "SHA")
				assert_eq(db.snmpd.openuf_v3.privacy_type, "AES", "AES")
				assert_eq(db.snmpd.general.snmp_version, "v1/v2c/v3", "both versions for the init script")
				assert_eq(db.snmpd.system.sysLocation, "Lab", "location")
				assert_contains(cmds[#cmds], "/etc/init.d/snmpd restart", "restarted")
				assert_true(st.snmp_owned, "ledger")
				local n = #cmds
				assert_false(snmp.apply(intent, st), "same push: nothing")
				assert_eq(#cmds, n, "no restart")
				files["/etc/config/snmpd"] = "rewritten\n"
				assert_true(quiet(function() snmp.apply({enabled = false}, st) end) ~= nil, "off")
				assert_eq(files["/etc/config/snmpd"], "config com2sec public\n", "original back")
				assert_nil(st.snmp_owned, "ledger spent")
				assert_false(snmp.apply({enabled = false}, st), "off again: nothing to restore")
				-- No ssl build: v3 is not configured, v1/v2c still is.
				files["/lib/apk/db/installed"] = "P:snmpd-nossl\n"
				quiet(function() snmp.apply(intent, st) end)
				assert_nil(db.snmpd.openuf_v3, "no v3 without privacy")
				assert_eq(db.snmpd.general.snmp_version, "v1/v2c", "v1/v2c only")
				-- Not installed: nothing at all.
				local st2 = {}
				files["/etc/init.d/snmpd"] = nil
				local log = quiet(function() assert_false(snmp.apply(intent, st2), "not installed") end)
				assert_nil(st2.snmp_owned, "untouched")
				assert_contains(table.concat(log), "apk add snmpd-ssl", "said how")
			end)
			snmp._uci, snmp._read_file, snmp._write_file, snmp._exec = saved[1], saved[2], saved[3], saved[4]
			if not ok then error(err, 0) end
		end
	},

	-- ─── Roam topology: sta_roam and assoc_status ────────────────────────────
	{
		name = "caps: departures carry assoc_status; a BSS Transition departure is also sta_roam",
		fn = function()
			staevents._reset()
			local prev = {["00:00:5e:00:53:01"] = {vap = "ath0", signal = -80, uptime = 100, idle = 0},
				["00:00:5e:00:53:02"] = {vap = "ath0", signal = -70, uptime = 100, idle = 0},
				["00:00:5e:00:53:03"] = {vap = "ath0", signal = -60, uptime = 100, idle = 0}}
			staevents.observe(prev, 1000, 500)
			local cause = function(mac)
				if mac == "00:00:5e:00:53:01" then return 16, false end
				if mac == "00:00:5e:00:53:02" then return 8192, true end
				return 0, false
			end
			staevents.observe({}, 1010, 510, nil, cause)
			local evs = {}
			while staevents.pending() > 0 do evs[#evs + 1] = staevents.pop() end
			local by = {}
			for _, e in ipairs(evs) do by[e.mac .. "/" .. e.event_type] = e end
			assert_eq(by["00:00:5e:00:53:01/sta_leave"].assoc_status, 16, "Minimum RSSI kick")
			assert_nil(by["00:00:5e:00:53:01/sta_roam"], "a kick is not a roam")
			assert_eq(by["00:00:5e:00:53:02/sta_leave"].assoc_status, 8192, "Roaming Assistant")
			local r = by["00:00:5e:00:53:02/sta_roam"]
			assert_not_nil(r, "sta_roam for the BTM departure")
			assert_eq(r.assoc_status, 8192, "with the same bits")
			assert_eq(r.vap, "ath0", "and the VAP the controller resolves")
			assert_eq(r.avg_rssi, -70, "avg_rssi")
			assert_true(r.event_id ~= by["00:00:5e:00:53:02/sta_leave"].event_id, "its own event id")
			assert_eq(by["00:00:5e:00:53:03/sta_leave"].assoc_status, 0, "plain departure: 0")
			local order = {}
			for _, e in ipairs(evs) do order[#order + 1] = e.mac .. "/" .. e.event_type end
			local s = table.concat(order, " ")
			assert_true(s:find("00:00:5e:00:53:02/sta_roam 00:00:5e:00:53:02/sta_leave", 1, true) ~= nil,
				"sta_roam first, then the sta_leave the station manager needs")
			-- Joins still carry auth_rssi: the detector's only "joined" half once 0x2000 is claimed.
			staevents.observe({["00:00:5e:00:53:04"] = {vap = "ath0", signal = -55, uptime = 2}}, 1020, 520)
			local a = staevents.pop()
			assert_eq(a.event_type, "association", "association")
			assert_eq(a.auth_rssi, -55, "with auth_rssi")
			while staevents.pending() > 0 do staevents.pop() end
			-- No cause source at all: the departure still says 0, as firmware does.
			staevents.observe({}, 1030, 530)
			local l = staevents.pop()
			assert_eq(l.event_type, "sta_leave", "departure")
			assert_eq(l.assoc_status, 0, "assoc_status 0 without a cause")
			staevents._reset()
		end
	},
	{
		name = "caps: departure causes come from the Minimum RSSI kick and the Roaming Assistant",
		fn = function()
			local saved_state = roamassist._state
			roamassist._state = {
				["00:00:5e:00:53:02"] = {pending = {ifname = "phy1-ap0", at = 990}, acted_at = 990},
				["00:00:5e:00:53:03"] = {acted_at = 995},
				["00:00:5e:00:53:05"] = {acted_at = 500},
			}
			inform._minrssi_kicks = {["00:00:5e:00:53:01"] = 998, ["00:00:5e:00:53:09"] = 100}
			local b1, r1 = inform._departure_cause("00:00:5e:00:53:01", 1000)
			local b2, r2 = inform._departure_cause("00:00:5e:00:53:02", 1000)
			local b3, r3 = inform._departure_cause("00:00:5e:00:53:03", 1000)
			local b5 = inform._departure_cause("00:00:5e:00:53:05", 1000)
			roamassist._state = saved_state
			assert_eq(b1, 16, "kicked")
			assert_false(r1, "a kick is no roam")
			assert_eq(b2, 8192, "BTM pending")
			assert_true(r2, "left on the BTM request: roam")
			assert_eq(b3, 8192, "forced disassociation")
			assert_false(r3, "forced: not a roam")
			assert_eq(b5, 0, "too long ago")
			assert_nil(inform._minrssi_kicks["00:00:5e:00:53:09"], "old kicks forgotten")
			inform._minrssi_kicks = nil
		end
	},
	{
		name = "caps: a Minimum RSSI kick is recorded for the departure event",
		fn = function()
			local src = io.open("src/openwrt/report.lua"):read("*a")
			local kick = src:find("pcall(ufuci.kick_station, ifname, sta.mac)", 1, true)
			local rec = src:find("ctx._minrssi_kicks[sta.mac] = now", 1, true)
			assert_true(kick and rec and rec > kick and rec - kick < 200, "recorded next to the kick")
		end
	},

	-- ─── wlan.lua housekeeping ───────────────────────────────────────────────
	{
		name = "caps: the parse_radius header no longer says DAS is unclaimed",
		fn = function()
			local src = io.open("src/unifi/wlan.lua"):read("*a")
			assert_true(not src:find("which openUF does not claim", 1, true), "stale comment gone")
			assert_not_nil(wlan.parse_hs20, "parse_hs20 exported")
		end
	},
}
