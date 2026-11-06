--[[
	The controller's nightly dfs-reset (`syswrapper.sh dfs-reset`).

	The controller pushes it as a 02:00 cron job to every AP with a 5 GHz radio
	pinned to a DFS channel (PROTOCOL-VALIDATION.md, "dfs-reset"). What it is
	for: a radar hit takes the radio off that channel and nothing brings it
	back, so the planned cell quietly stays on whatever channel the driver
	picked until the next Force Provision.

	U7LR 6.8.2's own dfs_reset is the model, verb for verb: for each 5 GHz
	radio, compare the live channel with the configured one, skip `auto` and
	`0`, skip when they agree, skip while the configured channel is still on the
	non-occupancy list ("still in nol_channel, wait next time"), and otherwise
	put the radio back. The firmware uses `radartool chknol` and `iwconfig
	channel`; the equivalents here are mac80211's per-channel DFS state
	(`iw phy phyN channels`) and a channel switch announcement through hostapd's
	control socket, rebuilt at the live operating width. A CSA rather than a
	`wifi reload`: the BSS is never torn down and associated clients are told
	where it is going. UCI is never written; it already holds the configured
	channel, which is what makes this a reset and not a change.

	The hook (hook/syswrapper.lua) only leaves a dated request file, as 11k-scan
	does: the daemon owns the radios' netdev names, the live channel and the
	control sockets. hostapd accepting the switch is not the radio arriving, and
	arriving on a DFS channel takes a CAC of a minute or ten, so each switch is
	read back on later heartbeats and logged as arrived or not.
]]--

local rrmscan = require("openwrt.rrmscan")

local M = {}

M._read_file = function(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
M._remove = os.remove
M._run_cmd = function(cmd)
	local p = io.popen(cmd)
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end

M.REQUEST_FILE = "/tmp/openuf-dfs-reset-request"
-- A request the daemon never saw (it was down, or the whole AP was) is not
-- carried out hours later, when the clock has moved on and the controller
-- would schedule a fresh one the next night anyway.
M.MAX_AGE = 1800
-- How long a switch hostapd accepted may take to show: the announcement
-- counts down CS_COUNT beacons, then the CAC on a DFS channel runs 60 s, or
-- 600 s on the weather-radar channels (120-128).
M.ARRIVE_WAIT = 900

-- Channels that can carry a radar hit: the whole 52-144 span rather than one
-- regulatory domain's subset, since a channel the domain forbids is never in
-- use.
function M.is_dfs_channel(ch)
	ch = tonumber(ch)
	return (ch ~= nil) and ch >= 52 and ch <= 144
end

-- Per-channel DFS state out of `iw phy phyN channels` (sysinfo.phy_channels).
-- mac80211 keeps the regulatory state machine per channel and `iw` prints it
-- under each channel's entry:
--
--   * 5500 MHz [100]
--     Maximum TX power: 26.0 dBm
--     Radar detection
--     Channel widths: 20MHz HT40+ VHT80 VHT160
--     DFS state: available (for 349821 sec)
--     DFS CAC time: 60000 ms
--
-- The three states are `usable` (CAC not done), `available` (CAC done, may
-- beacon) and `unavailable`, which is the non-occupancy list a radar hit puts
-- the channel on for 30 minutes. This is openUF's equivalent of the `radartool
-- -i <radio> chknol <ch>` the UniFi firmware's dfs_reset consults
-- (firmware-confirmed for U7LR 6.8.2), and the only reason it is consulted:
-- switching back onto a channel still in the NOL is refused by the kernel, and
-- the job simply waits for the next run.
--
-- Channels with no DFS state (the whole 2.4 GHz band, UNII-1, UNII-3) are
-- absent from the table rather than reported as usable, so a caller can tell
-- "not a DFS channel" from "a DFS channel that is free".
function M.parse_states(blob)
	local out = {}
	if type(blob) ~= "string" then return out end
	local ch = nil
	for line in blob:gmatch("[^\n]+") do
		local c = line:match("^%s*%*%s+%d+%s+MHz%s+%[(%d+)%]")
		if c then
			ch = tonumber(c)
		elseif ch then
			local state = line:match("DFS state:%s*(%a+)")
			if state then
				out[ch] = {state = state, secs = tonumber(line:match("%(for%s+(%d+)%s*sec"))}
				ch = nil
			end
		end
	end
	return out
end

-- True when the channel is on the non-occupancy list and must not be switched
-- onto yet. A channel the dump does not mention is not blocked: it has no DFS
-- state, or this driver does not report one, and the switch itself is then the
-- authority.
function M.channel_in_nol(states, ch)
	local s = states and states[tonumber(ch)]
	return (s ~= nil) and s.state == "unavailable"
end

-- How many beacons the CSA counts down before the switch. Five is hostapd's
-- own default for a user-requested switch and a little over half a second at
-- the usual 100 TU beacon interval.
M.CS_COUNT = 5

-- The centre channel of every bonded 5 GHz block, in IEEE's own numbering.
-- A table rather than arithmetic because the blocks are NOT evenly spaced:
-- UNII-3 starts at 149, which is not 36 + 16k, so an anchor-on-36 formula puts
-- the 149-161 block's centre one channel (5 MHz) too low -- a center_freq1
-- hostapd accepts and then beacons a shifted operation element with.
M.BLOCK_CENTERS = {
	[40]  = {38, 46, 54, 62, 102, 110, 118, 126, 134, 142, 151, 159},
	[80]  = {42, 58, 74, 90, 106, 122, 138, 155},
	[160] = {50, 114, 163},
}

-- The centre channel of the `width` MHz block holding `ch`, or nil when the
-- channel is in none (165 at 40 MHz: it has no partner).
function M.block_center(ch, width)
	local centers = M.BLOCK_CENTERS[width]
	if not centers then return nil end
	-- Half the block, in channel numbers: 2 either side at 40 MHz, 6 at
	-- 80 MHz, 14 at 160 MHz.
	local reach = width / 10 - 2
	for _, c in ipairs(centers) do
		if ch >= c - reach and ch <= c + reach then return c end
	end
	return nil
end

-- The highest 802.11 mode the BSS runs, as the token `chan_switch` takes, from
-- `hostapd_cli status` (ieee80211n/ac/ax/be=0|1 of the interface): "eht", "he",
-- "vht", "ht", or "" for a legacy BSS. nil when the dump carries none of the
-- keys, which is an unreadable BSS and not a legacy one.
--
-- The token is not optional. A switch onto a DFS channel (the only kind this
-- job makes) takes hostapd's fallback path: it copies the command's ht/vht/he/
-- eht flags into the interface config, disables and re-enables the interface,
-- and a mode the command did not name comes back OFF (hostapd 2.11
-- hostapd_switch_channel_fallback: `ieee80211ax = freq_params->he_enabled`).
-- Naming vht on an HE radio would put it back on the air without 802.11ax
-- until the next wifi reload. The daemon's usage line lists `he` and `eht`
-- (the help of hostapd_cli does not); "he" implies vht and ht, "eht" all
-- three (hostapd_ctrl_check_freq_params), so one token is enough.
function M.mode_token(status)
	if type(status) ~= "string" then return nil end
	status = "\n" .. status
	local seen = false
	local token = ""
	for _, m in ipairs({{"ieee80211n", "ht"}, {"ieee80211ac", "vht"},
			{"ieee80211ax", "he"}, {"ieee80211be", "eht"}}) do
		if status:find("\n" .. m[1] .. "=", 1, true) then seen = true end
		if status:find("\n" .. m[1] .. "=1\n", 1, true) then token = m[2] end
	end
	return seen and token or nil
end

-- The arguments for `hostapd_cli chan_switch <count> ...` that put a 5 GHz BSS
-- on channel `ch` at `width` MHz in `mode` (mode_token), or nil when the pair
-- cannot be expressed.
--
-- Grammar, from hostapd 2.12 (OpenWrt 25.12): chan_switch <cs_count> <freq>
-- [sec_channel_offset=] [center_freq1=] [center_freq2=] [bandwidth=] [blocktx]
-- [ht|vht|he|eht].
function M.chan_switch_args(ch, width, mode)
	ch, width = tonumber(ch), tonumber(width) or 20
	if not ch or ch < 32 then return nil end
	local freq = rrmscan.freq_of_channel(ch)
	if not freq then return nil end
	local tail = (mode and mode ~= "") and (" " .. mode) or ""
	if width == 20 then return tostring(freq) .. tail end

	local center = M.block_center(ch, width)
	if not center then return nil end
	-- Which side of the primary its 40 MHz partner sits on: the pairs are
	-- (36,40), (44,48), ..., so the lower member takes its secondary above it.
	-- Derived from the 40 MHz block's own centre, which keeps UNII-3 right too.
	local pair = M.block_center(ch, 40)
	if not pair then return nil end
	return table.concat({
		tostring(freq),
		"sec_channel_offset=" .. (ch < pair and 1 or -1),
		"center_freq1=" .. rrmscan.freq_of_channel(center),
		"bandwidth=" .. width,
	}, " ") .. tail
end

-- True when the hook left a request that is still fresh. The file is removed
-- either way, so one request is served at most once.
function M.requested(now)
	local raw = M._read_file(M.REQUEST_FILE)
	if not raw then return false end
	M._remove(M.REQUEST_FILE)
	local at = tonumber(raw:match("%d+"))
	if not at then return false end
	local late = now - at
	if late > M.MAX_AGE or late < -60 then
		io.stderr:write("inform: ignoring a stale dfs-reset request\n")
		return false
	end
	return true
end

-- ifname -> {want, from, at}: switches hostapd accepted, not yet seen to land.
M._pending = {}

-- One radio: put it back on its configured channel if it is somewhere else and
-- allowed to be there. Returns "moved", or nil plus the reason it was left
-- alone. si: the sysinfo reads, injectable.
function M.reset_radio(now, radio, ifname, si)
	local want = tonumber(radio.channel)
	if not want then return nil, "channel is not pinned" end

	local op = si.operating(ifname)
	local live = op and op.channel
	if not live then return nil, "no live channel" end
	-- radio.radio is "na" for 6 GHz too, whose channel numbers overlap 5 GHz's.
	if (op.freq or 0) > 5895 then return nil, "not a 5 GHz radio" end
	if live == want then return nil, nil end

	if M.is_dfs_channel(want) then
		local states = M.parse_states(si.phy_channels(ifname))
		if M.channel_in_nol(states, want) then
			local s = states[want] or {}
			io.stderr:write(("inform: dfs-reset: %s is on channel %d, wants %d,"
				.. " but %d is still on the non-occupancy list%s -- waiting for"
				.. " the next run\n"):format(ifname, live, want, want,
				s.secs and (" for another " .. s.secs .. " s") or ""))
			return nil, "in the non-occupancy list"
		end
	end

	local mode = M.mode_token(M._run_cmd("hostapd_cli -i " .. ifname .. " status 2>&1"))
	if not mode then
		io.stderr:write(("inform: dfs-reset: %s: cannot read the BSS's 802.11 modes"
			.. " from hostapd -- leaving it on %d\n"):format(ifname, live))
		return nil, "hostapd status unreadable"
	end
	local args = M.chan_switch_args(want, op.width, mode)
	if not args then
		io.stderr:write(("inform: dfs-reset: %s: cannot express channel %d at %s"
			.. " MHz as a channel switch -- leaving it on %d\n")
			:format(ifname, want, tostring(op.width), live))
		return nil, "not expressible as a channel switch"
	end
	local out = M._run_cmd("hostapd_cli -i " .. ifname .. " chan_switch "
		.. M.CS_COUNT .. " " .. args .. " 2>&1") or ""
	-- hostapd_cli prints OK or FAIL and exits 0 either way.
	if not out:find("OK", 1, true) then
		io.stderr:write(("inform: dfs-reset: %s: hostapd refused the switch to"
			.. " channel %d (%s): %s\n"):format(ifname, want, args,
			(out:gsub("%s+$", ""))))
		return nil, "hostapd refused the switch"
	end
	io.stderr:write(("inform: dfs-reset: %s switching back from channel %d to"
		.. " the configured %d (%s)\n"):format(ifname, live, want, args))
	M._pending[ifname] = {want = want, from = live, at = now}
	return "moved"
end

-- Read back the switches hostapd accepted: log the ones that landed, and the
-- ones still elsewhere after ARRIVE_WAIT. Returns how many landed.
function M.verify(now, si)
	local landed = 0
	for ifname, p in pairs(M._pending) do
		local op = si.operating(ifname)
		if op and op.channel == p.want then
			io.stderr:write(("inform: dfs-reset: %s is back on channel %d\n")
				:format(ifname, p.want))
			M._pending[ifname] = nil
			landed = landed + 1
		elseif now - p.at > M.ARRIVE_WAIT then
			io.stderr:write(("inform: dfs-reset: %s accepted the switch to channel"
				.. " %d but is on %s %d s later\n"):format(ifname, p.want,
				op and ("channel " .. op.channel) or "no channel", now - p.at))
			M._pending[ifname] = nil
		end
	end
	return landed
end

-- One heartbeat. hwassign: the radios the daemon reports (dev.conf.hwassign);
-- ufuci, si: ucihelper and sysinfo. Returns how many radios were moved.
function M.tick(now, hwassign, ufuci, si)
	if next(M._pending) then M.verify(now, si) end
	if not M.requested(now) then return 0 end
	if not (ufuci and si and si.phy_channels and si.operating) then return 0 end
	local ok_r, radios = pcall(ufuci.get_radio_table, hwassign)
	if not ok_r or type(radios) ~= "table" then return 0 end
	-- The firmware skips a downlink AP (is_wds): it follows its parent's
	-- channel. A radio carrying the wireless uplink station is that here, and
	-- moving its AP would cut the uplink.
	local uplink = {}
	local ok_u, secs = pcall(ufuci.backhaul_uplink_sections or function() return {} end)
	for _, sec in ipairs(ok_u and secs or {}) do
		if not sec.disabled then uplink[sec.radio] = true end
	end
	local moved = 0
	for _, radio in ipairs(radios) do
		-- 5 GHz only, as the firmware's own list_first_vaps_ifs 5 does: no
		-- other band has DFS, so no other band can have been pushed off a
		-- channel by radar.
		if radio.radio == "na" and not radio.disabled and not uplink[radio.name] then
			local ok_i, ifname = pcall(ufuci.get_ifname_for_radio, radio.name)
			if ok_i and ifname then
				local ok_m, what = pcall(M.reset_radio, now, radio, ifname, si)
				if ok_m and what == "moved" then moved = moved + 1 end
			end
		end
	end
	return moved
end

return M
