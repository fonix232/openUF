-- Tests for src/openwrt/usteer.lua (Band Steering via the usteer daemon).
-- Run from project root: lua tests/run_tests.lua
--
-- Uses the same in-memory mock UCI cursor shape as test_ucihelper.lua
-- (cursor:set/get/commit).

local usteer = dofile("src/openwrt/usteer.lua")

local function new_mock_uci()
	local db = {}  -- db[config][section] = { [".name"]=.., [".type"]=.., key=val, ... }

	local cursor = {}

	function cursor:set(config, section, a, b)
		db[config] = db[config] or {}
		if not db[config][section] then
			db[config][section] = {[".name"] = section}
		end
		if b == nil then
			db[config][section][".type"] = a
		else
			db[config][section][a] = b
		end
	end

	function cursor:get(config, section, option)
		local s = db[config] and db[config][section]
		return s and s[option]
	end

	function cursor:delete(config, section, option)
		local s = db[config] and db[config][section]
		if s then s[option] = nil end
	end

	function cursor:foreach(config, stype, fn)
		local names = {}
		for name, sec in pairs(db[config] or {}) do
			if sec[".type"] == stype then names[#names + 1] = name end
		end
		table.sort(names)
		for _, name in ipairs(names) do fn(db[config][name]) end
	end

	-- Recorded, not applied -- the counter lets tests catch a dropped commit.
	local commits = {}
	function cursor:commit(config)
		commits[config] = (commits[config] or 0) + 1
	end

	return {mock = {cursor = function() return cursor end}, db = db, commits = commits}
end

-- Fresh mock UCI + captured commands for each test.
local function with_usteer(fn)
	local m = new_mock_uci()
	local cmds = {}
	local orig_uci, orig_run = usteer._uci, usteer._run_cmd
	usteer._uci = m.mock
	usteer._locked = nil
	usteer._run_cmd = function(cmd) cmds[#cmds + 1] = cmd; return true end
	local ok, err = pcall(fn, m.db, cmds, m.commits)
	usteer._uci, usteer._run_cmd = orig_uci, orig_run
	if not ok then error(err, 2) end
end

local function cmds_contain(cmds, substr)
	for _, c in ipairs(cmds) do
		if c:find(substr, 1, true) then return true end
	end
	return false
end

return {
	{
		name = "usteer: set_enabled(false) writes interval 0 and stops/disables the daemon",
		fn = function()
			with_usteer(function(db, cmds)
				local ok = usteer.set_enabled(false, nil)
				assert_true(ok, "set_enabled returns true")
				local s = db.usteer["local"]
				assert_eq(s.band_steering_interval, "0", "band steering off")
				assert_eq(s.network, "lan", "defaults network to lan without cfg")
				assert_true(cmds_contain(cmds, "usteer stop"), "stops the daemon")
				assert_true(cmds_contain(cmds, "usteer disable"), "disables the daemon")
			end)
		end
	},
	{
		name = "usteer: set_enabled(true) runs the daemon at its default steering interval",
		fn = function()
			with_usteer(function(db, cmds)
				local ok = usteer.set_enabled(true, nil)
				assert_true(ok, "set_enabled returns true")
				local s = db.usteer["local"]
				-- Unset, not a number of our own: usteer's default interval
				-- is the one that steered a real client (band_steering.c;
				-- 0 is the only value that disables it).
				assert_nil(s.band_steering_interval, "daemon default interval")
				assert_nil(s.band_steering_threshold, "inert threshold not written")
				assert_true(cmds_contain(cmds, "usteer enable"), "enables the daemon")
				assert_true(cmds_contain(cmds, "usteer restart"), "restarts the daemon")
			end)
		end
	},
	{
		name = "usteer: a repeated set_enabled is a no-op (no restart churn)",
		fn = function()
			-- set_enabled runs on every WiFi setparam; before the guard each
			-- steady-state inform restarted the daemon, dropping its learned
			-- station table.
			with_usteer(function(db, cmds, commits)
				assert_true(usteer.set_enabled(true, nil), "first call writes")
				local after_first = #cmds
				assert_eq(commits.usteer, 1, "first call commits")
				assert_true(usteer.set_enabled(true, nil), "second call still reports success")
				assert_eq(#cmds, after_first, "no second enable/restart issued")
				assert_eq(commits.usteer, 1, "steady state issues no further commits")

				usteer.set_enabled(false, nil)
				local after_disable = #cmds
				assert_true(after_disable > after_first, "transition to disabled acts")
				usteer.set_enabled(false, nil)
				assert_eq(#cmds, after_disable, "repeated disable issues no further commands")
			end)
		end
	},
	{
		name = "usteer: Roaming Assistant alone runs the daemon with band steering off",
		fn = function()
			with_usteer(function(db, cmds)
				usteer.set_enabled(false, nil, true)
				local s = db.usteer["local"]
				-- The daemon default steers, so running usteer for Roaming
				-- Assistant without this would band-steer too.
				assert_eq(s.band_steering_interval, "0", "no band steering")
				assert_eq(s.openuf_active, "1", "stamped as running")
				assert_true(cmds_contain(cmds, "usteer restart"), "daemon started")
				assert_false(cmds_contain(cmds, "usteer stop"), "not stopped")
				-- usteer's own device-wide roam trigger stays off: the decision
				-- is roamassist.lua's, per WLAN.
				assert_nil(s.roam_trigger_snr, "no roam_trigger_snr")
				assert_nil(s.signal_diff_threshold, "no signal_diff_threshold")
			end)
		end
	},
	{
		name = "usteer: turning Roaming Assistant off (band steering off) stops the daemon",
		fn = function()
			-- The case an options-only guard would swallow: the interval is
			-- "0" before and after, only the running state moves.
			with_usteer(function(db, cmds)
				usteer.set_enabled(false, nil, true)
				local n = #cmds
				usteer.set_enabled(false, nil, false)
				assert_true(#cmds > n, "acted on the transition")
				assert_true(cmds_contain(cmds, "usteer stop"), "stopped")
				assert_eq(db.usteer["local"].openuf_active, "0", "stamped as stopped")
				local m = #cmds
				usteer.set_enabled(false, nil, false)
				assert_eq(#cmds, m, "steady off is a no-op")
			end)
		end
	},
	{
		name = "usteer: a device configured by an older openUF is rewritten once",
		fn = function()
			with_usteer(function(db, cmds, commits)
				local cursor = usteer._uci.cursor()
				cursor:set("usteer", "local", "usteer")
				cursor:set("usteer", "local", "network", "lan")
				cursor:set("usteer", "local", "band_steering_threshold", "5")
				cursor:set("usteer", "local", "openuf_active", "1")
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 1, "one migration write")
				assert_nil(db.usteer["local"].band_steering_threshold,
					"the threshold the old version wrote is removed")
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 1, "then steady")
			end)
		end
	},
	{
		name = "usteer: set_enabled uses cfg.net.lan_name when present",
		fn = function()
			with_usteer(function(db, cmds)
				usteer.set_enabled(true, {net = {lan_name = "br-lan"}})
				assert_eq(db.usteer["local"].network, "br-lan", "network taken from cfg")
			end)
		end
	},
	{
		name = "usteer: off then on deletes the interval 0 and restarts the daemon",
		fn = function()
			-- On is the absence of the option, so the guard must still see
			-- the change from "0" and act on it.
			with_usteer(function(db, cmds, commits)
				usteer.set_enabled(false, nil)
				local n = #cmds
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 2, "the transition writes")
				assert_nil(db.usteer["local"].band_steering_interval, "interval deleted")
				assert_true(#cmds > n and cmds_contain({cmds[#cmds]}, "usteer restart"),
					"daemon restarted")
			end)
		end
	},
	{
		name = "usteer: set_enabled carries the device's own ssid_list and event_log_types into local",
		fn = function()
			-- The init script emits each list key from every section, empty
			-- or not, and usteerd keeps the last: local's. Live 2026-10-10,
			-- four ssid_list entries in the device's own section, none in
			-- get_config.
			with_usteer(function(db, cmds, commits)
				db.usteer = {cfg01 = {[".name"] = "cfg01", [".type"] = "usteer",
					ssid_list = {"Home", "IoT"}, event_log_types = "probe_req_accept"}}
				usteer.set_enabled(true, nil)
				local s = db.usteer["local"]
				assert_eq(table.concat(s.ssid_list, " "), "Home IoT", "ssid_list carried")
				assert_eq(table.concat(s.event_log_types, " "), "probe_req_accept",
					"a single-value list carried as a list")
				assert_eq(commits.usteer, 1, "one write")
				local n = #cmds
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 1, "carried lists unchanged: no write")
				assert_eq(#cmds, n, "and no restart")
			end)
		end
	},
	{
		name = "usteer: a change to the device's own lists rewrites local once; removing them clears it",
		fn = function()
			with_usteer(function(db, cmds, commits)
				usteer.set_enabled(true, nil)
				assert_nil(db.usteer["local"].ssid_list, "nothing to carry: no list written")
				assert_eq(commits.usteer, 1, "first write")
				db.usteer.cfg01 = {[".name"] = "cfg01", [".type"] = "usteer", ssid_list = {"Home"}}
				local n = #cmds
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 2, "the new list is picked up")
				assert_true(#cmds > n and cmds_contain({cmds[#cmds]}, "usteer restart"),
					"daemon restarted with it")
				assert_eq(table.concat(db.usteer["local"].ssid_list, " "), "Home", "carried")
				db.usteer.cfg01.ssid_list = nil
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 3, "removal is a change too")
				assert_nil(db.usteer["local"].ssid_list, "local's copy deleted")
				usteer.set_enabled(true, nil)
				assert_eq(commits.usteer, 3, "then steady")
			end)
		end
	},
	{
		name = "usteer: reconcile_filter drops the sync on every VAP, first fragments and the rest",
		fn = function()
			local orig = usteer._exec
			local exec, r = fake_nft()
			local cmds = r.cmds
			usteer._exec = exec
			local n = usteer.reconcile_filter({"phy0-ap0", "phy1-ap0", "bad name;rm"})
			usteer._exec = orig
			assert_eq(n, 3, "three rules installed")
			assert_eq(r.runs, 1, "one nft run")
			assert_eq(cmds[2], "nft delete table bridge openuf_usteer", "rebuilt from scratch")
			assert_true(cmds_contain(cmds, "hook postrouting"), "postrouting sees local and forwarded frames")
			assert_true(cmds_contain(cmds, 'oifname { "phy0-ap0", "phy1-ap0" } ip daddr 255.255.255.255 udp dport 16720 drop'),
				"first fragment / whole datagram, on both VAPs")
			assert_true(cmds_contain(cmds, "ip daddr 255.255.255.255 ip protocol udp ip frag-off & 0x1fff != 0 drop"),
				"the later fragments, which carry no UDP header")
			assert_true(cmds_contain(cmds, "ip6 daddr ff02::4150 drop"), "usteer's ipv6 mode")
			assert_false(cmds_contain(cmds, "bad name"), "an odd ifname never reaches the shell")
			assert_false(cmds_contain(cmds, "udp dport 68"), "nothing else is touched")
		end
	},
	{
		name = "usteer: reconcile_filter with no VAPs only removes the table; a rejected rule is not counted",
		fn = function()
			local orig, origerr = usteer._exec, io.stderr
			io.stderr = {write = function() end}
			local exec, r = fake_nft()
			usteer._exec = exec
			local none = usteer.reconcile_filter({})
			local ncmds = #r.cmds
			-- fake_nft answers a rejected script with exit status 1, as 5.1's
			-- os.execute does: truthy, and still a failure.
			usteer._exec = fake_nft(function(l) return l:find("add rule", 1, true) end)
			local rejected = usteer.reconcile_filter({"phy0-ap0"})
			usteer._exec, io.stderr = orig, origerr
			assert_eq(none, 0, "nothing installed")
			assert_eq(ncmds, 2, "just the delete (after an add, so it cannot fail)")
			assert_eq(rejected, 0, "Lua 5.1 exit status 1 is a failure, not success")
		end
	},
	{
		name = "usteer: filter_wanted follows openuf_active",
		fn = function()
			with_usteer(function(db)
				assert_false(usteer.filter_wanted(), "never configured")
				usteer.set_enabled(false, nil, true)
				assert_true(usteer.filter_wanted(), "running for Roaming Assistant")
				usteer.set_enabled(false, nil, false)
				assert_false(usteer.filter_wanted(), "stopped")
			end)
		end
	},
	{
		name = "usteer: set_locked exempts the clients locked here from steering, keeping the device's own entries",
		fn = function()
			with_usteer(function(db, cmds, commits)
				usteer.set_enabled(false, nil, true)   -- running, for Roaming Assistant
				local n0, c0 = #cmds, commits.usteer
				-- The device's own usteer section, before openUF's: its list
				-- would otherwise be masked by local's.
				db.usteer.cfg01 = {[".name"] = "cfg01", [".type"] = "usteer",
					aggressiveness_mac_list = {"00:00:5e:00:53:30,2", "00:00:5e:00:53:21,4"}}
				assert_true(usteer.set_locked({"00:00:5E:00:53:21"}), "changed")
				assert_eq(table.concat(db.usteer["local"].aggressiveness_mac_list, " "),
					"00:00:5e:00:53:30,2 00:00:5e:00:53:21,0",
					"the device's entry kept, the locked client's replaced by 0")
				assert_eq(commits.usteer, c0 + 1, "committed")
				assert_true(#cmds == n0 + 1 and cmds_contain({cmds[#cmds]}, "usteer restart"),
					"restarted: usteer reads a station's override only when it first sees it")
				assert_false(usteer.set_locked({"00:00:5e:00:53:21"}), "unchanged: nothing done")
				assert_eq(#cmds, n0 + 1, "no second restart")
				usteer.set_locked({})
				assert_eq(table.concat(db.usteer["local"].aggressiveness_mac_list, " "),
					"00:00:5e:00:53:30,2 00:00:5e:00:53:21,4",
					"unlocked: the device's own entries, the client's own back")
			end)
		end
	},
	{
		name = "usteer: set_locked writes nothing while openUF does not run usteerd",
		fn = function()
			with_usteer(function(db, cmds)
				usteer.set_enabled(false, nil, false)
				local n0 = #cmds
				usteer.set_locked({"00:00:5e:00:53:21"})
				assert_nil(db.usteer["local"].aggressiveness_mac_list, "no list")
				assert_eq(#cmds, n0, "the daemon is not started for it")
			end)
		end
	},
	{
		name = "usteer: locks learnt while usteerd is stopped are in place when set_enabled starts it",
		fn = function()
			with_usteer(function(db, cmds, commits)
				usteer.set_enabled(false, nil, false)            -- stopped
				usteer.set_locked({"00:00:5e:00:53:21"})          -- remembered, not written
				assert_nil(db.usteer["local"].aggressiveness_mac_list, "nothing while stopped")
				local n0, c0 = #cmds, commits.usteer
				usteer.set_enabled(false, nil, true)             -- Roaming Assistant starts it
				assert_eq(table.concat(db.usteer["local"].aggressiveness_mac_list, " "),
					"00:00:5e:00:53:21,0", "the exemption is written with the start")
				assert_eq(commits.usteer, c0 + 1, "one commit")
				local restarts = 0
				for i = n0 + 1, #cmds do if cmds[i]:find("restart", 1, true) then restarts = restarts + 1 end end
				assert_eq(restarts, 1, "one restart, already with the list")
				assert_false(usteer.set_locked({"00:00:5e:00:53:21"}), "nothing left to do")
			end)
		end
	},
	{
		name = "usteer: the device's own aggressiveness entries are carried even while openUF does not run usteerd",
		fn = function()
			with_usteer(function(db)
				db.usteer = {cfg01 = {[".name"] = "cfg01", [".type"] = "usteer",
					aggressiveness_mac_list = {"00:00:5e:00:53:30,2"}}}
				usteer.set_locked({"00:00:5e:00:53:21"})
				usteer.set_enabled(false, nil, false)
				assert_eq(table.concat(db.usteer["local"].aggressiveness_mac_list, " "),
					"00:00:5e:00:53:30,2", "the device's entry survives local's empty key; no lock while stopped")
			end)
		end
	},
	{
		name = "usteer: a restarted daemon keeps the locks already in local until set_locked speaks",
		fn = function()
			with_usteer(function(db, cmds)
				usteer.set_enabled(false, nil, true)
				usteer.set_locked({"00:00:5e:00:53:21"})
				usteer._locked = nil                              -- a fresh openUF process
				local n0 = #cmds
				usteer.set_enabled(true, nil, true)               -- a push turns band steering on
				assert_eq(table.concat(db.usteer["local"].aggressiveness_mac_list, " "),
					"00:00:5e:00:53:21,0", "the lock is not dropped by the first push")
				assert_true(#cmds > n0, "band steering itself did change")
			end)
		end
	},
}
