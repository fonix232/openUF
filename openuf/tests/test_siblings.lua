-- Tests for src/openwrt/siblings.lua (the sibling BSSID exchange) and
-- src/openwrt/idlescan.lua (off-channel scans of idle radios).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local cjson    = require("cjson")
local siblings = require("openwrt.siblings")
local idlescan = require("openwrt.idlescan")

local SELF = "00:00:5e:00:53:01"
local PEER = "00:00:5e:00:53:02"

-- Two radios, four interfaces: two APs on phy#0, one AP and one station
-- interface on phy#1 (the station must not count as an AP).
local IW_DEV = [[
phy#1
	Interface phy1-sta0
		ifindex 12
		addr 00:00:5e:00:53:1a
		type managed
	Interface phy1-ap0
		ifindex 11
		addr 00:00:5e:00:53:1b
		ssid Home
		type AP
		channel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz
phy#0
	Interface phy0-ap1
		ifindex 10
		addr 00:00:5e:00:53:0b
		type AP
	Interface phy0-ap0
		ifindex 9
		addr 00:00:5e:00:53:0a
		ssid Home
		type AP
]]

-- idlescan with canned `iw` output: stations[ifname] = true for a busy one.
local function stub_idlescan(stations)
	local spawned = {}
	idlescan._run_cmd = function(cmd)
		if cmd == "iw dev" then return IW_DEV end
		local i = cmd:match("^iw dev (%S+) station dump$")
		if i and stations[i] then
			return "Station 00:00:5e:00:53:99 (on " .. i .. ")\n\tsignal: -50 dBm\n"
		end
		return ""
	end
	idlescan._spawn = function(cmd) spawned[#spawned + 1] = cmd end
	return spawned
end

return {
	{
		name = "siblings: a packet round-trips its MAC and BSSIDs",
		fn = function()
			local pkt = siblings.build(SELF, {{bssid = "00:00:5E:00:53:0A", freq = 2437},
				{bssid = "00:00:5e:00:53:1b", freq = 5580}, {bssid = "00:00:5e:00:53:1c"}},
				{model = "U6IW", model_display = "U6-IW"})
			assert_eq(pkt:sub(1, 4), "oUFs", "magic")
			assert_eq(pkt:byte(5), 3, "version 3")
			assert_eq(#pkt, 11 + (1 + 4) + (1 + 5) + 1 + 3 * 8,
				"header, both model strings, count, three BSSID+frequency entries")
			local mac, bssids, info = siblings.parse(pkt)
			assert_eq(info.model, "U6IW", "model code")
			assert_eq(info.model_display, "U6-IW", "model display")
			local _, _, none = siblings.parse(siblings.build(SELF, {}))
			assert_nil(none.model, "no model sent: none parsed")
			assert_eq(mac, SELF, "identity MAC")
			assert_eq(#bssids, 3, "all BSSIDs")
			assert_eq(bssids[1].bssid, "00:00:5e:00:53:0a", "lower-cased")
			assert_eq(bssids[1].freq, 2437, "2.4 GHz frequency")
			assert_eq(bssids[2].freq, 5580, "5 GHz frequency above 255 survives")
			assert_nil(bssids[3].freq, "unknown frequency stays unknown")
		end
	},
	{
		name = "siblings: malformed input builds or parses to nothing",
		fn = function()
			assert_nil(siblings.build("not-a-mac", {}), "bad identity MAC")
			local _, b = siblings.parse(siblings.build(SELF,
				{{bssid = "junk"}, {bssid = "00:00:5e:00:53:0a"}}))
			assert_eq(#b, 1, "a bad BSSID is left out, the good one kept")
			assert_nil(siblings.parse("oUFs"), "short")
			assert_nil(siblings.parse(string.char(1, 0, 0, 0)), "a Ubiquiti probe")
			local pkt = siblings.build(SELF, {{bssid = "00:00:5e:00:53:0a"}})
			assert_nil(siblings.parse(pkt .. "x"), "length disagrees with the count")
			assert_nil(siblings.parse("oUFs" .. string.char(2) .. pkt:sub(6)), "another version")
			assert_nil(siblings.parse(pkt:sub(1, 12) .. string.char(200)),
				"a model length running past the packet")
		end
	},
	{
		name = "siblings: own BSSIDs are the AP interfaces' addresses only",
		fn = function()
			local own = siblings.own_bssids(IW_DEV)
			assert_eq(#own, 3, "three AP interfaces, the station left out")
			assert_eq(own[1].bssid, "00:00:5e:00:53:1b", "phy1-ap0")
			assert_eq(own[1].freq, 5180, "its channel line, printed after the type")
			assert_eq(own[2].bssid, "00:00:5e:00:53:0b", "phy0-ap1")
			assert_nil(own[2].freq, "no channel line: unknown")
			assert_eq(own[3].bssid, "00:00:5e:00:53:0a", "phy0-ap0")
		end
	},
	{
		name = "siblings: our own broadcast is ignored, a sibling's is kept and expires",
		fn = function()
			local store = {}
			assert_false(siblings.record(store, siblings.build(SELF, {{bssid = "00:00:5e:00:53:0a"}}),
				SELF, 100), "own packet")
			assert_nil(next(store), "nothing stored from it")
			assert_true(siblings.record(store, siblings.build(PEER,
				{{bssid = "00:00:5e:00:53:2a", freq = 5580}}), SELF, 100), "sibling packet")
			assert_eq(store["00:00:5e:00:53:2a"].mac, PEER, "BSSID -> sibling MAC")
			assert_eq(store["00:00:5e:00:53:2a"].freq, 5580, "and its frequency")
			siblings.expire(store, 100 + siblings.TTL)
			assert_not_nil(store["00:00:5e:00:53:2a"], "kept up to the TTL")
			siblings.expire(store, 101 + siblings.TTL)
			assert_nil(store["00:00:5e:00:53:2a"], "gone after it")
		end
	},
	{
		name = "siblings: the saved table decodes to fresh entries only",
		fn = function()
			local text = cjson.encode({
				["00:00:5E:00:53:2A"] = {mac = PEER, seen = 1000},
				["00:00:5e:00:53:2b"] = {mac = PEER, seen = 1000 - siblings.TTL - 1},
				["00:00:5e:00:53:2c"] = {seen = 1000},
			})
			local m = siblings.decode(text, 1000, cjson)
			assert_eq(m["00:00:5e:00:53:2a"], PEER, "fresh, key lower-cased")
			assert_nil(m["00:00:5e:00:53:2b"], "stale")
			assert_nil(m["00:00:5e:00:53:2c"], "no MAC")
			assert_nil(next(siblings.decode("", 1000, cjson)), "no file: empty")
			assert_nil(next(siblings.decode("{oops", 1000, cjson)), "garbage: empty")
		end
	},
	{
		name = "idlescan: radios are grouped by phy, AP interfaces only",
		fn = function()
			local r = idlescan.radios(IW_DEV)
			assert_eq(#r, 2, "two radios")
			assert_eq(r[1].phy, "phy#1", "first phy")
			assert_eq(#r[1].ifaces, 1, "the station interface is not counted")
			assert_eq(r[2].ifaces[1], "phy0-ap1", "phy#0's first AP")
			assert_eq(#r[2].ifaces, 2, "phy#0 has two")
		end
	},
	{
		name = "idlescan: only a radio without clients is scanned, then not again until the interval",
		fn = function()
			local spawned = stub_idlescan({["phy0-ap0"] = true})
			local next_at = {}
			local started = idlescan.tick(next_at, 1000, 1800)
			assert_eq(#started, 1, "one radio scanned")
			assert_eq(spawned[1], "iw dev phy1-ap0 scan ap-force", "the idle one, phy#1")
			assert_eq(started[1], spawned[1], "reported as started")
			assert_eq(next_at["phy#1"], 2800, "next scan an interval later")
			assert_eq(next_at["phy#0"], 1000 + idlescan.RETRY, "the busy radio is looked at again soon")
			assert_eq(#idlescan.tick(next_at, 1030, 1800), 0, "nothing due yet")
			stub_idlescan({})
			assert_eq(#idlescan.tick(next_at, 1000 + idlescan.RETRY, 1800), 1,
				"phy#0 scanned once its client has gone")
		end
	},
	{
		name = "idlescan: a busy radio listens only on its siblings' channels in its band",
		fn = function()
			local spawned = stub_idlescan({["phy0-ap0"] = true, ["phy1-ap0"] = true})
			local next_at = {}
			-- phy#1 is on 5180; siblings on 2437, 5180 (same channel), 5580, 5660.
			local started = idlescan.tick(next_at, 1000, 1800,
				{sibling_interval = 1800, sibling_freqs = {2437, 5180, 5580, 5660}})
			assert_eq(#started, 1, "only phy#1 knows its own frequency")
			assert_eq(spawned[1], "iw dev phy1-ap0 scan freq 5580 5660 ap-force",
				"5 GHz siblings only, its own channel left out")
			assert_eq(next_at["phy#1/siblings"], 2800, "next sibling scan an interval later")
			assert_eq(#idlescan.tick(next_at, 1100, 1800,
				{sibling_interval = 1800, sibling_freqs = {5580}}), 0, "not due yet")
		end
	},
	{
		name = "idlescan: a sweep counts as the sibling scan; no siblings, no scan",
		fn = function()
			local spawned = stub_idlescan({})
			local next_at = {}
			idlescan.tick(next_at, 1000, 1800, {sibling_interval = 600, sibling_freqs = {5580}})
			for _, c in ipairs(spawned) do
				assert_true(c:find("scan freq", 1, true) == nil, "idle radios are swept, not sibling-scanned")
			end
			assert_eq(next_at["phy#1/siblings"], 1600, "sibling clock restarted by the sweep")
			spawned = stub_idlescan({["phy1-ap0"] = true, ["phy0-ap0"] = true})
			assert_eq(#idlescan.tick({}, 1000, 0, {sibling_interval = 600, sibling_freqs = {}}), 0,
				"nothing announced: nothing to listen for")
			local f = idlescan.sibling_freqs(2412, {2437, 2462, 2412, 2472, 2484, 5180})
			assert_eq(table.concat(f, ","), "2437,2462,2472",
				"2.4 GHz only, own channel left out, at most MAX_SIBLING_FREQS")
		end
	},
	{
		name = "idlescan: an interval of 0 or none never scans",
		fn = function()
			local spawned = stub_idlescan({})
			assert_eq(#idlescan.tick({}, 1000, 0), 0, "0 = off")
			assert_eq(#idlescan.tick({}, 1000, nil), 0, "unset = off")
			assert_eq(#spawned, 0, "no scan started")
		end
	},
}
