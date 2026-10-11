-- Tests for src/openwrt/siblings.lua (the sibling BSSID exchange) and
-- src/openwrt/idlescan.lua (off-channel scans of idle radios).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local cjson    = require("cjson")
local siblings = require("openwrt.siblings")
local idlescan = require("openwrt.idlescan")

local SELF = "00:00:5e:00:53:01"
local PEER = "00:00:5e:00:53:02"
-- Made-up site keys (unifi.key is 32 hex chars).
local SITE_KEY  = "0123456789abcdef0123456789abcdef"
local OTHER_KEY = "fedcba9876543210fedcba9876543210"

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
			assert_eq(pkt:byte(5), 3, "version 3: what every openUF build understands")
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
	{
		name = "siblings: the exchange key is derived from the site key, never equal to it",
		fn = function()
			local k = siblings.derive_key(SITE_KEY)
			assert_eq(#k, 64, "64 hex chars")
			assert_true(k:find(SITE_KEY, 1, true) == nil, "the site key does not appear in it")
			assert_eq(siblings.derive_key(SITE_KEY:upper()), k, "case of the site key does not matter")
			assert_nil(siblings.derive_key("abc"), "not a 32-hex key")
			assert_nil(siblings.derive_key(nil), "none")
		end
	},
	{
		name = "siblings: with a key, a v5 packet carries the lock list, authenticated",
		fn = function()
			local key = siblings.derive_key(SITE_KEY)
			local v3, v5 = siblings.build(SELF, {{bssid = "00:00:5e:00:53:0a", freq = 2437}},
				{model = "U6IW"}, {"00:00:5E:00:53:21", "not-a-mac", "00:00:5e:00:53:22"}, key, 1000)
			assert_eq(v3:byte(5), 3, "the v3 packet goes too, for older siblings")
			assert_eq(v5:byte(5), 5, "version 5")
			local mac, bssids, info, locks, authed = siblings.parse(v5, key, 1000)
			assert_eq(mac, SELF, "sender")
			assert_eq(#bssids, 1, "its BSSID")
			assert_eq(info.model, "U6IW", "its model")
			assert_true(authed, "authenticated")
			assert_eq(table.concat(locks, " "), "00:00:5e:00:53:21 00:00:5e:00:53:22",
				"the locks, lowercase, a malformed one dropped")
			local _, why = siblings.parse(v5, siblings.derive_key(OTHER_KEY), 1000)
			assert_eq(why, "unauthenticated", "another site's key: refused")
			_, why = siblings.parse(v5, nil, 1000)
			assert_eq(why, "unauthenticated", "no key here: refused")
			local forged = v5:sub(1, 12) .. "X" .. v5:sub(14)
			_, why = siblings.parse(forged, key, 1000)
			assert_eq(why, "unauthenticated", "one byte changed: refused")
			_, why = siblings.parse(v5, key, 1000 + siblings.SKEW + 1)
			assert_eq(why, "clock", "a replay from long ago, or a clock far off: refused")
			local m3, b3, _, l3, a3 = siblings.parse(v3, key, 1000)
			assert_eq(m3, SELF, "the v3 packet is still heard")
			assert_eq(#b3, 1, "with its BSSID")
			assert_eq(#l3, 0, "and no locks")
			assert_false(a3, "unauthenticated")
		end
	},
	{
		name = "siblings: no key, no v5 packet; a v4 packet's lock list is ignored",
		fn = function()
			local v3, v5 = siblings.build(SELF, {{bssid = "00:00:5e:00:53:0a"}}, nil,
				{"00:00:5e:00:53:21"})
			assert_eq(v3:byte(5), 3, "v3 only")
			assert_nil(v5, "nothing to authenticate with: no lock list sent")
			-- A v4 packet, as builds before v5 sent it: v3 body + lock list.
			local v4 = "oUFs" .. string.char(4) .. v3:sub(6) .. string.char(1)
				.. string.char(0, 0, 0x5e, 0, 0x53, 0x21)
			local mac, bssids, _, locks, authed = siblings.parse(v4)
			assert_eq(mac, SELF, "a v4 sibling's BSSIDs are still heard")
			assert_eq(#bssids, 1, "its BSSID")
			assert_eq(#locks, 0, "its unauthenticated locks are not")
			assert_false(authed, "unauthenticated")
			local _, why = siblings.parse("oUFs" .. string.char(6) .. v3:sub(6))
			assert_eq(why, "version 6", "an unknown version says so")
		end
	},
	{
		name = "siblings: only an authenticated sibling's locks and BSSIDs reach locked_here and backhaul",
		fn = function()
			local key = siblings.derive_key(SITE_KEY)
			local store = {}
			local _, a = siblings.build(PEER, {{bssid = "00:00:5e:00:53:1c"}}, nil,
				{"00:00:5e:00:53:21", "00:00:5e:00:53:23"}, key, 1000)
			assert_true(siblings.record(store, a, SELF, 1000, key), "authenticated sibling")
			local _, b = siblings.build("00:00:5e:00:53:03",
				{{bssid = "00:00:5e:00:53:1d"}}, nil, {"00:00:5e:00:53:21"}, key, 1000)
			siblings.record(store, b, SELF, 1000, key)
			-- An unauthenticated sender claims :1c for itself and :1e anew.
			local forged = siblings.build("00:00:5e:00:53:66",
				{{bssid = "00:00:5e:00:53:1c"}, {bssid = "00:00:5e:00:53:1e"}})
			assert_true(siblings.record(store, forged, SELF, 1001, key), "kept, unauthenticated")
			local text = cjson.encode(store)
			local locks = siblings.decode_locks(text, 1010, cjson)
			assert_true(locks["00:00:5e:00:53:21"] and locks["00:00:5e:00:53:23"], "the union")
			-- This AP denies :23 itself, so :23 is locked to some third AP;
			-- :21 is denied by both siblings and not here: locked to this AP.
			local here = siblings.locked_here(locks, {"00:00:5e:00:53:23"})
			assert_eq(table.concat(here, " "), "00:00:5e:00:53:21", "locked to this AP")
			local all = siblings.decode(text, 1010, cjson)
			assert_eq(all["00:00:5e:00:53:1e"], "00:00:5e:00:53:66",
				"scan tagging hears an unauthenticated sender")
			local authed = siblings.decode(text, 1010, cjson, true)
			assert_eq(authed["00:00:5e:00:53:1c"], PEER,
				"backhaul keeps the identity the authenticated sibling claimed")
			assert_nil(authed["00:00:5e:00:53:1e"], "and never an unauthenticated one")
			assert_eq(#siblings.locked_here(siblings.decode_locks(text,
				1000 + siblings.TTL + 1, cjson), {}), 0, "a silent sibling's locks age out")
			assert_eq(#siblings.locked_here(siblings.decode_locks("garbage", 1010, cjson), nil), 0,
				"an unreadable file: nothing locked")
			-- Unauthenticated packets alone never lock anything.
			local s2 = {}
			local v4 = "oUFs" .. string.char(4) .. forged:sub(6) .. string.char(1)
				.. string.char(0, 0, 0x5e, 0, 0x53, 0x21)
			siblings.record(s2, v4, SELF, 1000, key)
			assert_nil(next(siblings.decode_locks(cjson.encode(s2), 1010, cjson)),
				"a v4 lock list locks nothing")
		end
	},
	{
		name = "siblings: the store holds at most MAX_STORE BSSIDs and says when it is full",
		fn = function()
			local store = {}
			local n = 0
			for i = 1, 40 do
				local list = {}
				for j = 1, 32 do
					list[#list + 1] = {bssid = string.format("02:00:00:00:%02x:%02x", i, j)}
				end
				local pkt = siblings.build(string.format("02:00:00:01:00:%02x", i), list)
				local ok, why = siblings.record(store, pkt, SELF, 1000)
				assert_true(ok, "a sibling's packet")
				if why == "full" then n = n + 1 end
			end
			local count = 0
			for _ in pairs(store) do count = count + 1 end
			assert_eq(count, siblings.MAX_STORE, "capped")
			assert_eq(n, 8, "the last eight senders were told it is full")
			-- A known BSSID is still refreshed while full.
			local pkt = siblings.build("02:00:00:01:00:01", {{bssid = "02:00:00:00:01:01", freq = 2412}})
			local ok, why = siblings.record(store, pkt, SELF, 1100)
			assert_true(ok and why == nil, "refreshing a known BSSID is not refused")
			assert_eq(store["02:00:00:00:01:01"].seen, 1100, "refreshed")
		end
	},
	{
		name = "siblings: more locks than fit are cut at MAX_LOCKS and reported",
		fn = function()
			local locks = {}
			for i = 1, siblings.MAX_LOCKS + 5 do
				locks[#locks + 1] = string.format("02:00:00:02:%02x:%02x", math.floor(i / 256), i % 256)
			end
			local key = siblings.derive_key(SITE_KEY)
			local _, v5, cut = siblings.build(SELF, {}, nil, locks, key, 1000)
			assert_true(cut, "reported as cut")
			local _, _, _, got = siblings.parse(v5, key, 1000)
			assert_eq(#got, siblings.MAX_LOCKS, "MAX_LOCKS sent")
			assert_true(#v5 <= 1472, "still fits one frame")
		end
	},
	{
		name = "siblings: the key file holds the derived key only, mode 0600, and goes when the key does",
		fn = function()
			local path = os.tmpname()
			os.remove(path)
			local cmds = {}
			local function run(cmd) cmds[#cmds + 1] = cmd; return os.execute(cmd) end
			assert_eq(siblings.store_key(SITE_KEY, path, run), "written", "written")
			assert_contains(cmds[1], "chmod 600", "made private before the key went in")
			local f = io.open(path, "r")
			local text = f:read("*a")
			f:close()
			assert_true(text:find(SITE_KEY, 1, true) == nil, "the site key is not on disk")
			assert_eq(siblings.read_key(path), siblings.derive_key(SITE_KEY), "the derived key is")
			local p = io.popen("stat -c %a '" .. path .. "' 2>/dev/null || stat -f %Lp '" .. path .. "'")
			assert_eq((p:read("*a") or ""):match("%d+"), "600", "readable by its owner only")
			p:close()
			assert_nil(siblings.store_key(SITE_KEY, path, run), "unchanged: not rewritten")
			assert_eq(#cmds, 1, "no second write")
			assert_eq(siblings.store_key(nil, path, run), "removed", "no key: removed")
			assert_nil(io.open(path, "r"), "gone")
		end
	},
}
