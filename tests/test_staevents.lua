-- Tests for openuf/staevents.lua (the controller's STA_ASSOC_TRACKER events).
-- Run from project root: lua tests/run_tests.lua

local ev = dofile("openuf/staevents.lua")

local A = "aa:bb:cc:00:00:01"
local B = "aa:bb:cc:00:00:02"

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
			ev.observe({[A] = {vap = "v", uptime = 1}, [B] = {vap = "v", uptime = 1},
				[C] = {vap = "v", uptime = 1}}, 10, 10, {[A] = true, [B] = true, [C] = true})
			assert_eq(ev.pending(), 2, "capped")
			assert_eq(ev.peek().event_type, "success", "oldest dropped first")
			ev.MAX_QUEUE = old
			ev._reset()
		end
	},
	{
		name = "staevents: success waits for a DNS answer; yes when seen, N/A after the wait",
		fn = function()
			ev._reset()
			ev.observe({}, 0, 0)
			ev.observe({[A] = {vap = "v", uptime = 1}, [B] = {vap = "v", uptime = 1}}, 100, 100, {})
			assert_eq(ev.pending(), 2, "associations go out at once, successes are held")
			ev.pop(); ev.pop()
			ev.observe({[A] = {vap = "v", uptime = 11}, [B] = {vap = "v", uptime = 11}}, 110, 110, {[A] = true})
			assert_eq(ev.pending(), 1, "A's DNS answer seen")
			local e = ev.pop()
			assert_eq(e.mac, A, "A")
			assert_eq(e.event_type, "success", "success")
			assert_eq(e.dns_resp_seen, "yes", "verified")
			ev.observe({[B] = {vap = "v", uptime = 51}}, 150, 150, {})
			assert_eq(ev.peek().event_type, "sta_leave", "A left")
			ev.pop()
			assert_eq(ev.pending(), 0, "B still waiting")
			ev.observe({[B] = {vap = "v", uptime = 61}}, 160, 160, {})
			local b = ev.pop()
			assert_eq(b.mac, B, "B after the wait")
			assert_eq(b.dns_resp_seen, "N/A", "unverified, and says so")
			ev._reset()
		end
	},
	{
		name = "staevents: a client that leaves before its DNS answer gets no success",
		fn = function()
			ev._reset()
			ev.observe({}, 0, 0)
			ev.observe({[A] = {vap = "v", uptime = 1}}, 10, 10, {})
			ev.pop()
			ev.observe({}, 20, 20, {[A] = true})
			assert_eq(ev.pending(), 1, "only the sta_leave")
			assert_eq(ev.pop().event_type, "sta_leave", "leave")
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
}
