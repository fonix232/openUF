-- Tests for src/unifi/staevents.lua (the controller's STA_ASSOC_TRACKER events).
-- Run from project root: lua tests/run_tests.lua

local ev = dofile("src/unifi/staevents.lua")

local A = "aa:bb:cc:00:00:01"
local B = "aa:bb:cc:00:00:02"

-- A connection's device timeline (µs) for a client authorized at `ts` seconds.
local function timeline(ts)
	local auth = ts * 1000000 - 30000
	return {auth = auth, assoc = auth + 4000, authorized = auth + 30000,
		dhcp = auth + 250000, dns = auth + 300000}
end

local function kinds(list)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = e.event_type .. ":" .. e.mac end
	return table.concat(out, ",")
end

return {
	{
		name = "staevents: the first heartbeat after a start reports nothing",
		fn = function()
			ev._reset()
			assert_eq(ev.observe({[A] = {vap = "v0", signal = -50, uptime = 30}}, 1000, 500), 0,
				"no burst of fake associations after a restart")
		end
	},
	{
		name = "staevents: a new client is an association plus a success, dated by connected time",
		fn = function()
			local out = ev.diff({}, {[A] = {vap = "openuf_radio0_x", signal = -52, uptime = 7}}, 1000, 500)
			assert_eq(kinds(out), "association:" .. A .. ",success:" .. A, "two events")
			local a, s = out[1], out[2]
			assert_eq(a.message_type, "STA_ASSOC_TRACKER", "message type")
			assert_eq(a.vap, "openuf_radio0_x", "vap is the vap_table name")
			assert_eq(a.auth_ts, 993, "associated 7 s before now")
			assert_eq(a.auth_rssi, -52, "auth_rssi, which the roaming detector requires")
			assert_eq(s.dns_resp_seen, "N/A", "nothing claimed that was not observed")
			assert_eq(s.assoc_failures, 0, "no failures")
			assert_true(type(a.event_id) == "string" and #a.event_id == 8, "event id")
			assert_true(a.event_id ~= s.event_id, "distinct per event")
		end
	},
	{
		name = "staevents: a departed client is a sta_leave with last_seen in device uptime",
		fn = function()
			local out = ev.diff({[A] = {vap = "v0", signal = -60, uptime = 100, idle = 4}}, {}, 2000, 900)
			assert_eq(kinds(out), "sta_leave:" .. A, "one event")
			assert_eq(out[1].last_seen, 896, "uptime at the last heartbeat minus idle time")
			assert_eq(out[1].vap, "v0", "the vap it left")
		end
	},
	{
		name = "staevents: a VAP change or a reconnect between heartbeats is leave + join",
		fn = function()
			local prev = {[A] = {vap = "v0", uptime = 50}, [B] = {vap = "v0", uptime = 50}}
			local cur  = {[A] = {vap = "v1", uptime = 3}, [B] = {vap = "v0", uptime = 2}}
			local out = ev.diff(prev, cur, 3000, 1000)
			assert_eq(kinds(out), "sta_leave:" .. A .. ",association:" .. A .. ",success:" .. A
				.. ",sta_leave:" .. B .. ",association:" .. B .. ",success:" .. B, "both")
			assert_eq(out[1].vap, "v0", "left the old vap")
			assert_eq(out[2].vap, "v1", "joined the new one")
		end
	},
	{
		name = "staevents: an unchanged client produces nothing",
		fn = function()
			local out = ev.diff({[A] = {vap = "v0", uptime = 10}}, {[A] = {vap = "v0", uptime = 20}}, 1, 1)
			assert_eq(#out, 0, "quiet")
		end
	},
	{
		name = "staevents: the queue is bounded and ordered",
		fn = function()
			ev._reset()
			local old = ev.MAX_QUEUE
			ev.MAX_QUEUE = 2
			ev.observe({}, 0, 0)
			local C = "aa:bb:cc:00:00:03"
			local conns = {}
			for _, m in ipairs({A, B, C}) do conns[m] = timeline(9) end
			ev.observe({[A] = {vap = "v", uptime = 1}, [B] = {vap = "v", uptime = 1},
				[C] = {vap = "v", uptime = 1}}, 10, 10, {connections = conns})
			assert_eq(ev.pending(), 2, "capped")
			assert_eq(ev.peek().event_type, "success", "oldest dropped first")
			ev.MAX_QUEUE = old
			ev._reset()
		end
	},
	{
		name = "staevents: deltas are cumulative from the first Authentication frame",
		fn = function()
			local d = ev.deltas({auth = 1000000, assoc = 1004000, authorized = 1030000,
				dhcp = 1250000, dns = 1300000})
			assert_eq(d.assoc_delta, 4000, "association 4 ms in")
			assert_eq(d.wpa_auth_delta, 30000, "handshake done at 30 ms")
			assert_eq(d.ip_delta, 250000, "DHCP ACK at 250 ms")
			assert_eq(d.traffic_delta, 300000, "first DNS answer at 300 ms")
		end
	},
	{
		name = "staevents: a DHCP ACK or DNS answer from an earlier connection is not this one's",
		fn = function()
			local d = ev.deltas({auth = 1000000, assoc = 1004000, authorized = 1030000,
				dhcp = 900000, dns = 1020000})
			assert_nil(d.ip_delta, "an ACK before the handshake finished")
			assert_nil(d.traffic_delta, "an answer before the client could send")
			-- No DHCP (a roam, a static client): DNS still counts, after the handshake.
			d = ev.deltas({auth = 1000000, assoc = 1004000, authorized = 1030000, dns = 1100000})
			assert_nil(d.ip_delta, "no DHCP phase")
			assert_eq(d.traffic_delta, 100000, "DNS measured from the start")
			-- The controller ignores anything past a minute.
			d = ev.deltas({auth = 1000000, authorized = 1030000, dns = 1000000 + 61000000})
			assert_nil(d.traffic_delta, "over a minute is not sent")
			assert_nil(d.assoc_delta, "no assoc notification, no association phase")
		end
	},
	{
		name = "staevents: a success waits for its timed DNS answer, then carries the deltas",
		fn = function()
			ev._reset()
			ev.observe({}, 0, 0, {connections = {}})
			local c = timeline(99)
			c.dns = nil
			ev.observe({[A] = {vap = "v", signal = -50, uptime = 1}}, 100, 100, {connections = {[A] = c}})
			assert_eq(ev.pending(), 1, "the association goes out; the success is held")
			ev.pop()
			c.dns = c.authorized + 400000
			ev.observe({[A] = {vap = "v", uptime = 11}}, 110, 110, {connections = {[A] = c}})
			local e = ev.pop()
			assert_eq(e.event_type, "success", "success")
			assert_eq(e.traffic_delta, 430000, "time to the first DNS answer")
			assert_eq(e.dns_responses, 1, "what the controller counts a success by")
			assert_eq(e.ip_delta, 250000, "DHCP phase")
			assert_eq(e.ip_assign_type, "dhcp", "and the client used DHCP")
			assert_eq(e.dns_resp_seen, "yes", "older firmware's field, now true")
			ev._reset()
		end
	},
	{
		name = "staevents: an unverified success is never sent",
		fn = function()
			ev._reset()
			ev.observe({}, 0, 0, {connections = {}})
			local c = timeline(99)
			c.dns = nil
			ev.observe({[A] = {vap = "v", uptime = 1}}, 100, 100, {connections = {[A] = c}})
			ev.pop()
			ev.observe({[A] = {vap = "v", uptime = 81}}, 180, 180, {connections = {[A] = c}})
			assert_eq(ev.pending(), 0, "no DNS answer within the wait: nothing claimed")
			assert_nil(ev._held[A], "and nothing left waiting")
			-- A timeline of some other connection of the same client does not match.
			ev.observe({}, 190, 190, {connections = {}})
			ev.pop()
			ev.observe({[A] = {vap = "v", uptime = 1}}, 300, 300, {connections = {[A] = timeline(99)}})
			ev.pop()
			ev.observe({[A] = {vap = "v", uptime = 11}}, 310, 310, {connections = {[A] = timeline(99)}})
			assert_eq(ev.pending(), 0, "authorized 200 s before this join: not this connection")
			ev._reset()
		end
	},
	{
		name = "staevents: a client that leaves before its DNS answer gets no success",
		fn = function()
			ev._reset()
			ev.observe({}, 0, 0)
			ev.observe({[A] = {vap = "v", uptime = 1}}, 10, 10, {connections = {}})
			ev.pop()
			ev.observe({}, 20, 20, {connections = {[A] = timeline(9)}})
			assert_eq(ev.pending(), 1, "only the sta_leave")
			assert_eq(ev.pop().event_type, "sta_leave", "leave")
			ev._reset()
		end
	},
	{
		name = "staevents: wrong-passphrase attempts become one failure per client per window",
		fn = function()
			ev._reset()
			local fails = {
				{seq = 1, mac = A, at = 50e6, auth = 49e6, signal = -60, vap = "v"},
			}
			ev.observe({}, 100, 100, {failures = fails})
			assert_eq(ev.pending(), 0, "what the collector held before this run is not recounted")
			fails[#fails + 1] = {seq = 2, mac = A, at = 101e6, auth = 100.997e6, signal = -61, vap = "v"}
			fails[#fails + 1] = {seq = 3, mac = A, at = 102e6, auth = 101.997e6, signal = -61, vap = "v"}
			fails[#fails + 1] = {seq = 4, mac = B, at = 103e6, auth = 102e6, assoc = 102.004e6,
				signal = -55, vap = "w"}
			fails[#fails + 1] = {seq = 5, mac = B, at = 104e6, auth = 103e6, vap = nil}
			ev.observe({}, 110, 110, {failures = fails})
			assert_eq(ev.pending(), 0, "held for the window")
			ev.observe({}, 170, 170, {failures = fails})
			assert_eq(ev.pending(), 2, "one event per client")
			local a, b = ev.pop(), ev.pop()
			assert_eq(a.event_type, "failure", "failure")
			assert_eq(a.mac, A, "A first")
			assert_eq(a.auth_failures, 2, "SAE rejected it before association: authentication")
			assert_nil(a.wpa_auth_failures, "not the handshake")
			assert_eq(a.auth_rssi, -61, "the signal the controller filters weak clients by")
			assert_eq(a.vap, "v", "the VAP it tried")
			assert_eq(b.wpa_auth_failures, 1, "after association: the 4-way handshake")
			assert_eq(b.assoc_delta, 4000, "and how long association took")
			ev._reset()
		end
	},
	{
		name = "staevents: a restarted collector's failures are counted from its start",
		fn = function()
			ev._reset()
			ev.observe({}, 100, 100, {failures = {{seq = 7, mac = A, at = 90e6, vap = "v"}}})
			ev.observe({}, 110, 110, {failures = {{seq = 1, mac = A, at = 105e6, vap = "v"}}})
			ev.observe({}, 200, 200, {failures = {{seq = 1, mac = A, at = 105e6, vap = "v"}}})
			assert_eq(ev.pending(), 1, "seq went backwards: a new collector, a new failure")
			assert_eq(ev.pop().auth_failures, 1, "counted once")
			ev._reset()
		end
	},
	{
		name = "staevents: the notification inform repeats the identity and carries the event",
		fn = function()
			local p = ev.notif_payload({mac = "00:11:22:33:44:55", model = "U6IW", version = "6.8.2.1",
				vap_table = {}}, {event_type = "sta_leave"})
			assert_eq(p.inform_as_notif, true, "notif")
			assert_eq(p.notif_reason, "event", "reason")
			assert_eq(p.notif_payload.event_type, "sta_leave", "payload")
			assert_eq(p.model, "U6IW", "identity kept")
			assert_nil(p.vap_table, "but not the stats")
		end
	},
	{
		name = "dnswatch: remove drops the DNS-answer table",
		fn = function()
			local dw = dofile("src/openwrt/dnswatch.lua")
			local cmds = {}
			dw._exec = function(c) cmds[#cmds + 1] = c return 0 end
			dw.remove()
			assert_eq(cmds[1], "nft delete table bridge openuf_ev >/dev/null 2>&1", "one delete")
		end
	},
	{
		name = "dnswatch: the first DHCP ACK and DNS answer are dated from what remains of their timeout",
		fn = function()
			local dw = dofile("src/openwrt/dnswatch.lua")
			dw._now_us = function() return 1000 * 1000000 end
			dw._popen = function() return table.concat({
				"table bridge openuf_ev {",
				"\tset dhcpfirst {",
				"\t\ttypeof @th,288,48",
				"\t\tsize 65535\t# count 2",
				"\t\tflags dynamic,timeout",
				"\t\ttimeout 1m10s",
				"\t\telements = { 0xc0956da355ab expires 1m5s500ms,",
				"\t\t\t     0x1af4a03fc66 expires 12s }",
				"\t}",
				"\tset dnsfirst {",
				"\t\ttype ether_addr",
				"\t\tflags dynamic,timeout",
				"\t\ttimeout 1m10s",
				"\t\telements = { c0:95:6d:a3:55:ab expires 1m6s }",
				"\t}",
				"}", ""}, "\n") end
			local f = dw.firsts()
			assert_eq(f.dhcp["c0:95:6d:a3:55:ab"], (1000 - 4.5) * 1000000, "ACKed 4.5 s ago")
			assert_eq(f.dhcp["01:af:4a:03:fc:66"], (1000 - 58) * 1000000, "leading zero restored")
			assert_eq(f.dns["c0:95:6d:a3:55:ab"], (1000 - 4) * 1000000, "answered 4 s ago")
			assert_eq(dw.parse_duration("990ms"), 990000, "ms")
			assert_true(dw.RULESET:find("timeout 70s", 1, true) ~= nil, "a minute plus a heartbeat")
		end
	},
	{
		name = "staphase: the collector's attempts become timelines, with the VAP name",
		fn = function()
			local sp = dofile("src/openwrt/staphase.lua")
			local doc = {at = 5, connections = {
				{seq = 3, mac = "AA:BB:CC:00:00:01", ifname = "wl0-ap0", auth = 100, assoc = 104,
					authorized = 130, signal = -48},
				{seq = 4, mac = "aa:bb:cc:00:00:02", ifname = "wl1-ap0", auth = 100},
			}, failures = {
				{seq = 2, mac = "aa:bb:cc:00:00:03", ifname = "wl1-ap3", at = 90, auth = 88, signal = -60},
			}}
			local out = sp.collect(doc, {dhcp = {[A] = 350}, dns = {[A] = 400}},
				{["wl0-ap0"] = "openuf_radio0_x", ["wl1-ap3"] = "openuf_radio1_y"})
			local c = out.connections[A]
			assert_eq(c.authorized, 130, "handshake time")
			assert_eq(c.dhcp, 350, "DHCP joined in")
			assert_eq(c.dns, 400, "DNS joined in")
			assert_eq(c.vap, "openuf_radio0_x", "named as the controller knows it")
			assert_nil(out.connections[B], "never authorized: not a connection")
			assert_eq(out.failures[1].vap, "openuf_radio1_y", "failure's VAP")
			assert_eq(#sp.collect(nil).failures, 0, "no collector file: nothing")
		end
	},
}
