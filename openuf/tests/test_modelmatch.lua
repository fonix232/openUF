-- Tests for src/modelmatch.lua against the generated catalogue.
-- Run from project root: lua tests/run_tests.lua

local match   = dofile("src/modelmatch.lua")
local catalog = dofile("src/ufmodel/catalog.lua")

-- /etc/board.json as board.d wrote it on the two real APs this was built for.
local E8450 = {   -- Linksys E8450: MT7622 2.4 GHz 4x4 n, MT7915 5 GHz 4x4 HE160, 4 LAN + WAN
	network = {lan = {ports = {"lan1", "lan2", "lan3", "lan4"}}, wan = {device = "wan"}},
	wlan = {
		wl0 = {info = {antenna_tx = 15, bands = {["2G"] = {ht = true, max_width = 40}}}},
		wl1 = {info = {antenna_tx = 15, bands = {["5G"] = {ht = true, vht = true, he = true, max_width = 160}}}},
		wl2 = {},
	},
}
local WAX220 = {  -- Netgear WAX220: MT7986 2.4 GHz 2x2 HE40, 5 GHz 3x3 HE160, one socket
	network = {lan = {device = "eth0"}},
	wlan = {
		phy0 = {info = {antenna_tx = 3, bands = {["2G"] = {ht = true, he = true, max_width = 40}}}},
		phy1 = {info = {antenna_tx = 7, bands = {["5G"] = {ht = true, vht = true, he = true, max_width = 160}}}},
	},
}
local ARCHER_C7 = {  -- ath79 802.11ac wave 2, 4 LAN + WAN
	network = {lan = {ports = {"lan1", "lan2", "lan3", "lan4"}}, wan = {device = "wan"}},
	wlan = {
		phy0 = {info = {antenna_tx = 7, bands = {["2G"] = {ht = true, max_width = 40}}}},
		phy1 = {info = {antenna_tx = 15, bands = {["5G"] = {ht = true, vht = true, max_width = 80}}}},
	},
}

return {
	{
		name = "modelmatch: facts come from board.json's wlan and network sections",
		fn = function()
			local f = match.facts(E8450)
			assert_eq(f.sockets, 5, "five sockets")
			assert_eq(f.gen, "ax", "best radio is WiFi 6")
			assert_eq(f.bands.ng.gen, "n", "the 2.4 GHz radio is 802.11n")
			assert_eq(f.bands.ng.nss, 4, "4x4")
			assert_eq(f.bands.na.speed, 4 * 1201, "4x4 HE160")
			assert_nil(match.facts({network = {}}), "no radio info, no facts")
		end
	},
	{
		name = "modelmatch: a 5-socket dual-band WiFi 6 board is a U6 In-Wall",
		fn = function()
			local m = match.best(catalog, match.facts(E8450))
			assert_eq(m.model, "U6IW", "switch model, five ports")
			local id = match.identity(m)
			assert_eq(id.sysid, 0xa652, "sysid from the registry")
			assert_eq(id.uplink_idx, 5, "uplink on the last port")
			assert_true(id.fw.ver:match("^%d+%.%d+%.%d+%.%d+$") ~= nil, "catalogue firmware version")
		end
	},
	{
		name = "modelmatch: a one-socket WiFi 6 board is a plain ceiling AP with its uplink on port 1",
		fn = function()
			local m = match.best(catalog, match.facts(WAX220))
			assert_eq(m.model, "UAP6MP", "U6-Pro")
			assert_false(m.switch, "no switch")
			assert_eq(m.ports, 1, "one port")
			assert_eq(m.gen, "ax", "WiFi 6")
			assert_false(m.outdoor, "indoor")
			assert_false(m.mesh, "not a mesh unit")
			assert_eq(match.identity(m).uplink_idx, 1, "uplink port 1")
		end
	},
	{
		name = "modelmatch: an 802.11ac board is matched to an 802.11ac identity",
		fn = function()
			local m = match.best(catalog, match.facts(ARCHER_C7))
			assert_eq(m.model, "UHDIW", "UAP-IW-HD")
			assert_eq(m.gen, "ac", "no WiFi 6 menus for an ac radio")
			assert_true(m.switch, "multi-socket board, switch model")
		end
	},
	{
		name = "modelmatch: the band set outweighs everything else",
		fn = function()
			local f = {bands = {na = {gen = "ac", speed = 1733}}, gen = "ac", sockets = 1}
			local m = match.best(catalog, f)
			assert_eq(#m.bands, 1, "a single-band board gets a single-band model")
			assert_eq(m.bands[1], "na", "5 GHz")
		end
	},
	{
		name = "modelmatch: every catalogue entry is usable as an identity",
		fn = function()
			assert_true(#catalog.models > 50, "the registry's access points")
			for _, m in ipairs(catalog.models) do
				local id = match.identity(m)
				assert_true(type(id.model) == "string" and id.model ~= "", "model code")
				assert_true(type(id.sysid) == "number", "sysid " .. id.model)
				assert_true(id.fw.ver:match("^%d+%.%d+%.%d+%.%d+$") ~= nil, "version " .. id.model)
			end
		end
	},
}
