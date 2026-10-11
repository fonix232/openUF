-- Tests for src/openwrt/firewall.lua (client block/unblock enforcement).
-- Run from project root: lua tests/run_tests.lua
-- The script itself was run against real nft (1.0.9) in a privileged
-- container: see PROTOCOL-VALIDATION.md.

local firewall = dofile("src/openwrt/firewall.lua")

-- nft as a double: the script each `nft -f` ran, and a set listing that
-- echoes the last script's elements back unless told otherwise.
local function with_nft(fn, opts)
	opts = opts or {}
	local scripts, cmds = {}, {}
	local saved = {firewall._exec, firewall._popen, io.stderr}
	local log = {}
	io.stderr = {write = function(_, s) log[#log + 1] = s end}
	firewall._exec = function(cmd)
		cmds[#cmds + 1] = cmd
		local path = cmd:match("^nft %-f '([^']+)'")
		if path then
			local f = io.open(path, "r")
			scripts[#scripts + 1] = f and f:read("*a") or ""
			if f then f:close() end
		end
		return opts.rc or 0
	end
	firewall._popen = function(cmd)
		if opts.listing then return opts.listing end
		local last = scripts[#scripts] or ""
		local els = last:match("elements = { ([^}]*) }") or ""
		return "table bridge openuf {\n\tset blocked_macs {\n\t\ttype ether_addr\n"
			.. (els ~= "" and ("\t\telements = { " .. els .. " }\n") or "") .. "\t}\n}\n"
	end
	local ok, err = pcall(fn, scripts, cmds, log)
	firewall._exec, firewall._popen, io.stderr = saved[1], saved[2], saved[3]
	if not ok then error(err, 0) end
end

-- A hostapd for deny_sync: per BSS, what `deny_acl SHOW` prints (absent =
-- no control socket, so hostapd_cli fails), the grep of the hostapd
-- configs, and the deny files. Captures the script read and every exec.
local function fake_hostapd(shows, confs, files)
	local r = {execs = {}, script = ""}
	local orig = {firewall._read, firewall._exec, firewall._read_file}
	firewall._read = function(cmd)
		r.script = cmd
		local out = {}
		for b in cmd:gmatch("echo '@ ([^']+)'") do
			out[#out + 1] = "@ " .. b
			out[#out + 1] = shows[b] or "FAIL"
		end
		out[#out + 1] = "@"
		out[#out + 1] = confs or ""
		return table.concat(out, "\n")
	end
	firewall._exec = function(cmd) r.execs[#r.execs + 1] = cmd; return true end
	firewall._read_file = function(path) return (files or {})[path] end
	function r.restore() firewall._read, firewall._exec, firewall._read_file = orig[1], orig[2], orig[3] end
	function r.cmds()
		local out = {}
		for _, e in ipairs(r.execs) do
			for c in e:gmatch("hostapd_cli [^;}]-%x%x:%x%x:%x%x:%x%x:%x%x:%x%x") do out[#out + 1] = c end
		end
		return out
	end
	return r
end

return {
	{
		name = "firewall: one nft transaction replaces the table, with forward and input drops",
		fn = function()
			with_nft(function(scripts, cmds)
				assert_true(firewall.reconcile({"aa:bb:cc:dd:ee:01", "AA:BB:CC:DD:EE:02"}), "applied")
				assert_eq(#cmds, 1, "a single nft invocation")
				local s = scripts[1]
				assert_true(s:find("add table bridge openuf\ndelete table bridge openuf\n", 1, true) == 1,
					"the old table goes in the same transaction")
				assert_contains(s, "elements = { aa:bb:cc:dd:ee:01, aa:bb:cc:dd:ee:02 }", "both MACs, lowercase")
				assert_contains(s, "type filter hook forward priority 0; policy accept;", "bridge forward")
				assert_contains(s, "ether saddr @blocked_macs drop", "from a blocked MAC")
				assert_contains(s, "ether daddr @blocked_macs drop", "to a blocked MAC")
				assert_contains(s, "chain input {\n\t\ttype filter hook input priority 0;",
					"and frames from it to the AP itself")
			end)
		end
	},
	{
		name = "firewall: an empty list is an empty set, still a valid script",
		fn = function()
			with_nft(function(scripts)
				assert_true(firewall.reconcile({}), "applied")
				assert_true(scripts[1]:find("elements", 1, true) == nil, "no empty elements clause")
			end)
		end
	},
	{
		name = "firewall: the result is read back -- a rejected script or a missing MAC is a failure",
		fn = function()
			with_nft(function(_, _, log)
				assert_false(firewall.reconcile({"aa:bb:cc:dd:ee:01"}), "nft exited non-zero")
				assert_contains(table.concat(log), "not enforced", "said so")
			end, {rc = 1})
			with_nft(function(_, _, log)
				assert_false(firewall.reconcile({"aa:bb:cc:dd:ee:01"}), "the set does not hold it")
				assert_contains(table.concat(log), "aa:bb:cc:dd:ee:01", "named")
			end, {listing = "table bridge openuf {\n\tset blocked_macs {\n\t}\n}\n"})
			with_nft(function()
				assert_false(firewall.reconcile({}), "no table at all")
			end, {listing = ""})
		end
	},
	{
		name = "firewall: a malformed MAC never reaches the nft script",
		fn = function()
			-- blocked_stas comes from the controller by way of state.json,
			-- which is hand-editable too. Before adoption the inform channel
			-- is plain HTTP under the well-known default key, so a forged
			-- block-sta is within reach of anyone on the path.
			with_nft(function(scripts, _, log)
				firewall.reconcile({
					"aa:bb:cc:dd:ee:ff",
					"aa:bb:cc:dd:ee:ff }; flush ruleset; add element x y { 1",
					"not-a-mac",
				})
				local s = scripts[1]
				assert_contains(s, "aa:bb:cc:dd:ee:ff", "the real MAC is in")
				assert_true(s:find("flush", 1, true) == nil, "the injected statement is not")
				assert_true(s:find("not%-a%-mac") == nil, "nor the junk entry")
				assert_contains(table.concat(log), "malformed", "each drop is logged")
			end)
		end
	},
	{
		name = "firewall: deny_sync adds each blocked MAC to every BSS's hostapd deny list",
		fn = function()
			local r = fake_hostapd({["phy0-ap0"] = "", ["phy1-ap0"] = "aa:bb:cc:dd:ee:01 VLAN_ID=0\n"})
			local again = firewall.deny_sync({"AA:BB:CC:DD:EE:01", "aa:bb:cc:dd:ee:02", "junk"},
				{"phy0-ap0", "phy1-ap0"})
			r.restore()
			assert_eq(#r.execs, 1, "every change in one shell")
			local cmds = r.cmds()
			assert_eq(table.concat(cmds, "\n"), table.concat({
				"hostapd_cli -i phy0-ap0 deny_acl ADD_MAC aa:bb:cc:dd:ee:01",
				"hostapd_cli -i phy0-ap0 deny_acl ADD_MAC aa:bb:cc:dd:ee:02",
				"hostapd_cli -i phy1-ap0 deny_acl ADD_MAC aa:bb:cc:dd:ee:02",
			}, "\n"), "lowercased; only what each BSS lacks")
			assert_true(r.execs[1]:find("junk", 1, true) == nil, "the junk entry never reaches the shell")
			assert_true(again, "a change was made: look again next time")
		end
	},
	{
		name = "firewall: deny_sync changes nothing when hostapd already has the list",
		fn = function()
			local r = fake_hostapd({["phy0-ap0"] = "aa:bb:cc:dd:ee:01 VLAN_ID=0\n"})
			local again = firewall.deny_sync({"aa:bb:cc:dd:ee:01"}, {"phy0-ap0"})
			r.restore()
			assert_eq(#r.execs, 0, "nothing to run")
			assert_false(again, "nothing to look at again")
		end
	},
	{
		name = "firewall: deny_sync removes an unblocked MAC but keeps the BSS's own MAC filter entries",
		fn = function()
			-- phy0-ap0 runs the controller's MAC filter in deny mode: its
			-- file lists :03, which an unblock must not take off. phy1-ap0
			-- has no deny file, so its :03 is openUF's and goes. The file
			-- of another BSS protects nothing here.
			local r = fake_hostapd({
				["phy0-ap0"] = "aa:bb:cc:dd:ee:01 VLAN_ID=0\naa:bb:cc:dd:ee:03 VLAN_ID=0\n",
				["phy1-ap0"] = "aa:bb:cc:dd:ee:01 VLAN_ID=0\naa:bb:cc:dd:ee:03 VLAN_ID=0\n",
			}, "interface=phy0-ap0\ndeny_mac_file=/var/run/hostapd-phy0-ap0.maclist\n"
				.. "interface=phy1-ap0\nbss=phy1-ap1\ndeny_mac_file=/var/run/hostapd-phy1-ap1.maclist\n",
				{["/var/run/hostapd-phy0-ap0.maclist"] = "AA:BB:CC:DD:EE:03\n",
				 ["/var/run/hostapd-phy1-ap1.maclist"] = "aa:bb:cc:dd:ee:03\n"})
			local again = firewall.deny_sync({}, {"phy0-ap0", "phy1-ap0"})
			r.restore()
			assert_eq(table.concat(r.cmds(), "\n"), table.concat({
				"hostapd_cli -i phy0-ap0 deny_acl DEL_MAC aa:bb:cc:dd:ee:01",
				"hostapd_cli -i phy1-ap0 deny_acl DEL_MAC aa:bb:cc:dd:ee:01",
				"hostapd_cli -i phy1-ap0 deny_acl DEL_MAC aa:bb:cc:dd:ee:03",
			}, "\n"), "only runtime entries the BSS's own config file doesn't list")
			assert_true(again, "read back next time")
		end
	},
	{
		name = "firewall: deny_sync skips a BSS hostapd doesn't answer for and asks to be called again",
		fn = function()
			local r = fake_hostapd({["phy0-ap0"] = "FAIL\n"})
			local again = firewall.deny_sync({"aa:bb:cc:dd:ee:01"}, {"phy0-ap0", "phy1-ap0"})
			r.restore()
			assert_eq(#r.execs, 0, "no command for a BSS whose list is unknown")
			assert_true(again, "try again later")
			local r2 = fake_hostapd({})
			firewall._read = function() return "" end
			assert_true(firewall.deny_sync({"aa:bb:cc:dd:ee:01"}, {"phy0-ap0"}),
				"no output at all (the shell never ran): again, and no error")
			assert_eq(#r2.execs, 0, "and nothing run blind")
			assert_false(firewall.deny_sync({}, {}), "no BSS and nothing blocked: done")
			assert_true(firewall.deny_sync({"aa:bb:cc:dd:ee:01"}, {}), "no BSS yet but something blocked: again")
			r2.restore()
		end
	},
	{
		name = "firewall: deny_sync never splices a bad BSS name into the shell",
		fn = function()
			local r = fake_hostapd({["phy0-ap0"] = ""})
			firewall.deny_sync({"aa:bb:cc:dd:ee:01"}, {"phy0-ap0", "x; reboot", "$(id)"})
			r.restore()
			local all = r.script .. table.concat(r.execs, "\n")
			assert_true(all:find("reboot", 1, true) == nil, "the injected name is dropped")
			assert_true(all:find("$(id)", 1, true) == nil, "and so is the substitution")
			assert_contains(all, "-i phy0-ap0 deny_acl ADD_MAC", "the real BSS is still synced")
		end
	},
	{
		name = "firewall: hostapd_sockets names each hostapd control socket by its inode, without a fork",
		fn = function()
			-- /proc/net/unix as both reference boards print it (2026-10-17):
			-- 32-bit on the ath79, 64-bit on the filogic, one socket of
			-- another daemon.
			local orig = firewall._read_file
			firewall._read_file = function(path)
				assert_eq(path, "/proc/net/unix", "one file")
				return "Num       RefCount Protocol Flags    Type St Inode Path\n"
					.. "6e6e66c9: 00000003 00000000 00000000 0001 03 125358599 /var/run/hostapd/phy1-ap1\n"
					.. "722ee422: 00000002 00000000 00000000 0001 03 65409346 /var/run/hostapd/global\n"
					.. "000000000b05b42b: 00000002 00000000 00010000 0001 01  1666 /var/run/ubus/ubus.sock\n"
					.. "000000000ed6ee61: 00000003 00000000 00000000 0002 03 2749890 /var/run/hostapd/phy0-ap0\n"
					.. "0000000012345678: 00000003 00000000 00000000 0001 03 4242\n"
			end
			local got = firewall.hostapd_sockets()
			firewall._read_file = orig
			assert_eq(got, "/var/run/hostapd/global=65409346 /var/run/hostapd/phy0-ap0=2749890 "
				.. "/var/run/hostapd/phy1-ap1=125358599", "hostapd's only, sorted, whole inodes")
			firewall._read_file = function() return nil end
			assert_eq(firewall.hostapd_sockets(), "", "unreadable: none")
			firewall._read_file = orig
		end
	},
}
