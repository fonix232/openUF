-- Tests for src/openwrt/board.lua (the device described from itself) and
-- src/unifi/identity.lua (the UniFi model it presents).
-- Run from the package directory: lua tests/run_tests.lua

local board    = require("openwrt.board")
local identity = require("unifi.identity")
local cjson    = require("cjson")

local function read(p)
	local f = assert(io.open(p, "r"))
	local s = f:read("*a")
	f:close()
	return s
end

local E8450 = read("tests/fixtures/board_e8450.json")

-- A device: files by path, command output by prefix. Writes are recorded.
local function device(files, commands)
	local written = {}
	board._read = function(path) return files[path] end
	board._write = function(path, s) written[path] = s; files[path] = s; return true end
	board._sh = function(cmd)
		for prefix, out in pairs(commands) do
			if cmd:sub(1, #prefix) == prefix then return out end
		end
		return ""
	end
	return written
end

-- bifrost, cabled to odin on lan4: the gateway 10.0.0.1 is learned there.
local function bifrost(extra)
	local files = {
		["/etc/board.json"] = E8450,
		["/proc/net/arp"] = "IP address       HW type     Flags       HW address            Mask     Device\n"
			.. "10.0.0.1         0x1         0x2         aa:bb:cc:dd:ee:01     *        br-lan\n",
		["/sys/class/net/br-lan/address"] = "c4:41:1e:f8:98:3e\n",
	}
	for k, v in pairs(extra or {}) do files[k] = v end
	return files, {
		["ip -4 route show default"] = "default via 10.0.0.1 dev br-lan\n",
		["bridge fdb show"] = "aa:bb:cc:dd:ee:01 dev lan4 master br-lan\n33:33:00:00:00:01 dev lan1 self permanent\n",
		["readlink /sys/class/net/lan4/master"] = "../br-lan\n",
		["ls /sys/class/leds"] = "inet:blue\ninet:orange\npower:blue\npower:orange\nmt76-phy0\n",
		["uci -q show wireless"] = "wireless.radio0=wifi-device\nwireless.radio1=wifi-device\nwireless.x=wifi-iface\n",
	}
end

return {
	{
		name = "board: an E8450 is described from board.json, the bridge and its LEDs",
		fn = function()
			device(bifrost())
			local d = board.derive(cjson.decode(E8450), 5)
			assert_eq(d.uplink, "lan4", "the socket the gateway is learned on")
			assert_eq(d.identity_mac, "c4:41:1e:f8:98:3e", "the bridge's MAC, not the socket's")
			assert_eq(d.led, "power:blue", "status/power LED, blue preferred")
			assert_eq(table.concat(d.radios, ","), "radio0,radio1", "every wifi-device")
			local by_if = {}
			for _, p in ipairs(d.ports) do by_if[p.ifname] = p.idx end
			assert_eq(by_if.lan4, 5, "a switch model's uplink is its last port")
			assert_eq(by_if.wan, 1, "then the sockets in board.json order")
			assert_eq(by_if.lan3, 4, "up to the port before the uplink")
		end
	},
	{
		name = "board: a plain AP model takes the uplink on port 1",
		fn = function()
			device(bifrost())
			local d = board.derive(cjson.decode(E8450), 1)
			local by_if = {}
			for _, p in ipairs(d.ports) do by_if[p.ifname] = p.idx end
			assert_eq(by_if.lan4, 1, "uplink on port 1")
			assert_eq(by_if.wan, 2, "the rest after it")
		end
	},
	{
		name = "board: an undetected uplink falls back to wan and is not kept",
		fn = function()
			local files, cmds = bifrost()
			cmds["ip -4 route show default"] = ""
			local written = device(files, cmds)
			local dev = board.describe()
			assert_eq(dev.conf.net.lan_cpueth, "wan", "board.json's wan device")
			assert_nil(written[board.LAYOUT_FILE], "a guess is not persisted")
		end
	},
	{
		name = "board: describe persists a detected layout and the identity, and reads them back",
		fn = function()
			local files, cmds = bifrost()
			local written = device(files, cmds)
			local saved_err = io.stderr
			io.stderr = {write = function() end}
			local dev = board.describe()
			io.stderr = saved_err
			assert_eq(dev.conf.net.lan_cpueth, "lan4", "detected uplink")
			assert_eq(dev.identity.model, "U6IW", "a 5-socket WiFi 6 board is a U6-IW")
			assert_eq(dev.openuf.uap.ufmodel, "auto", "chosen automatically")
			assert_eq(#dev.openuf.uap.hwassign, 2, "radios for the payload")
			assert_not_nil(written[board.LAYOUT_FILE], "layout kept")
			assert_eq(cjson.decode(written[board.IDENTITY_FILE]).model, "U6IW", "identity kept")
			-- Moving the cable changes nothing once the layout is kept.
			cmds["bridge fdb show"] = "aa:bb:cc:dd:ee:01 dev lan1 master br-lan\n"
			local again = board.describe()
			assert_eq(again.conf.net.lan_cpueth, "lan4", "kept layout wins")
		end
	},
	{
		name = "identity: a saved choice is kept, a missing board falls back to U6-IW",
		fn = function()
			local uap, code, fresh = identity.choose(cjson.decode(E8450), "UHDIW")
			assert_eq(code, "UHDIW", "saved model kept even if another scores higher")
			assert_false(fresh, "not a fresh choice")
			assert_eq(uap.model, "UHDIW", "its identity")
			local fb, fcode, ffresh = identity.choose(nil, nil)
			assert_eq(fcode, identity.FALLBACK, "fallback")
			assert_false(ffresh, "nothing was chosen")
			assert_eq(fb.sysid, 0xa652, "U6-IW's sysid")
			local _, scode, sfresh = identity.choose(cjson.decode(E8450), "NO-SUCH-MODEL")
			assert_eq(scode, "U6IW", "an unknown saved code is chosen again")
			assert_true(sfresh, "and counts as fresh")
		end
	},
}
