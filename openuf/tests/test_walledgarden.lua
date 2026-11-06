-- Tests for src/openwrt/walledgarden.lua (the guest walled garden's domain
-- half: names resolved on the AP, in the background, bounded).
-- Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local wg = dofile("src/openwrt/walledgarden.lua")

local function with_stderr(fn)
	local buf, real = {}, io.stderr
	io.stderr = {write = function(_, ...) for _, s in ipairs({...}) do buf[#buf + 1] = s end end}
	local ok, err = pcall(fn)
	io.stderr = real
	if not ok then error(err, 0) end
	return table.concat(buf)
end

-- OpenWrt 25.12's nslookup: repeated Name:/Address: pairs, A and AAAA
-- together, the resolver's own address BEFORE the first Name: line.
local NSLOOKUP = table.concat({
	"Server:\t\t192.0.2.1",
	"Address:\t192.0.2.1:53",
	"",
	"Non-authoritative answer:",
	"Name:\twww.example.net",
	"Address: 198.51.100.20",
	"Name:\twww.example.net",
	"Address: 198.51.100.21",
	"",
	"Non-authoritative answer:",
	"Name:\twww.example.net",
	"Address: 2606:4700:10::6814:179a",
}, "\n") .. "\n"

-- The firmware's busybox shape: the resolver's own address in the same
-- "Address N:" form, which is why the cut is at the first "Name:".
local NSLOOKUP_BB = table.concat({
	"Server:    127.0.0.1",
	"Address 1: 127.0.0.1 localhost",
	"",
	"Name:      ads.example.org",
	"Address 1: 198.51.100.30",
	"Address 2: 198.51.100.31",
}, "\n") .. "\n"

local function round_file(...)
	local parts = {}
	for i = 1, select("#", ...), 2 do
		local name, out = select(i, ...)
		parts[#parts + 1] = "@@ " .. name .. "\n" .. out
	end
	return table.concat(parts) .. "@end\n"
end

return {
	{
		name = "walledgarden: is_ipv4 takes a plain unicast dotted quad and nothing else",
		fn = function()
			for _, good in ipairs({"198.51.100.20", "10.0.0.1", "1.2.3.4", "223.255.255.255"}) do
				assert_true(wg.is_ipv4(good), good)
			end
			for _, bad in ipairs({"256.1.1.1", "01.2.3.4", "1.2.3", "1.2.3.4.5", "127.0.0.1", "0.0.0.0",
					"224.0.0.1", "255.255.255.255", "1.2.3.4; reboot", "1.2.3.4\n", "1.2.3.4/24",
					"2606:4700::1", "a.b.c.d", "", "1.2.3.1000"}) do
				assert_false(wg.is_ipv4(bad), ("%q"):format(bad))
			end
			assert_false(wg.is_ipv4(nil), "nil")
			assert_false(wg.is_ipv4(198), "a number")
		end
	},
	{
		name = "walledgarden: parse_round reads both nslookup shapes, server address and AAAA excluded",
		fn = function()
			local names = {"www.example.net", "ads.example.org", "never.example"}
			local map, cut = wg.parse_round(round_file("www.example.net", NSLOOKUP,
				"ads.example.org", NSLOOKUP_BB, "never.example", ""), names)
			assert_false(cut, "ran to its end")
			assert_eq(table.concat(map["www.example.net"], ","), "198.51.100.20,198.51.100.21",
				"every A record; the AAAA and the resolver's own address left out")
			assert_eq(table.concat(map["ads.example.org"], ","), "198.51.100.30,198.51.100.31", "Address N: shape")
			assert_nil(map["never.example"], "no answer, no entry")
			local twice = wg.parse_round(round_file("www.example.net", NSLOOKUP,
				"www.example.net", (NSLOOKUP:gsub("20", "22"))), names)
			assert_eq(table.concat(twice["www.example.net"], ","), "198.51.100.20,198.51.100.21,198.51.100.22",
				"the two asks merge, a repeat is one address")
			local _, stopped = wg.parse_round("@@ www.example.net\n" .. NSLOOKUP .. "@cut\n", names)
			assert_true(stopped, "@cut says the budget ran out")
			local foreign = wg.parse_round(round_file("evil.example", NSLOOKUP), names)
			assert_nil(foreign["evil.example"], "a name that was not asked is not taken")
		end
	},
	{
		name = "walledgarden: an answer is untrusted, so what is not an address never gets through",
		fn = function()
			local hostile = table.concat({"Name:\ta.example", "Address: 198.51.100.9",
				"Address: 1.2.3.4; flush ruleset", "Address: 127.0.0.1", "Address: 224.0.0.251",
				"Address: 0.0.0.0", "Address: 198.51.100.9/24", "Address: 300.1.1.1"}, "\n") .. "\n"
			local map = wg.parse_round(round_file("a.example", hostile), {"a.example"})
			assert_eq(table.concat(map["a.example"], ","), "198.51.100.9", "one good address")
			local many = {"Name:\ta.example"}
			for i = 1, wg.MAX_IPS + 5 do many[#many + 1] = "Address: 198.51.100." .. i end
			local capped = wg.parse_round(round_file("a.example", table.concat(many, "\n") .. "\n"), {"a.example"})
			assert_eq(#capped["a.example"], wg.MAX_IPS, "at most MAX_IPS per name")
			assert_eq(#wg.addresses({a = {"198.51.100.2", "x; reboot", "127.0.0.1"}}), 1,
				"and what comes back from state.json is checked again")
		end
	},
	{
		name = "walledgarden: merge keeps the last good answer for a name that stops resolving",
		fn = function()
			local first, changed = wg.merge({"a.example", "b.example"}, nil,
				{["a.example"] = {"198.51.100.20"}, ["b.example"] = {"198.51.100.21"}})
			assert_true(changed, "from nothing to two addresses")
			assert_eq(table.concat(wg.addresses(first), ","), "198.51.100.20,198.51.100.21", "flattened")
			local kept, changed2, unanswered
			local err = with_stderr(function()
				kept, changed2, unanswered = wg.merge({"a.example", "b.example"}, first,
					{["a.example"] = {"198.51.100.20"}})
			end)
			assert_eq(table.concat(kept["b.example"], ","), "198.51.100.21", "the last good answer stands")
			assert_false(changed2, "so the chains need no rebuild")
			assert_true(unanswered, "but a retry is wanted")
			assert_contains(err, "keeping the last 1 address", "said")
			local fresh
			local err2 = with_stderr(function() fresh = wg.merge({"c.example"}, first, {}) end)
			assert_nil(fresh["c.example"], "no earlier answer: not enforced")
			assert_contains(err2, "no earlier answer", "said plainly")
			local gone = wg.merge({"a.example"}, first, {["a.example"] = {"198.51.100.20"}})
			assert_nil(gone["b.example"], "a name no longer pushed is dropped")
			local moved, changed3 = wg.merge({"a.example"}, first, {["a.example"] = {"198.51.100.99"}})
			assert_true(changed3, "a moved address is a change")
			assert_eq(moved["a.example"][1], "198.51.100.99", "taken")
			assert_eq(table.concat(wg.addresses({x = {"198.51.100.9"}, y = {"198.51.100.9", "198.51.100.8"}}), ","),
				"198.51.100.8,198.51.100.9", "sorted, deduplicated")
			local p, ch = wg.prune({a = {"198.51.100.1"}, b = {"198.51.100.2"}}, {"a"})
			assert_true(ch and p.b == nil and p.a ~= nil, "prune drops what is not pushed")
			assert_false(select(2, wg.prune({a = {"198.51.100.1"}}, {"a"})), "and reports no change when nothing went")
		end
	},
	{
		name = "walledgarden: a round runs in the background, is collected later, and is given up on when lost",
		fn = function()
			local oe, orf, orm = wg._exec, wg._read_file, wg._remove
			local cmds, files, removed = {}, {}, {}
			wg._exec = function(c) cmds[#cmds + 1] = c; return 0 end
			wg._read_file = function(p) return files[p] end
			wg._remove = function(p) removed[#removed + 1] = p; files[p] = nil end
			wg._round = nil
			local ok, err = pcall(function()
				assert_true(wg.start({"www.example.net", "a;reboot.example", "$(id).example", "ads.example.org"}, 1000),
					"started")
				local run = cmds[#cmds]
				assert_true(run:sub(-1) == "&", "in the background: the caller does not wait")
				assert_contains(run, "for n in www.example.net ads.example.org;", "only real names reach the shell")
				assert_true(not run:find("reboot", 1, true) and not run:find("$(id)", 1, true), "nothing else")
				assert_contains(run, "timeout " .. wg.LOOKUP .. " nslookup", "each lookup is bounded")
				assert_contains(run, "-ge " .. wg.BUDGET, "and so is the round")
				local n = #cmds
				assert_false(wg.start({"www.example.net"}, 1001), "one round at a time")
				assert_eq(#cmds, n, "and nothing is launched for the refusal")
				assert_nil(wg.poll(1005), "not back yet: nothing, and no waiting")
				files[wg.OUT_PREFIX .. "1000"] = round_file("www.example.net", NSLOOKUP)
				local done = wg.poll(1010)
				assert_eq(table.concat(done.answered["www.example.net"], ","), "198.51.100.20,198.51.100.21", "collected")
				assert_eq(removed[#removed], wg.OUT_PREFIX .. "1000", "and the file removed")
				assert_nil(wg.poll(1011), "no round in flight")
				assert_true(wg.start({"www.example.net"}, 2000), "the next round can start")
				local lost
				local msg = with_stderr(function() lost = wg.poll(2000 + wg.ROUND_MAX + 1) end)
				assert_true(lost.lost, "a round that never writes its file is given up on")
				assert_contains(msg, "given up", "said")
				assert_true(wg.start({"www.example.net"}, 3000), "so the next one can start")
				assert_false(wg.start({}, 3000), "no names, no round")
			end)
			wg._exec, wg._read_file, wg._remove, wg._round = oe, orf, orm, nil
			if not ok then error(err, 0) end
		end
	},
	{
		name = "walledgarden: the cron job's request is served once, and only while fresh",
		fn = function()
			local orf, orm = wg._read_file, wg._remove
			local file = "1000\n"
			wg._read_file = function(p) return p == wg.REQUEST_FILE and file or nil end
			wg._remove = function() file = nil end
			local ok, err = pcall(function()
				assert_true(wg.requested(1100), "fresh")
				assert_nil(file, "and consumed")
				assert_false(wg.requested(1100), "once")
				file = "1000\n"
				local msg = with_stderr(function() assert_false(wg.requested(1000 + wg.MAX_AGE + 1), "stale") end)
				assert_contains(msg, "stale", "said")
				file = "5000\n"
				with_stderr(function() assert_false(wg.requested(1000), "dated in the future") end)
			end)
			wg._read_file, wg._remove = orf, orm
			if not ok then error(err, 0) end
		end
	},
}
