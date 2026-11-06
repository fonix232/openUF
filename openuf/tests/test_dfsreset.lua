-- Tests for src/openwrt/dfsreset.lua (the controller's nightly dfs-reset) and
-- the sysinfo reads it uses. Run from project root: lua tests/run_tests.lua

local dfs = dofile("src/openwrt/dfsreset.lua")
local sysinfo = dofile("src/openwrt/sysinfo.lua")

local function quiet(fn)
	local said, real = {}, io.stderr
	io.stderr = {write = function(_, s) said[#said + 1] = s end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(said)
end

return {
	{
		name = "dfsreset: parse_states reads the per-channel DFS state machine",
		fn = function()
			-- The shape of `iw phy phy1 channels` on an AX3000T (OpenWrt 25.12,
			-- mt76), one channel on the non-occupancy list by hand: the state
			-- no live read can be made to show on demand.
			local blob = table.concat({
				"Band 2:",
				"\t* 5180 MHz [36] ",
				"\t  Maximum TX power: 23.0 dBm",
				"\t  Channel widths: 20MHz HT40+ VHT80 VHT160",
				"\t* 5500 MHz [100] ",
				"\t  Maximum TX power: 26.0 dBm",
				"\t  Radar detection",
				"\t  DFS state: available (for 349821 sec)",
				"\t  DFS CAC time: 60000 ms",
				"\t* 5520 MHz [104] ",
				"\t  Radar detection",
				"\t  DFS state: unavailable (for 1766 sec)",
				"\t* 5540 MHz [108] ",
				"\t  Radar detection",
				"\t  DFS state: usable (for 0 sec)",
			}, "\n") .. "\n"
			local s = dfs.parse_states(blob)
			assert_eq(s[100].state, "available", "CAC done")
			assert_eq(s[100].secs, 349821, "and for how long")
			assert_eq(s[104].state, "unavailable", "on the NOL after a radar hit")
			assert_eq(s[104].secs, 1766, "with 1766 s left")
			assert_eq(s[108].state, "usable", "awaiting CAC")
			assert_nil(s[36], "36 has no DFS state: absent, not claimed free")
			assert_true(dfs.channel_in_nol(s, 104), "104 is blocked")
			assert_true(dfs.channel_in_nol(s, "104"), "a string channel")
			assert_false(dfs.channel_in_nol(s, 100), "100 is not")
			assert_false(dfs.channel_in_nol(s, 108), "CAC pending is not the NOL")
			assert_false(dfs.channel_in_nol(s, 36), "no state, not blocked")
			assert_false(dfs.channel_in_nol(nil, 100), "no dump at all")
			assert_nil(next(dfs.parse_states(nil)), "no blob")
			assert_nil(next(dfs.parse_states("")), "empty blob")
		end
	},
	{
		name = "dfsreset: chan_switch_args rebuilds a CSA for each 5 GHz width, naming the BSS's own mode",
		fn = function()
			local A = dfs.chan_switch_args
			assert_eq(A(100, 80, "he"), "5500 sec_channel_offset=1 center_freq1=5530 bandwidth=80 he", "100 at 80")
			assert_eq(A(104, 80, "he"), "5520 sec_channel_offset=-1 center_freq1=5530 bandwidth=80 he",
				"104 is the upper half of its pair; the 80 MHz centre is unchanged")
			assert_eq(A(36, 80, "vht"), "5180 sec_channel_offset=1 center_freq1=5210 bandwidth=80 vht", "36 at 80")
			assert_eq(A(149, 80, "vht"), "5745 sec_channel_offset=1 center_freq1=5775 bandwidth=80 vht",
				"the UNII-3 block anchors on 149")
			assert_eq(A(100, 160, "eht"), "5500 sec_channel_offset=1 center_freq1=5570 bandwidth=160 eht", "160 spans 100-128")
			assert_eq(A(100, 40, "ht"), "5500 sec_channel_offset=1 center_freq1=5510 bandwidth=40 ht", "40")
			assert_eq(A(104, 40, "ht"), "5520 sec_channel_offset=-1 center_freq1=5510 bandwidth=40 ht", "the other side")
			assert_eq(A(100, 20, "he"), "5500 he", "20 MHz is the frequency and the mode: a 20 MHz HE BSS must stay HE")
			assert_eq(A(100, nil, "ht"), "5500 ht", "unknown width reads as 20")
			assert_eq(A(100, 80, ""), "5500 sec_channel_offset=1 center_freq1=5530 bandwidth=80", "a legacy BSS names none")
			assert_nil(A(165, 40, "ht"), "165 has no 40 MHz partner")
			assert_nil(A(165, 80, "he"), "nor an 80 MHz block")
			assert_eq(A(165, 20, "he"), "5825 he", "but is a good 20 MHz channel")
			assert_eq(dfs.block_center(149, 80), 155, "155, not the 154 an anchor-on-36 formula gives")
			assert_nil(A(11, 80, "he"), "2.4 GHz is not 5 GHz")
			assert_nil(A(100, 60, "he"), "not a width hostapd knows")
			assert_nil(A("auto", 80, "he"), "auto is not a channel")
			assert_nil(A(nil, 80, "he"), "nil")
		end
	},
	{
		name = "dfsreset: mode_token is the highest mode `hostapd_cli status` says the BSS runs",
		fn = function()
			local function status(n, ac, ax, be)
				return "state=ENABLED\nchannel=100\nsecondary_channel=1\nieee80211n=" .. n
					.. "\nieee80211ac=" .. ac .. "\nieee80211ax=" .. ax .. "\nieee80211be=" .. be .. "\nbeacon_int=100\n"
			end
			assert_eq(dfs.mode_token(status(1, 1, 1, 0)), "he", "an HE BSS")
			assert_eq(dfs.mode_token(status(1, 1, 1, 1)), "eht", "an EHT BSS")
			assert_eq(dfs.mode_token(status(1, 1, 0, 0)), "vht", "a VHT BSS")
			assert_eq(dfs.mode_token(status(1, 0, 0, 0)), "ht", "an HT BSS")
			assert_eq(dfs.mode_token(status(0, 0, 0, 0)), "", "a legacy BSS")
			assert_nil(dfs.mode_token("Failed to connect to hostapd\n"), "no hostapd: unreadable, not legacy")
			assert_nil(dfs.mode_token(nil), "nothing")
		end
	},
	{
		name = "dfsreset: is_dfs_channel covers 52-144 only",
		fn = function()
			assert_true(dfs.is_dfs_channel(52), "52")
			assert_true(dfs.is_dfs_channel("100"), "100 as a string")
			assert_true(dfs.is_dfs_channel(144), "144")
			assert_false(dfs.is_dfs_channel(48), "48")
			assert_false(dfs.is_dfs_channel(149), "149")
			assert_false(dfs.is_dfs_channel("auto"), "auto")
		end
	},
	{
		name = "dfsreset: a request is served once, and a stale or future-dated one is not served",
		fn = function()
			local orig = {r = dfs._read_file, rm = dfs._remove}
			local file, removed = nil, 0
			dfs._read_file = function(p) assert_eq(p, dfs.REQUEST_FILE, "the request file") return file end
			dfs._remove = function() removed = removed + 1 end
			local ok, err = pcall(function()
				assert_false(dfs.requested(1000000), "no file")
				assert_eq(removed, 0, "nothing to remove")
				file = "1000000\n"
				assert_true(dfs.requested(1000000), "fresh")
				assert_eq(removed, 1, "and consumed")
				file = tostring(1000000 - dfs.MAX_AGE - 1) .. "\n"
				local said = quiet(function() assert_false(dfs.requested(1000000), "stale") end)
				assert_contains(said, "stale dfs-reset request", "said so")
				assert_eq(removed, 2, "still removed")
				file = "1003600\n"
				quiet(function() assert_false(dfs.requested(1000000), "an hour ahead: the clock moved") end)
				file = "junk\n"
				assert_false(dfs.requested(1000000), "no timestamp")
			end)
			dfs._read_file, dfs._remove = orig.r, orig.rm
			if not ok then error(err, 0) end
		end
	},
	{
		name = "dfsreset: tick moves only a 5 GHz radio that is off its pinned channel, and reads the switch back",
		fn = function()
			local orig = {read = dfs._read_file, rm = dfs._remove, run = dfs._run_cmd}
			local cmds, request = {}, nil
			-- The AX3000T's layout: 2.4 on radio0, the DFS 5 GHz on radio1.
			local live, width, nol, freq = 36, 80, nil, 5180
			local radios = {
				{name = "radio0", radio = "ng", channel = 11},
				{name = "radio1", radio = "na", channel = 100},
			}
			local ufuci = {
				get_radio_table = function() return radios end,
				get_ifname_for_radio = function(r) return r == "radio0" and "phy0-ap0" or "phy1-ap0" end,
			}
			local si = {
				operating = function(ifname)
					if ifname == "phy1-ap0" then return {channel = live, width = width, freq = freq} end
					-- Off its pinned channel too (1, configured 11): only the
					-- band gate keeps it out of the job.
					return {channel = 1, width = 20, freq = 2412}
				end,
				phy_channels = function()
					return "\t* 5500 MHz [100] \n\t  Radar detection\n\t  DFS state: "
						.. (nol and "unavailable (for 1766 sec)" or "available (for 86400 sec)") .. "\n"
				end,
			}
			dfs._read_file = function() return request end
			dfs._remove = function() request = nil end
			local STATUS = "state=ENABLED\nieee80211n=1\nieee80211ac=1\nieee80211ax=1\nieee80211be=0\n"
			local cs_reply = "OK\n"
			dfs._run_cmd = function(c)
				if c:find(" status", 1, true) then return STATUS end
				cmds[#cmds + 1] = c
				return cs_reply
			end
			dfs._pending = {}
			local ok, err = pcall(function()
				assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "no request, no work")
				assert_eq(#cmds, 0, "and no command")

				request = "1000000\n"
				local said = quiet(function() assert_eq(dfs.tick(1000000, nil, ufuci, si), 1, "one radio moved") end)
				assert_eq(#cmds, 1, "one command")
				assert_contains(cmds[1], "hostapd_cli -i phy1-ap0 chan_switch 5 "
					.. "5500 sec_channel_offset=1 center_freq1=5530 bandwidth=80 he",
					"a CSA back to the configured channel, at the live width, still HE")
				assert_contains(said, "switching back from channel 36 to the configured 100", "says what it did")
				assert_nil(said:find("phy0%-ap0"), "the 2.4 radio is never touched")

				-- Accepted is not arrived: the next heartbeats read it back.
				said = quiet(function() dfs.tick(1000010, nil, ufuci, si) end)
				assert_eq(said, "", "still on 36 inside the wait: nothing said")
				live, freq = 100, 5500
				said = quiet(function() dfs.tick(1000070, nil, ufuci, si) end)
				assert_contains(said, "phy1-ap0 is back on channel 100", "arrival confirmed")
				assert_nil(next(dfs._pending), "and no longer pending")

				-- A switch that never lands is reported, once.
				live, freq, cmds = 36, 5180, {}
				request = "1000100\n"
				quiet(function() dfs.tick(1000100, nil, ufuci, si) end)
				said = quiet(function() dfs.tick(1000100 + dfs.ARRIVE_WAIT + 1, nil, ufuci, si) end)
				assert_contains(said, "accepted the switch to channel 100 but is on channel 36", "not arrived")
				assert_eq(quiet(function() dfs.tick(1000100 + dfs.ARRIVE_WAIT + 9, nil, ufuci, si) end), "", "said once")

				-- Already there.
				cmds, live, freq = {}, 100, 5500
				request = "1000000\n"
				assert_eq(quiet(function() dfs.tick(1000000, nil, ufuci, si) end), "", "silent")
				assert_eq(#cmds, 0, "no switch when the channel agrees")

				-- Still on the non-occupancy list: wait, do not ask hostapd.
				cmds, live, freq, nol = {}, 36, 5180, true
				request = "1000000\n"
				said = quiet(function() assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "left alone") end)
				assert_eq(#cmds, 0, "no switch attempted")
				assert_contains(said, "still on the non-occupancy list for another 1766 s", "the reason and the time left")

				-- hostapd refusing is reported, not counted.
				cmds, nol = {}, nil
				cs_reply = "FAIL\n"
				request = "1000000\n"
				said = quiet(function() assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "not moved") end)
				assert_contains(said, "hostapd refused the switch", "logged")
				assert_nil(next(dfs._pending), "and nothing to read back")
				cs_reply = "OK\n"

				-- No readable mode, no switch: a CSA that names none would
				-- bring the BSS back without 802.11n/ac/ax.
				cmds = {}
				STATUS = "Failed to connect to hostapd\n"
				request = "1000000\n"
				said = quiet(function() assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "left alone") end)
				assert_eq(#cmds, 0, "no switch attempted")
				assert_contains(said, "cannot read the BSS's 802.11 modes", "and said why")
				STATUS = "state=ENABLED\nieee80211n=1\nieee80211ac=1\nieee80211ax=1\nieee80211be=0\n"

				-- An unpinned radio is left to the driver, silently.
				cmds = {}
				radios = {{name = "radio1", radio = "na", channel = "auto"}}
				request = "1000000\n"
				assert_eq(quiet(function() assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "auto is not pinned") end), "", "silent")
				assert_eq(#cmds, 0, "no switch")
				local _, why = dfs.reset_radio(1000000, {channel = "auto"}, "phy1-ap0", si)
				assert_eq(why, "channel is not pinned", "refused before anything reads the radio")

				-- A radio the controller turned off is not woken up.
				radios = {{name = "radio1", radio = "na", channel = 100, disabled = true}}
				request = "1000000\n"
				assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "disabled is skipped")
				assert_eq(#cmds, 0, "no switch")

				-- A radio carrying the wireless uplink station follows its
				-- parent's channel (the firmware's is_wds skip).
				radios = {{name = "radio1", radio = "na", channel = 100}}
				ufuci.backhaul_uplink_sections = function()
					return {{name = "openuf_bh_ul_radio1", radio = "radio1", disabled = false}}
				end
				request = "1000000\n"
				assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "an uplink radio is skipped")
				assert_eq(#cmds, 0, "no switch")
				ufuci.backhaul_uplink_sections = function()
					return {{name = "openuf_bh_ul_radio1", radio = "radio1", disabled = true}}
				end
				request = "1000000\n"
				assert_eq(dfs.tick(1000000, nil, ufuci, si), 1, "a switched-off uplink does not count")
				ufuci.backhaul_uplink_sections = nil
				dfs._pending = {}
				cmds = {}

				-- A 6 GHz radio reads "na" too, and its channel numbers overlap
				-- 5 GHz's: it is never switched with a 5 GHz frequency.
				radios = {{name = "radio1", radio = "na", channel = 37}}
				live, freq = 5, 5955
				request = "1000000\n"
				assert_eq(dfs.tick(1000000, nil, ufuci, si), 0, "6 GHz is skipped")
				assert_eq(#cmds, 0, "no switch")
			end)
			dfs._read_file, dfs._remove, dfs._run_cmd = orig.read, orig.rm, orig.run
			dfs._pending = {}
			if not ok then error(err, 0) end
		end
	},
	{
		name = "sysinfo: operating reads the live channel, frequency and width; phy_channels asks iw for the radio's phy",
		fn = function()
			local orig = sysinfo._run_cmd
			local cmds = {}
			sysinfo._run_cmd = function(c)
				cmds[#cmds + 1] = c
				if c:find("iw dev phy1-ap0 info", 1, true) then
					return "Interface phy1-ap0\n\tifindex 9\n\twiphy 1\n\ttype AP\n"
						.. "\tchannel 100 (5500 MHz), width: 80 MHz, center1: 5530 MHz\n\ttxpower 23.00 dBm\n"
				end
				if c:find("iw dev phy2-ap0 info", 1, true) then return "Interface phy2-ap0\n\twiphy 2\n\ttype AP\n" end
				if c:find("iw phy phy1 channels", 1, true) then return "Band 2:\n\t* 5500 MHz [100]\n" end
				return ""
			end
			local ok, err = pcall(function()
				local op = sysinfo.operating("phy1-ap0")
				assert_eq(op.channel, 100, "channel")
				assert_eq(op.freq, 5500, "frequency")
				assert_eq(op.width, 80, "width")
				assert_nil(sysinfo.operating("phy2-ap0"), "an interface on no channel")
				assert_nil(sysinfo.operating(nil), "no interface")
				assert_contains(sysinfo.phy_channels("phy1-ap0"), "[100]", "the phy's channel dump")
				assert_contains(cmds[#cmds], "iw phy phy1 channels", "for the interface's phy")
				assert_nil(sysinfo.phy_channels("nope"), "an unknown interface")
			end)
			sysinfo._run_cmd = orig
			if not ok then error(err, 0) end
		end
	},
}
