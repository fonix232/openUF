--[[
	Off-channel scans on radios nobody is using.

	A radio only hears beacons on the channel it serves, and sibling APs are
	on other channels by design, so the passive cache almost never holds one
	(rrmscan.lua). A sweep (`iw dev <if> scan ap-force`) hears every channel,
	and siblings answer it with probe responses carrying the vendor element
	sysinfo.peer_ie_hex tags them by. But a sweep takes the radio off its
	channel for seconds: on an Archer C5 it cost an associated client 12% of
	its packets. So it runs only on a radio with no client on any of its
	interfaces, at most every idle_scan_interval seconds, in the background so
	the heartbeat does not wait for it.

	The controller keeps a sibling sighting for an hour (10.6.106 aS
	peer-scan-cache, expireAfterWrite 3600 s), so the default half hour keeps
	a pair of idle siblings listed as neighbours.

	A radio that always has a client (every radio of a busy home network)
	would never be swept. For those there is the sibling scan: siblings
	announce the frequency of every BSSID (siblings.lua), so the radio listens
	only on those, in its own band and not its own channel: one or two
	channels for a fraction of a second, against the multi-second sweep. It
	runs with clients associated, at most every sibling_scan_interval.
]]--

local M = {}

-- A radio that had clients is looked at again after this long.
M.RETRY = 60

M._run_cmd = function(cmd)
	local p = io.popen(cmd .. " 2>/dev/null")
	if not p then return "" end
	local out = p:read("*a") or ""
	p:close()
	return out
end

M._spawn = function(cmd)
	os.execute(cmd .. " >/dev/null 2>&1 &")
end

-- {{phy = "phy#0", ifaces = {ap ifname, ...}, freq = MHz or nil}, ...}
-- from `iw dev` output. Only AP interfaces: a scan runs on one of them, and
-- only their clients count. freq is the radio's operating frequency.
function M.radios(iw_dev)
	local out, cur, ifname = {}, nil, nil
	for line in (iw_dev or ""):gmatch("[^\n]+") do
		local phy = line:match("^(phy#%d+)")
		if phy then
			cur = {phy = phy, ifaces = {}}
			out[#out + 1] = cur
			ifname = nil
		else
			local i = line:match("^%s*Interface (%S+)")
			if i then ifname = i end
			if cur and ifname and line:match("^%s*type AP%s*$") then
				cur.ifaces[#cur.ifaces + 1] = ifname
			end
			local f = line:match("^%s*channel %d+ %((%d+) MHz%)")
			if cur and f and not cur.freq then cur.freq = tonumber(f) end
		end
	end
	local radios = {}
	for _, r in ipairs(out) do
		if #r.ifaces > 0 then radios[#radios + 1] = r end
	end
	return radios
end

-- 2.4, 5 or 6 (GHz) for a frequency in MHz.
function M.band(freq)
	if not freq then return nil end
	if freq < 3000 then return 2 end
	if freq <= 5925 then return 5 end
	return 6
end

-- The sibling frequencies worth listening on from a radio on own_freq: same
-- band, not its own channel, at most M.MAX_SIBLING_FREQS.
M.MAX_SIBLING_FREQS = 3
function M.sibling_freqs(own_freq, freqs)
	local out, band = {}, M.band(own_freq)
	for _, f in ipairs(freqs or {}) do
		if band and M.band(f) == band and f ~= own_freq
			and #out < M.MAX_SIBLING_FREQS then
			out[#out + 1] = f
		end
	end
	return out
end

-- Whether any of ifaces has an associated station.
function M.busy(ifaces)
	for _, i in ipairs(ifaces) do
		local dump = "\n" .. M._run_cmd("iw dev " .. i .. " station dump")
		if dump:find("\nStation ") then return true end
	end
	return false
end

-- One heartbeat. next_at: {key = time}, kept by the caller across calls.
-- interval: seconds between full sweeps of an idle radio (0/nil = never).
-- opts.sibling_interval: seconds between sibling scans (0/nil = never);
-- opts.sibling_freqs: the frequencies siblings announced.
-- Returns the commands started.
function M.tick(next_at, now, interval, opts)
	opts = opts or {}
	local started = {}
	local sib_iv = tonumber(opts.sibling_interval)
	if (not interval or interval <= 0) and (not sib_iv or sib_iv <= 0) then
		return started
	end
	for _, r in ipairs(M.radios(M._run_cmd("iw dev"))) do
		local swept = false
		if interval and interval > 0 and now >= (next_at[r.phy] or 0) then
			if M.busy(r.ifaces) then
				next_at[r.phy] = now + M.RETRY
			else
				local cmd = "iw dev " .. r.ifaces[1] .. " scan ap-force"
				M._spawn(cmd)
				started[#started + 1] = cmd
				next_at[r.phy] = now + interval
				swept = true
			end
		end
		local key = r.phy .. "/siblings"
		if not swept and sib_iv and sib_iv > 0 and now >= (next_at[key] or 0) then
			local freqs = M.sibling_freqs(r.freq, opts.sibling_freqs)
			if #freqs > 0 then
				local cmd = "iw dev " .. r.ifaces[1] .. " scan freq "
					.. table.concat(freqs, " ") .. " ap-force"
				M._spawn(cmd)
				started[#started + 1] = cmd
			end
			next_at[key] = now + sib_iv
		elseif swept and sib_iv and sib_iv > 0 then
			-- A sweep hears the siblings too.
			next_at[key] = now + sib_iv
		end
	end
	return started
end

return M
