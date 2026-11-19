-- Tests for src/openwrt/hosthints.lua (wireless clients' addresses for
-- LuCI's host hints). Run from project root: lua tests/run_tests.lua

OPENUF_TEST_MODE = true
local hh = dofile("src/openwrt/hosthints.lua")

-- A dump as nft 1.1 prints it (checked against nft in openwrt/rootfs 25.12).
local DUMP = table.concat({
	"table bridge openuf_hosts {",
	"\tset staips {",
	"\t\ttype ether_addr . ipv4_addr",
	"\t\tsize 4096\t# count 3",
	"\t\tflags dynamic,timeout",
	"\t\ttimeout 1h",
	"\t\telements = { 00:00:5E:00:53:01 . 198.51.100.7 expires 59m59s983ms,",
	"\t\t\t     00:00:5e:00:53:02 . 198.51.100.8 expires 3m2s,",
	"\t\t\t     00:00:5e:00:53:02 . 198.51.100.9 expires 40m }",
	"\t}",
	"}",
}, "\n")

local function with_seams(exec, popen, fn)
	local o = {exec = hh._exec, popen = hh._popen, leases = hh.LEASES, applied = hh._applied,
		ours = hh.OURS, names = hh._names}
	hh._exec, hh._popen = exec, popen or function() return "" end
	hh.LEASES, hh.OURS, hh._names = os.tmpname(), os.tmpname(), {}
	os.remove(hh.LEASES) -- tmpname creates it; absent is the AP's usual start
	os.remove(hh.OURS)
	local ok, err = pcall(fn, hh.LEASES)
	os.remove(hh.LEASES)
	os.remove(hh.OURS)
	hh._exec, hh._popen, hh.LEASES, hh._applied = o.exec, o.popen, o.leases, o.applied
	hh.OURS, hh._names = o.ours, o.names
	if not ok then error(err, 0) end
end

return {
	{
		name = "hosthints: the table learns from the wireless ifnames only, idempotently",
		fn = function()
			local s = hh.script({"phy0-ap0", "wl1-ap3", "bad name"})
			assert_contains(s, 'add element bridge openuf_hosts wifi { "phy0-ap0", "wl1-ap3" }', "valid ifnames only")
			assert_contains(s, "iifname @wifi ip saddr != 0.0.0.0 update @staips { ether saddr . ip saddr }")
			assert_contains(s, "iifname @wifi arp saddr ip != 0.0.0.0 update @staips")
			assert_contains(s, "flush chain bridge openuf_hosts learn", "a re-run does not stack rules")
			assert_true(not s:find("delete table", 1, true), "a re-run keeps the learned set")
			assert_true(not hh.script({}):find("add element", 1, true), "no VAPs: an empty set")
		end
	},
	{
		name = "hosthints: ensure re-runs nft only when the VAPs change or it is forced",
		fn = function()
			local runs = 0
			with_seams(function() runs = runs + 1; return 0 end, nil, function()
				hh._applied = nil
				assert_true(hh.ensure({["phy0-ap0"] = {}}), "installed")
				hh.ensure({["phy0-ap0"] = {}})
				assert_eq(runs, 1, "unchanged: no fork")
				hh.ensure({["phy0-ap0"] = {}}, true)
				assert_eq(runs, 2, "forced")
				hh.ensure({["phy0-ap0"] = {}, ["phy1-ap0"] = {}})
				assert_eq(runs, 3, "a new VAP")
			end)
			with_seams(function() return 1 end, nil, function()
				hh._applied = nil
				assert_eq(hh.ensure({["phy0-ap0"] = {}}), false, "rejected")
				assert_eq(hh._applied, nil, "so it is retried next heartbeat")
			end)
		end
	},
	{
		name = "hosthints: parse takes each client's most recent address",
		fn = function()
			local m = hh.parse(DUMP)
			assert_eq(m["00:00:5e:00:53:01"], "198.51.100.7", "lowercased")
			assert_eq(m["00:00:5e:00:53:02"], "198.51.100.9", "40m left beats 3m2s")
			assert_eq(next(hh.parse("")), nil, "no table: nothing")
		end
	},
	{
		name = "hosthints: publish writes leases named by rrdns, never while dnsmasq runs",
		fn = function()
			local dnsmasq = false
			local exec = function(cmd)
				if cmd:find("pidof dnsmasq", 1, true) then return dnsmasq and 0 or 1 end
				return 0
			end
			-- rrdns as rpcd-mod-rrdns answers: found names only.
			local popen = function(cmd)
				if cmd:find("network.rrdns", 1, true) then
					return '{"198.51.100.7": "printer.localdomain"}'
				end
				return DUMP
			end
			with_seams(exec, popen, function(path)
				assert_true(hh.publish(1000), "written")
				local f = io.open(path); local text = f:read("*a"); f:close()
				assert_eq(text, "1600 00:00:5e:00:53:01 198.51.100.7 printer.localdomain *\n"
					.. "1600 00:00:5e:00:53:02 198.51.100.9 * *\n",
					"the DHCP table shows a lease's own name; none found: *")
				assert_true(hh.publish(1100), "its own file, names and all, is rewritten")
				f = io.open(path, "w"); f:write("1600 00:00:5e:00:53:01 198.51.100.7 * *\n"); f:close()
				assert_true(hh.publish(1200), "so is the nameless file an older openUF left")
				local foreign = "1735689600 00:00:5e:00:53:03 198.51.100.3 printer *\n"
				f = io.open(path, "w"); f:write(foreign); f:close()
				assert_eq(hh.publish(2000), false, "a file openUF did not write is not ours")
				f = io.open(path); text = f:read("*a"); f:close()
				assert_eq(text, foreign, "left alone")
				os.remove(path)
				dnsmasq = true
				assert_eq(hh.publish(2000), false, "dnsmasq owns the file")
				assert_true(io.open(path) == nil, "nothing written")
			end)
		end
	},
	{
		name = "hosthints: names are looked up once, kept a while, and only plain DNS names",
		fn = function()
			local asked = {}
			local answer = '{"198.51.100.7": "printer.localdomain", "198.51.100.8": "bad name; rm"}'
			with_seams(function() return 0 end, function(cmd)
				asked[#asked + 1] = cmd
				return answer
			end, function()
				local n = hh.names({"198.51.100.7", "198.51.100.8", "198.51.100.9"}, 1000)
				assert_eq(n["198.51.100.7"], "printer.localdomain", "found")
				assert_nil(n["198.51.100.8"], "not a DNS name: dropped")
				assert_nil(n["198.51.100.9"], "no PTR record")
				assert_eq(#asked, 1, "one lookup for all three")
				hh.names({"198.51.100.7", "198.51.100.9"}, 1000 + hh.NONAME_TTL - 1)
				assert_eq(#asked, 1, "cached: no new lookup")
				hh.names({"198.51.100.7", "198.51.100.9"}, 1000 + hh.NONAME_TTL)
				assert_eq(#asked, 2, "a missing name is asked for again sooner")
				assert_true(asked[2]:find("198.51.100.9", 1, true) ~= nil
					and not asked[2]:find("198.51.100.7", 1, true), "and only it")
				answer = "not json"
				hh._names = {}
				assert_nil(hh.names({"198.51.100.7"}, 5000)["198.51.100.7"], "rrdns missing: no names, no error")
			end)
		end
	},
}
