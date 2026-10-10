-- Tests for the wireless uplink (mesh): src/unifi/mesh.lua (the controller's
-- side), the backhaul guard in src/unifi/wlan.lua, src/openwrt/backhaul.lua
-- (the uplink policy and link naming), ucihelper's backhaul sections, and
-- their wiring through provision.lua and report.lua.
-- Ported from yesrab/openUF's tests/test_backhaul.lua (2026-10-03). No device
-- access: every seam is replaced.

OPENUF_TEST_MODE = true

local cjson    = require("cjson")
local mesh     = require("unifi.mesh")
local wlan     = require("unifi.wlan")
local backhaul = dofile("src/openwrt/backhaul.lua")

local PSK    = "0123456789abcdef0123456789abcdef"
local ESSID  = "vwire-0123456789abcdef"
local PARENT = "00:00:5e:00:53:01"   -- the parent AP's identity MAC
local PARENT_BSS = "00:00:5e:00:53:11" -- its downlink BSS
local CHILD  = "00:00:5e:00:53:02"

-- The push a meshing child receives (yesrab/openUF's capture on 10.6.106,
-- addresses and secrets replaced): one user WLAN on each band, plus the
-- downlink and uplink on the 5 GHz radio.
local MESH_PUSH = table.concat({
	"radio.1.phyname=radio0", "radio.1.channel=6",
	"radio.2.phyname=radio1", "radio.2.channel=auto",
	"aaa.1.ssid=home", "aaa.1.wpa=2", "aaa.1.wpa.key.1.mgmt=WPA-PSK", "aaa.1.wpa.psk=hunter2hunter2",
	"aaa.1.id=000000000000000000000001", "aaa.1.devname=ath0",
	"wireless.1.ssid=home", "wireless.1.parent=radio0", "wireless.1.mode=master",
	"wireless.1.usage=user", "wireless.1.devname=ath0",
	"aaa.4.devname=vwire3", "aaa.4.ssid=" .. ESSID, "aaa.4.wpa=2",
	"aaa.4.wpa.key.1.mgmt=WPA-PSK", "aaa.4.wpa.psk=" .. PSK, "aaa.4.hide_ssid=true",
	"aaa.4.status=enabled",
	"wireless.4.devname=vwire3", "wireless.4.mode=master", "wireless.4.usage=downlink",
	"wireless.4.wds=enabled", "wireless.4.vwire=enabled", "wireless.4.vport=disabled",
	"wireless.4.ssid=" .. ESSID, "wireless.4.hide_ssid=true", "wireless.4.parent=radio1",
	"aaa.5.devname=ath4", "aaa.5.ssid=vport-00005e005302", "aaa.5.status=disabled",
	"wireless.5.devname=ath4", "wireless.5.mode=managed", "wireless.5.usage=uplink",
	"wireless.5.wds=enabled", "wireless.5.vport=enabled", "wireless.5.vwire=disabled",
	"wireless.5.ssid=vport-00005e005302", "wireless.5.hide_ssid=true", "wireless.5.parent=radio1",
	"mesh.status=enabled", "mesh.version=3", "mesh.essid=" .. ESSID, "mesh.psk=" .. PSK,
	"mesh.serial1=" .. PARENT:upper(),
	"connectivity.status=enabled", "connectivity.uplink_wds=ath4",
	"connectivity.uplink_eth=eth0", "connectivity.uplink_bridge=br0",
}, "\n")

local function quietly(fn)
	local real = io.stderr
	io.stderr = {write = function() end}
	local ok, a, b, c = pcall(fn)
	io.stderr = real
	if not ok then error(a, 0) end
	return a, b, c
end

-- ─── An in-memory UCI, rejecting what libuci silently discards ───────────────

local function new_uci()
	local db, order = {}, {}
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
		if b == nil then db[config][section][".type"] = a
		elseif type(b) == "table" then
			local l = {}
			for i, v in ipairs(b) do l[i] = tostring(v) end
			db[config][section][a] = l
		else db[config][section][a] = b end
	end
	function cursor:foreach(config, stype, fn)
		for _, n in ipairs(order[config] or {}) do
			local s = db[config][n]
			if s and s[".type"] == stype then fn(s) end
		end
	end
	function cursor:delete(config, section, option)
		if option ~= nil then
			if db[config] and db[config][section] then db[config][section][option] = nil end
			return
		end
		if db[config] then db[config][section] = nil end
		for i, n in ipairs(order[config] or {}) do
			if n == section then table.remove(order[config], i); break end
		end
	end
	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		if option == nil then return s and s[".type"] end
		local v = s and s[option]
		if v == nil then return nil, "Entry not found" end
		return v
	end
	local commits = {}
	function cursor:commit(config) commits[config] = (commits[config] or 0) + 1 end
	return {cursor = function() return cursor end}, db, commits
end

-- A fresh ucihelper on a fresh in-memory UCI with two radios.
local function new_ucihelper()
	local uf = dofile("src/openwrt/ucihelper.lua")
	local uci, db, commits = new_uci()
	local cmds = {}
	uf._uci = uci
	uf._popen = function() return "" end
	uf._read_file = function() return nil end
	uf._run_cmd = function(c) cmds[#cmds + 1] = c; return true end
	uf._bcfilter = {reconcile = function() end}
	uf._shaper = {reconcile = function() end}
	local c = uci.cursor()
	c:set("wireless", "radio0", "wifi-device")
	c:set("wireless", "radio0", "band", "2g")
	c:set("wireless", "radio1", "wifi-device")
	c:set("wireless", "radio1", "band", "5g")
	return uf, db, cmds, commits
end

-- netifd's `ubus call network.wireless status` for radio1 with the given
-- interfaces ({section, ifname, mode, wds}).
local function wireless_status(ifaces)
	local list = {}
	for _, i in ipairs(ifaces) do
		list[#list + 1] = {section = i.section, ifname = i.ifname,
			config = {mode = i.mode or "ap", ssid = i.ssid, wds = i.wds}}
	end
	return cjson.encode({radio1 = {up = true, interfaces = list}})
end

-- ─── backhaul.lua's seams ────────────────────────────────────────────────────

local function fake_ufuci(sections, ifname)
	local f = {calls = {}}
	function f.backhaul_uplink_sections() return sections end
	function f.ifname_for_section() return ifname end
	function f.backhaul_set_uplink_enabled(enabled)
		f.calls[#f.calls + 1] = enabled
		for _, s in ipairs(sections) do s.disabled = not enabled end
		return true
	end
	return f
end

local function fake_sysinfo(port)
	return {
		bridge_of = function() return "br-lan" end,
		uplink_bridge_port = function() return port end,
	}
end

-- carrier_by_port: port -> true/false (nil: no sysfs entry).
local function with_seams(carrier_by_port, popen_out, fn)
	local orig_read, orig_popen, orig_log = backhaul._read_file, backhaul._popen, backhaul._log
	backhaul._read_file = function(path)
		local port, what = path:match("^/sys/class/net/([^/]+)/(%w+)$")
		if port and (what == "carrier" or what == "operstate") then
			local c = carrier_by_port[port]
			if c == nil then return nil end
			if what == "operstate" then return c and "up\n" or "lowerlayerdown\n" end
			return c and "1\n" or "0\n"
		end
		return nil
	end
	backhaul._popen = function() return popen_out or "" end
	backhaul._log = function() end
	backhaul._down_ticks = 0
	local ok, err = pcall(fn)
	backhaul._read_file, backhaul._popen, backhaul._log = orig_read, orig_popen, orig_log
	if not ok then error(err, 0) end
end

return {
	-- ─── unifi/mesh.lua ──────────────────────────────────────────────────────
	{
		name = "mesh: parse() reads the mesh block, nil without one, status false unless enabled",
		fn = function()
			local m = mesh.parse(MESH_PUSH)
			assert_true(m.status, "enabled")
			assert_eq(m.essid, ESSID, "essid")
			assert_eq(m.psk, PSK, "psk")
			assert_eq(m.serial1, PARENT:upper(), "serial1 verbatim")
			assert_nil(mesh.parse("radio.1.phyname=radio0\nwireless.1.ssid=x"), "no mesh block")
			assert_false(mesh.parse("mesh.status=disabled").status, "disabled")
			assert_false(mesh.parse("mesh.version=3").status, "no status line: off")
			assert_eq(mesh.parent(m), PARENT, "the push's parent, lower-cased")
			assert_eq(mesh.parent(mesh.parse("mesh.status=enabled")), "", "no parent named")
			assert_eq(mesh.parent({serial1 = "not-a-mac"}), "", "garbage is no parent")
		end
	},
	{
		name = "mesh: role() tells the two backhaul VAPs from a WLAN",
		fn = function()
			assert_nil(mesh.role({mode = "master", usage = "user"}), "a WLAN")
			assert_nil(mesh.role({}), "a WLAN of a push with neither key")
			assert_eq(mesh.role({mode = "master", usage = "downlink"}), "downlink", "downlink")
			assert_eq(mesh.role({mode = "managed", usage = "uplink"}), "uplink", "uplink")
			assert_eq(mesh.role({mode = "managed"}), "uplink", "a station without usage")
		end
	},
	{
		name = "mesh: wlan.parse() hands the backhaul VAPs over and provisions neither as an access point",
		fn = function()
			local radios, vaps, entries = quietly(function() return wlan.parse(MESH_PUSH) end)
			assert_eq(#radios, 2, "radios")
			assert_eq(#vaps, 1, "only the user WLAN is a VAP")
			assert_eq(vaps[1].ssid, "home", "the user WLAN")
			assert_eq(#entries, 2, "two backhaul entries")
			local dl, ul = entries[1], entries[2]
			assert_eq(dl.role, "downlink", "wireless.4 is the downlink")
			assert_eq(dl.radio, "radio1", "on the 5 GHz radio")
			assert_eq(dl.psk, PSK, "carrying the site PSK")
			assert_eq(dl.devname, "vwire3", "devname")
			assert_eq(ul.role, "uplink", "wireless.5 is the uplink")
			assert_eq(ul.ssid, "vport-00005e005302", "its own vport name")
			assert_eq(ul.devname, "ath4", "devname")
			assert_nil(ul.psk, "the uplink's aaa block has no key")
		end
	},
	{
		name = "mesh: plan() turns the entries into a downlink AP and a station that is up only on the wireless uplink",
		fn = function()
			local _, _, entries = quietly(function() return wlan.parse(MESH_PUSH) end)
			local m = mesh.parse(MESH_PUSH)
			local plan = mesh.plan(m, entries, false)
			assert_eq(plan.downlink.radio, "radio1", "downlink radio")
			assert_eq(plan.downlink.ssid, ESSID, "downlink beacons the mesh essid")
			assert_eq(plan.downlink.key, PSK, "with the site PSK")
			assert_eq(plan.downlink.devname, "vwire3", "devname kept for reporting")
			assert_eq(plan.uplink.ssid, ESSID, "the station joins the mesh essid, not its vport name")
			assert_eq(plan.uplink.key, PSK, "with mesh.psk")
			assert_eq(plan.uplink.devname, "ath4", "devname")
			assert_false(plan.uplink.enabled, "wired: the station is written disabled")
			assert_true(mesh.plan(m, entries, true).uplink.enabled, "already wireless: it stays up across a push")
		end
	},
	{
		name = "mesh: plan() is nil without an enabled mesh block, a usable ESSID and PSK, or any entry",
		fn = function()
			local _, _, entries = quietly(function() return wlan.parse(MESH_PUSH) end)
			assert_nil(mesh.plan(nil, entries), "no mesh block")
			assert_nil(mesh.plan({status = false, essid = ESSID, psk = PSK}, entries), "disabled")
			assert_nil(mesh.plan({status = true, essid = ESSID, psk = "short"}, entries), "PSK under 8")
			assert_nil(mesh.plan({status = true, essid = ESSID, psk = PSK .. "\n"}, entries), "unprintable PSK")
			assert_nil(mesh.plan({status = true, essid = "", psk = PSK}, entries), "no essid")
			assert_nil(mesh.plan({status = true, essid = ESSID, psk = PSK}, {}), "no entries")
			local p = mesh.plan({status = true, essid = ESSID, psk = PSK}, {entries[1]})
			assert_true(p.downlink ~= nil and p.uplink == nil, "a parent-only push")
			local bad = mesh.plan({status = true, essid = ESSID, psk = PSK},
				{{role = "uplink", radio = "radio1", devname = "ath4; reboot"}})
			assert_nil(bad.uplink.devname, "a devname that could not be a netdev is dropped")
		end
	},
	{
		name = "mesh: uplink_fields() is the `uplink` STRING naming the uplink VAP, nil while wired",
		fn = function()
			local f = mesh.uplink_fields({name = "ath4", bssid = PARENT_BSS:upper()})
			assert_eq(f.uplink, "ath4", "a string, the uplink VAP's name")
			assert_eq(f.uplink_bssid, PARENT_BSS, "the BSS joined, lower-cased")
			assert_nil(mesh.uplink_fields(nil), "wired: nothing, the default eth0 stands")
			assert_nil(mesh.uplink_fields({name = ""}), "no name: nothing")
			assert_nil(mesh.uplink_fields({name = "ath4", bssid = "x"}).uplink_bssid, "garbage BSSID dropped")
		end
	},

	-- ─── openwrt/backhaul.lua ────────────────────────────────────────────────
	{
		name = "backhaul: decide() is wired-first, with patience on loss and none on return",
		fn = function()
			local mode, ticks = backhaul.decide(true, "wired", 0)
			assert_eq(mode, "wired", "link: wired")
			mode, ticks = backhaul.decide(false, "wired", 0)
			assert_eq(mode, "wired", "one heartbeat without link: still wired")
			assert_eq(ticks, 1, "counted")
			mode = backhaul.decide(false, "wired", 1)
			assert_eq(mode, "wireless", "second heartbeat: wireless")
			mode, ticks = backhaul.decide(true, "wireless", 5)
			assert_eq(mode, "wired", "link back: wired at once")
			assert_eq(ticks, 0, "counter reset")
			mode, ticks = backhaul.decide(nil, "wireless", 3)
			assert_eq(mode, "wireless", "unknown: hold")
			assert_eq(ticks, 0, "and do not accumulate")
			assert_eq((backhaul.decide(nil, nil, nil)), "wired", "nothing known: wired")
		end
	},
	{
		name = "backhaul: tick() learns the wired socket, enables the station after two link-less heartbeats, disables it when the wire is back",
		fn = function()
			local carrier = {wan = true}
			with_seams(carrier, "", function()
				local st = {}
				local secs = {{name = "openuf_bh_ul_radio1", disabled = true}}
				local uf = fake_ufuci(secs, "phy1-sta0")
				local saves = 0
				local sm = {save = function() saves = saves + 1 end}
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), sm), "wired", "wired")
				assert_eq(st.backhaul_wired_port, "wan", "the socket the gateway is behind")
				assert_eq(saves, 1, "persisted")
				carrier.wan = false
				local gone = fake_sysinfo(nil)
				assert_eq(backhaul.tick(st, {}, uf, gone, sm), "wired", "first heartbeat: patience")
				assert_eq(#uf.calls, 0, "station untouched")
				assert_eq(backhaul.tick(st, {}, uf, gone, sm), "wireless", "second: wireless")
				assert_eq(uf.calls[1], true, "station enabled")
				assert_eq(st.backhaul_mode, "wireless", "mode in state")
				-- The gateway is now learnt behind the station: not a wired socket.
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("phy1-sta0"), sm), "wireless", "stays wireless")
				assert_eq(st.backhaul_wired_port, "wan", "the station never becomes the wired socket")
				carrier.wan = true
				assert_eq(backhaul.tick(st, {}, uf, fake_sysinfo("wan"), sm), "wired", "wire back: wired")
				assert_eq(uf.calls[#uf.calls], false, "station disabled")
			end)
		end
	},
	{
		name = "backhaul: tick() falls back to the board's uplink socket before the gateway was ever seen",
		fn = function()
			with_seams({lan1 = false}, "", function()
				local st = {}
				local uf = fake_ufuci({{name = "openuf_bh_ul_radio1", disabled = true}}, nil)
				local cfg = {net = {lan_cpueth = "lan1"}}
				backhaul.tick(st, cfg, uf, fake_sysinfo(nil))
				assert_eq(backhaul.tick(st, cfg, uf, fake_sysinfo(nil)), "wireless",
					"lan1 has no link: the station comes up")
			end)
		end
	},
	{
		name = "backhaul: tick() is a no-op without a station, and forgets a wireless mode whose station is gone",
		fn = function()
			with_seams({wan = false}, "", function()
				local st = {}
				assert_nil(backhaul.tick(st, {}, fake_ufuci({}, nil), fake_sysinfo("wan")), "nothing to do")
				assert_nil(st.backhaul_mode, "state untouched")
				st.backhaul_mode = "wireless"
				backhaul.tick(st, {}, fake_ufuci({}, nil), fake_sysinfo("wan"))
				assert_eq(st.backhaul_mode, "wired", "a later station starts disabled")
			end)
		end
	},
	{
		name = "backhaul: carrier_of() reads operstate first, then carrier, never a hostile name",
		fn = function()
			with_seams({wan = false, lan2 = true}, "", function()
				assert_false(backhaul.carrier_of("wan"), "lowerlayerdown")
				assert_true(backhaul.carrier_of("lan2"), "up")
				assert_nil(backhaul.carrier_of("lan3"), "nothing readable: unknown")
				assert_nil(backhaul.carrier_of("../x"), "not a netdev name")
			end)
		end
	},
	{
		name = "backhaul: parent_for_bssid() names the device behind the BSS joined, from the RAW scan entry, before the push's parent",
		fn = function()
			-- sysinfo.scan_table's entries carry the sibling element as peer_mac;
			-- is_unifi/serialno exist only on the payload's scan_radio_table.
			local si = {scan_table = function() return {
				{bssid = "00:00:5e:00:53:99"},
				{bssid = PARENT_BSS:upper(), peer_mac = PARENT:upper()},
			} end}
			local PUSHED = "00:00:5e:00:53:07"
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = ""}, PARENT_BSS, "phy1-sta0", si),
				PARENT, "the raw entry's peer_mac, case-insensitively on both sides")
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = PUSHED}, PARENT_BSS, "phy1-sta0", si),
				PARENT, "the BSS actually joined beats the parent the last push named")
			local decoded = {scan_table = function() return {
				{bssid = PARENT_BSS, is_unifi = true, serialno = PARENT},
			} end}
			assert_eq(backhaul.parent_for_bssid({}, PARENT_BSS, "phy1-sta0", decoded), PARENT,
				"the payload's shape (is_unifi + serialno) too")
			-- Not in the scan cache: the sibling exchange knows the downlink's BSSID.
			local exchanged = {scan_table = function() return {} end,
				sibling_bssids = function() return {[PARENT_BSS] = PARENT}, {} end}
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = PUSHED}, PARENT_BSS:upper(), "phy1-sta0", exchanged),
				PARENT, "the sibling exchange, before the push's parent")
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = PUSHED}, PARENT_BSS, nil,
				{sibling_bssids = exchanged.sibling_bssids}), PARENT, "no interface to scan from: the exchange still knows")
			-- The push's parent is the fallback, never the first word.
			assert_eq(backhaul.parent_for_bssid({backhaul_parent = PUSHED}, "00:00:5e:00:53:99", "phy1-sta0", si),
				PUSHED, "a BSS nobody tagged: the push's parent")
			assert_nil(backhaul.parent_for_bssid({backhaul_parent = ""}, "00:00:5e:00:53:99", "phy1-sta0", si),
				"neither: unknown, never a guess")
			assert_nil(backhaul.parent_for_bssid({}, PARENT_BSS, nil, si), "no interface, no exchange, no push: unknown")
		end
	},
	{
		name = "backhaul: child_serialno() names the one sibling learnt behind a downlink's WDS netdev",
		fn = function()
			local fdb = {[CHILD] = "phy1-ap1.sta1", ["00:00:5e:00:53:31"] = "phy1-ap1.sta1",
				["00:00:5e:00:53:32"] = "phy1-ap0"}
			local si = {bridge_of = function() return "br-lan" end,
				bridge_fdb_ports = function() return fdb end}
			local sib = {[CHILD] = true, ["00:00:5e:00:53:03"] = true}
			assert_eq(backhaul.child_serialno("phy1-ap1.sta1", sib, {}, si), CHILD, "the sibling behind it")
			assert_nil(backhaul.child_serialno("phy1-ap0", sib, {}, si), "a client VAP: no sibling")
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", {}, {}, si), "no siblings known")
			fdb["00:00:5e:00:53:03"] = "phy1-ap1.sta1"
			assert_nil(backhaul.child_serialno("phy1-ap1.sta1", sib, {}, si),
				"two siblings behind one netdev (a grandchild): refuse to guess")
		end
	},
	{
		name = "backhaul: uplink_link() names the uplink VAP and the BSS joined, only while wireless and associated",
		fn = function()
			local link = "Connected to " .. PARENT_BSS .. " (on phy1-sta0)\n\tSSID: " .. ESSID .. "\n\tfreq: 5500\n"
			local secs = {{name = "openuf_bh_ul_radio1", devname = "ath4"}}
			with_seams({}, link, function()
				local uf = fake_ufuci(secs, "phy1-sta0")
				local l = backhaul.uplink_link({backhaul_mode = "wireless"}, uf)
				assert_eq(l.name, "ath4", "the controller's devname, as the VAP reports it")
				assert_eq(l.bssid, PARENT_BSS, "the BSS joined")
				assert_nil(backhaul.uplink_link({backhaul_mode = "wired"}, uf), "wired: nothing")
				secs[1].devname = nil
				assert_eq(backhaul.uplink_link({backhaul_mode = "wireless"}, uf).name, "openuf_bh_ul_radio1",
					"no devname: the section name, which is also the VAP's")
			end)
			with_seams({}, "Not connected.\n", function()
				assert_nil(backhaul.uplink_link({backhaul_mode = "wireless"}, fake_ufuci(secs, "phy1-sta0")),
					"not associated: nothing")
			end)
		end
	},

	-- ─── ucihelper ───────────────────────────────────────────────────────────
	{
		name = "ucihelper: backhaul_apply writes the hidden WDS downlink and the disabled 4-address station",
		fn = function()
			local uf, db = new_ucihelper()
			local written = uf.backhaul_apply({
				downlink = {radio = "radio1", ssid = ESSID, key = PSK, devname = "vwire3"},
				uplink   = {radio = "radio1", ssid = ESSID, key = PSK, devname = "ath4", enabled = false},
			}, "lan", "dd0d026f556f554601000005e00530")
			assert_eq(#written, 2, "two sections")
			local dl = db.wireless.openuf_bh_dl_radio1
			assert_eq(dl[".type"], "wifi-iface", "a wifi-iface")
			assert_eq(dl.device, "radio1", "on the radio")
			assert_eq(dl.mode, "ap", "an AP")
			assert_eq(dl.wds, "1", "4-address (wds_sta)")
			assert_eq(dl.hidden, "1", "hidden")
			assert_eq(dl.encryption, "psk2", "WPA2-PSK")
			assert_eq(dl.key, PSK, "site PSK")
			assert_eq(dl.network, "lan", "in the management network")
			assert_eq(dl.vendor_elements, "dd0d026f556f554601000005e00530", "beaconing the sibling element")
			assert_eq(dl.openuf_backhaul, "downlink", "marked")
			assert_eq(dl.openuf_devname, "vwire3", "the controller's name kept")
			local ul = db.wireless.openuf_bh_ul_radio1
			assert_eq(ul.mode, "sta", "a station")
			assert_eq(ul.wds, "1", "4-address")
			assert_eq(ul.ssid, ESSID, "joining the mesh essid")
			assert_eq(ul.disabled, "1", "disabled while wired")
			assert_eq(ul.openuf_backhaul, "uplink", "marked")
			assert_eq(#uf.backhaul_uplink_sections(), 1, "listed")
			assert_eq(#uf.backhaul_downlink_sections(), 1, "listed")
		end
	},
	{
		name = "ucihelper: backhaul_set_uplink_enabled flips the station and reloads wireless once, only on a change",
		fn = function()
			local uf, db, cmds = new_ucihelper()
			uf.backhaul_apply({uplink = {radio = "radio1", ssid = ESSID, key = PSK, enabled = false}})
			assert_true(uf.backhaul_set_uplink_enabled(true), "changed")
			assert_eq(db.wireless.openuf_bh_ul_radio1.disabled, "0", "enabled")
			assert_eq(cmds[#cmds], "wifi reload", "reloaded")
			local n = #cmds
			assert_false(uf.backhaul_set_uplink_enabled(true), "already enabled")
			assert_eq(#cmds, n, "no second reload")
		end
	},
	{
		name = "ucihelper: apply_config rewrites the backhaul on every push, and drops it with the mesh block",
		fn = function()
			local uf, db = new_ucihelper()
			local radios, vaps, entries = quietly(function() return wlan.parse(MESH_PUSH) end)
			local plan = mesh.plan(mesh.parse(MESH_PUSH), entries, false)
			quietly(function()
				uf.apply_config({radio_table = radios, vap_table = vaps}, {net = {lan_name = "lan"}},
					{backhaul = plan, peer_ie = "dd0d"})
			end)
			assert_not_nil(db.wireless.openuf_bh_dl_radio1, "downlink written")
			assert_not_nil(db.wireless.openuf_bh_ul_radio1, "uplink written")
			assert_eq(db.wireless.openuf_bh_dl_radio1.vendor_elements, "dd0d", "sibling element from opts")
			for name, s in pairs(db.wireless) do
				if s[".type"] == "wifi-iface" and s.openuf_backhaul == nil then
					assert_neq(s.ssid, ESSID, name .. ": the downlink is not also an ordinary AP")
					assert_neq(s.ssid, "vport-00005e005302", name .. ": the uplink is not an AP")
				end
			end
			-- A push without the mesh block: both go.
			quietly(function()
				uf.apply_config({radio_table = radios, vap_table = vaps}, {}, {})
			end)
			assert_nil(db.wireless.openuf_bh_dl_radio1, "downlink removed")
			assert_nil(db.wireless.openuf_bh_ul_radio1, "uplink removed")
		end
	},
	{
		name = "ucihelper: the backhaul is reported as typed VAPs, kept out of l2guard and of the per-radio reads",
		fn = function()
			local uf = new_ucihelper()
			uf.backhaul_apply({
				downlink = {radio = "radio1", ssid = ESSID, key = PSK, devname = "vwire3"},
				uplink   = {radio = "radio1", ssid = ESSID, key = PSK, devname = "ath4", enabled = true},
			})
			local status = wireless_status({
				{section = "openuf_bh_ul_radio1", ifname = "phy1-sta0", mode = "sta", ssid = ESSID, wds = true},
				{section = "openuf_radio1_home", ifname = "phy1-ap0", ssid = "home"},
				{section = "openuf_bh_dl_radio1", ifname = "phy1-ap1", ssid = ESSID, wds = true},
			})
			uf._popen = function(cmd)
				if cmd:find("network.wireless status", 1, true) then return status end
				if cmd:find("iw dev phy1-sta0 link", 1, true) then
					return "Connected to " .. PARENT_BSS .. " (on phy1-sta0)\n"
				end
				if cmd == "ls /sys/class/net" then
					return "br-lan\nphy1-ap0\nphy1-ap1\nphy1-ap1.sta1\nphy1-ap1.sta12\nphy1-ap1.stax\nphy1-sta0\n"
				end
				return ""
			end
			uf._read_file = function(path)
				if path == "/sys/class/net/phy1-sta0/address" then return "00:00:5e:00:53:21\n" end
				if path == "/sys/class/net/phy1-ap1/address" then return "00:00:5e:00:53:22\n" end
				return nil
			end
			local by_usage = {}
			for _, v in ipairs(uf.get_vap_table()) do by_usage[v.usage] = v end
			local up, down = by_usage.uplink, by_usage.downlink
			assert_eq(up.name, "ath4", "the uplink under the controller's devname")
			assert_eq(up.essid, ESSID, "its essid is the mesh essid (is_mesh_v3)")
			assert_true(up.up, "associated: up")
			assert_eq(up.state, "RUN", "RUN")
			assert_eq(up.bssid, "00:00:5e:00:53:21", "its own address")
			assert_eq(table.concat(up._ifnames, ","), "phy1-sta0", "its station dump is the parent")
			assert_eq(down.name, "vwire3", "the downlink")
			assert_eq(table.concat(down._ifnames, ","), "phy1-ap1,phy1-ap1.sta1,phy1-ap1.sta12",
				"its BSS and each child's WDS netdev, nothing else")
			assert_eq(table.concat(uf.ap_ifnames(), ","), "phy1-ap0", "l2guard sees only the client VAP")
			assert_eq(uf.get_ifname_for_radio("radio1"), "phy1-ap0", "per-radio reads prefer the client VAP")
			assert_eq(uf.ifname_for_section("openuf_bh_dl_radio1"), "phy1-ap1", "section -> netdev")
		end
	},
	{
		name = "ucihelper: a disabled uplink station is still reported, down",
		fn = function()
			local uf = new_ucihelper()
			uf.backhaul_apply({uplink = {radio = "radio1", ssid = ESSID, key = PSK, enabled = false}})
			local v = uf.get_vap_table()[1]
			assert_eq(v.usage, "uplink", "reported")
			assert_eq(v.name, "openuf_bh_ul_radio1", "no devname: the section name")
			assert_true(v.disabled, "disabled")
			assert_false(v.up, "down")
		end
	},

	{
		name = "mesh: the uplink's state survives a restart",
		fn = function()
			local state = dofile("src/state.lua")
			state._state_file = "/tmp/openuf_test_mesh_state_rt.json"
			state.save({backhaul_mode = "wireless", backhaul_wired_port = "wan", backhaul_parent = PARENT})
			local st = state.load()
			os.remove(state._state_file)
			assert_eq(st.backhaul_mode, "wireless", "mode")
			assert_eq(st.backhaul_wired_port, "wan", "wired socket")
			assert_eq(st.backhaul_parent, PARENT, "the push's parent")
		end
	},

	-- ─── provision.lua and report.lua ────────────────────────────────────────
	{
		name = "mesh: handle_response hands apply_config the plan and keeps the push's parent",
		fn = function()
			local inform = dofile("src/inform.lua")
			inform._state._state_file = "/tmp/openuf_test_mesh_state.json"
			inform._firewall = {reconcile = function() end, deauth = function() end}
			inform._l2guard = setmetatable({reconcile = function() return 0 end}, {__index = inform._l2guard})
			inform._guestguard = setmetatable({reconcile = function() return false end}, {__index = inform._guestguard})
			inform._sysconf = setmetatable({apply_cron = function() return false end, apply = function() end},
				{__index = inform._sysconf})
			inform._airtime = setmetatable({set_enabled = function() return 0, 0 end}, {__index = inform._airtime})
			inform._usteer = {set_enabled = function() end}
			inform._switchvlan = nil
			inform._netmodel = nil
			local opts_seen
			inform._ucihelper = {apply_config = function(_, _, opts) opts_seen = opts end}
			local st = {authkey = inform._state.DEFAULT_KEY, adopted = true, cfgversion = "", mac = CHILD,
				backhaul_mode = "wireless"}
			local resp = cjson.encode({_type = "setparam", system_cfg = MESH_PUSH})
			quietly(function() inform.handle_response(resp, st, {net = {lan_cpueth = "eth0"}}) end)
			os.remove("/tmp/openuf_test_mesh_state.json")
			assert_not_nil(opts_seen and opts_seen.backhaul, "a plan reached apply_config")
			assert_true(opts_seen.backhaul.uplink.enabled, "already wireless: the station stays up")
			assert_eq(st.backhaul_parent, PARENT, "the push's parent kept")
			-- A wired push: no plan.
			opts_seen = nil
			local wired = cjson.encode({_type = "setparam",
				system_cfg = "wireless.1.ssid=home\nwireless.1.parent=radio0\naaa.1.wpa=2\naaa.1.wpa.psk=hunter2hunter2"})
			quietly(function() inform.handle_response(wired, st, {net = {lan_cpueth = "eth0"}}) end)
			os.remove("/tmp/openuf_test_mesh_state.json")
			assert_nil(opts_seen.backhaul, "no mesh block, no plan")
		end
	},
	{
		name = "mesh: the payload claims the mesh bits only with wireless_uplink, and reports the uplink and its links",
		fn = function()
			local inform = dofile("src/inform.lua")
			local si = inform._sysinfo
			si._read_file = function() return "" end
			si._run_cmd = function() return "" end
			si._phy_info_cache, si._uplink_cache = {}, {}
			inform._lldp._run_cmd = function() return "" end
			inform._lldp._neighbours_cache = nil
			inform._airtime._supported_cache = false
			si._ppsk_supported_cache = false
			si.sta_table = function(ifname)
				if ifname == "phy1-sta0" then return {{mac = PARENT_BSS, signal = -90, tx_packets = 1}} end
				if ifname == "phy1-ap1.sta1" then return {{mac = "00:00:5e:00:53:23", signal = -90, tx_packets = 1}} end
				return {}
			end
			si.bridge_of = function() return "br-lan" end
			si.bridge_fdb_ports = function() return {[CHILD] = "phy1-ap1.sta1"} end
			si.sibling_bssids = function() return {["00:00:5e:00:53:12"] = CHILD}, {} end
			si.scan_table = function() return {} end
			local kicked = 0
			inform._ucihelper = {
				get_radio_table = function()
					return {{name = "radio1", radio = "na", channel = 100, min_rssi_enabled = true, min_rssi_raw = 25}}
				end,
				get_vap_table = function()
					return {
						{name = "ath4", essid = ESSID, radio = "na", radio_name = "radio1", usage = "uplink",
						 up = true, state = "RUN", _ifnames = {"phy1-sta0"}},
						{name = "vwire3", essid = ESSID, radio = "na", radio_name = "radio1", usage = "downlink",
						 up = true, state = "RUN", _ifnames = {"phy1-ap1", "phy1-ap1.sta1"}},
					}
				end,
				-- The radio's client VAP: where the Minimum RSSI threshold is read.
				get_ifname_for_radio = function() return "phy1-ap0" end,
				get_ifnames_for_vap = function() return {} end,
				kick_station = function() kicked = kicked + 1 end,
				backhaul_uplink_sections = function() return {{name = "openuf_bh_ul_radio1", devname = "ath4"}} end,
				ifname_for_section = function() return "phy1-sta0" end,
			}
			inform._backhaul._popen = function(cmd)
				if cmd:find("link", 1, true) then return "Connected to " .. PARENT_BSS .. " (on phy1-sta0)\n" end
				return ""
			end
			local ufhw = {uap = {platform = "U6IW", model = "U6IW", fw = {pre = "U6IW.", ver = "6.6.55"}}}
			local st = {authkey = inform._state.DEFAULT_KEY, adopted = true, cfgversion = "", mac = CHILD,
				backhaul_mode = "wireless", backhaul_parent = PARENT}
			local plain = cjson.decode(inform.build_json(st, {config = {}}, ufhw))
			assert_eq(plain.wifi_caps % 0x2, 0, "0x1 not claimed by default")
			assert_eq(math.floor(plain.wifi_caps / 0x800) % 2, 0, "0x800 not claimed by default")
			local d = cjson.decode(inform.build_json(st, {config = {wireless_uplink = true}}, ufhw))
			assert_eq(d.wifi_caps - plain.wifi_caps, 0x801, "exactly 0x1 + 0x800 with the option")
			assert_eq(d.uplink, "ath4", "uplink names the uplink VAP")
			assert_eq(d.uplink_bssid, PARENT_BSS, "and the BSS joined")
			local up, down
			for _, v in ipairs(d.vap_table) do
				if v.usage == "uplink" then up = v elseif v.usage == "downlink" then down = v end
				assert_nil(v._ifnames, "the internal netdev list never reaches the wire")
			end
			assert_eq(#up.sta_table, 1, "the uplink's one station")
			assert_eq(up.sta_table[1].serialno, PARENT, "is the parent")
			assert_eq(#down.sta_table, 1, "the downlink's child station")
			assert_eq(down.sta_table[1].serialno, CHILD, "named from the FDB and the sibling exchange")
			assert_eq(kicked, 0, "Minimum RSSI never kicks a backhaul peer")
			assert_nil(d.satisfaction, "backhaul peers are not clients in the device's Experience")
			st.backhaul_mode = "wired"
			local w = cjson.decode(inform.build_json(st, {config = {wireless_uplink = true}}, ufhw))
			assert_nil(w.uplink, "wired: no uplink string, the default stands")
		end
	},
}
