-- Tests for src/unifi/stun.lua (the controller's STUN wake-up channel).
-- Run from project root: lua tests/run_tests.lua

local stun = dofile("src/unifi/stun.lua")

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

-- A Binding Success Response carrying `attr` (type, value).
local function response(txid, atype, value)
	local attr = u16(atype) .. u16(#value) .. value
	return u16(0x0101) .. u16(#attr) .. stun.MAGIC .. txid .. attr
end

-- A socket module double: one UDP socket fed from a queue.
local function mock_socket(queue)
	local sent = {}
	local udp = {}
	function udp:settimeout() end
	function udp:setsockname() return true end
	function udp:getsockname() return "0.0.0.0", 40001 end
	function udp:sendto(d, ip, port) sent[#sent + 1] = {d = d, ip = ip, port = port} return #d end
	function udp:receivefrom()
		local d = table.remove(queue, 1)
		if type(d) == "table" then return d[1], d[2], 3478 end
		if d then return d, "192.0.2.10", 3478 end
		return nil, "timeout"
	end
	function udp:close() end
	local clock = 0
	local mod = {
		dns = {toip = function(h) return h == "unifi.example" and "192.0.2.10" or h end},
		udp = function() return udp end,
		select = function(r, _, t)
			clock = clock + (t or 0)
			if #queue > 0 then return {udp} end
			return {}
		end,
	}
	return mod, sent, function() return clock end
end

return {
	{
		name = "stun: parse_url takes host and port, defaulting to 3478",
		fn = function()
			local h, p = stun.parse_url("stun://192.0.2.10:3478/")
			assert_eq(h, "192.0.2.10", "host")
			assert_eq(p, 3478, "port")
			local h2, p2 = stun.parse_url("stun://unifi.example/")
			assert_eq(h2, "unifi.example", "named host")
			assert_eq(p2, 3478, "default port")
			assert_nil(stun.parse_url("http://x/"), "not a stun URL")
		end
	},
	{
		name = "stun: parse_response decodes XOR-MAPPED-ADDRESS",
		fn = function()
			local txid = string.rep("\1", 12)
			-- 203.0.113.5:40001 XOR 0x2112A442
			local port = 40001
			local m = {stun.MAGIC:byte(1, 4)}
			local function x(a, b)
				local r, pw = 0, 1
				for _ = 1, 8 do
					if a % 2 ~= b % 2 then r = r + pw end
					a, b, pw = math.floor(a / 2), math.floor(b / 2), pw * 2
				end
				return r
			end
			local xp = string.char(x(math.floor(port / 256), m[1]), x(port % 256, m[2]))
			local ip = {203, 0, 113, 5}
			local xa = string.char(x(ip[1], m[1]), x(ip[2], m[2]), x(ip[3], m[3]), x(ip[4], m[4]))
			local got_ip, got_port = stun.parse_response(response(txid, 0x0020, "\0\1" .. xp .. xa), txid)
			assert_eq(got_ip, "203.0.113.5", "mapped ip")
			assert_eq(got_port, 40001, "mapped port")
		end
	},
	{
		name = "stun: parse_response falls back to MAPPED-ADDRESS and checks the transaction id",
		fn = function()
			local txid = string.rep("\2", 12)
			local v = "\0\1" .. u16(40002) .. string.char(198, 51, 100, 7)
			local ip, port = stun.parse_response(response(txid, 0x0001, v), txid)
			assert_eq(ip, "198.51.100.7", "classic mapped ip")
			assert_eq(port, 40002, "classic mapped port")
			assert_nil(stun.parse_response(response(txid, 0x0001, v), string.rep("\3", 12)),
				"a stranger's answer is ignored")
		end
	},
	{
		name = "stun: the controller's 0x8888 header is a wake-up",
		fn = function()
			assert_true(stun.is_wake(u16(0x8888) .. u16(0) .. string.rep("\0", 16)), "bare header")
			assert_false(stun.is_wake(u16(0x0101) .. u16(0) .. string.rep("\0", 16)), "a binding answer is not")
			assert_false(stun.is_wake("short"), "too short")
		end
	},
	{
		name = "stun: wait returns early on a wake and keeps the binding fresh",
		fn = function()
			local queue = {}
			local mod, sent, now = mock_socket(queue)
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			assert_true(c ~= nil, "client created")
			assert_false(c:wait(5, now), "nothing arrived: waits the full time")
			assert_true(#sent >= 1, "a binding request went out")
			assert_eq(sent[1].ip, "192.0.2.10", "to the resolved controller")
			queue[1] = u16(0x8888) .. u16(0) .. string.rep("\0", 16)
			assert_true(c:wait(10, now), "the wake-up cut the wait short")
			local ip, port = c:address("192.168.1.5")
			assert_eq(ip, "192.168.1.5", "no answer yet: the device's own address")
			assert_eq(port, 40001, "and the socket's local port")
			stun._socket = nil
		end
	},
	{
		name = "stun: the binding request carries the CHANGE-REQUEST a 3489 server insists on",
		fn = function()
			local req = stun.binding_request(string.rep("\7", 12))
			assert_eq(#req, 28, "20-byte header + one 8-byte attribute")
			assert_eq(req:byte(1) * 256 + req:byte(2), 0x0001, "Binding Request")
			assert_eq(req:byte(3) * 256 + req:byte(4), 8, "message length")
			assert_eq(req:byte(21) * 256 + req:byte(22), 0x0003, "CHANGE-REQUEST")
			assert_eq(req:sub(25, 28), "\0\0\0\0", "no change asked for")
		end
	},
	{
		name = "stun: a wake from anywhere but the controller is ignored",
		fn = function()
			local queue = {{u16(0x8888) .. u16(0) .. string.rep("\0", 16), "192.0.2.66"}}
			local mod, _, now = mock_socket(queue)
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			local woke = c:wait(5, now)
			stun._socket = nil
			assert_false(woke, "a stranger's wake does not start an inform")
		end
	},
	{
		name = "stun: wakes start at most one inform per MIN_WAKE_GAP, a held one is not lost",
		fn = function()
			local wake = u16(0x8888) .. u16(0) .. string.rep("\0", 16)
			local queue = {wake}
			local mod, _, now = mock_socket(queue)
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			assert_true(c:wait(10, now), "the first wake")
			local t1 = now()
			queue[1] = wake
			assert_true(c:wait(10, now), "the second wake is answered")
			local gap = now() - t1
			queue[1] = wake
			local within = c:wait(0.5, now)
			stun._socket = nil
			assert_true(gap >= stun.MIN_WAKE_GAP, "but not before the gap (" .. gap .. " s)")
			assert_false(within, "a wake inside the gap does not cut a short wait")
			assert_true(c.pending, "it is held for the next wait")
		end
	},
	{
		name = "stun: a new or changed mapped address informs at once, an unchanged one does not",
		fn = function()
			local orig = stun._random_bytes
			stun._random_bytes = function(n) return string.rep("\7", n) end
			local txid = string.rep("\7", 12)
			local function mapped(port)
				return response(txid, 0x0001, "\0\1" .. u16(port) .. string.char(198, 51, 100, 7))
			end
			local queue = {}
			local mod, _, now = mock_socket(queue)
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			c:bind(0)
			queue[1] = mapped(40002)
			assert_true(c:poll(), "the first mapping is news to the controller")
			queue[1] = mapped(40002)
			assert_false(c:poll(), "the same mapping again is not")
			queue[1] = mapped(40003)
			assert_true(c:poll(), "a changed port is")
			stun._socket, stun._random_bytes = nil, orig
			assert_eq(select(2, c:address("192.0.2.100")), 40003, "and is what gets reported")
		end
	},
	{
		name = "stun: Binding Requests every 30 s, 5 s after one that could not be sent",
		fn = function()
			local mod = mock_socket({})
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			c:bind(100)
			assert_eq(c.next_bind, 130, "the firmware's 30 s")
			c.udp.sendto = function() return nil, "network unreachable" end
			c:bind(200)
			stun._socket = nil
			assert_eq(c.next_bind, 205, "a failed send retries after 5 s")
		end
	},
	{
		name = "stun: the transaction id comes from the crypto source",
		fn = function()
			local orig = stun._random_bytes
			local asked
			stun._random_bytes = function(n) asked = n; return string.rep("\9", n) end
			local mod, sent = mock_socket({})
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			c:bind(0)
			stun._socket, stun._random_bytes = nil, orig
			assert_eq(asked, 12, "12 bytes asked for")
			assert_eq(sent[1].d:sub(9, 20), string.rep("\9", 12), "used as the transaction id")
			assert_eq(#stun._random_bytes(12), 12, "the real source gives 12 bytes")
		end
	},
	{
		name = "stun: wait serves the extra sockets it is given, dropping one with nothing to take",
		fn = function()
			local queue = {}
			local mod, _, now = mock_socket(queue)
			local other = {}
			local served = 0
			local select = mod.select
			local rounds = 0
			mod.select = function(r, w, t)
				rounds = rounds + 1
				if #r > 1 and rounds <= 2 then select(r, w, 0.1); return {other} end
				return select(r, w, t)
			end
			stun._socket = mod
			local c = stun.new("stun://unifi.example:3478/")
			local also = {{sock = other, fn = function() served = served + 1; return served < 2 end}}
			assert_false(c:wait(5, now, also), "no wake")
			stun._socket = nil
			assert_eq(served, 2, "served while readable")
			assert_eq(#also, 0, "dropped once it had nothing to take")
		end
	},
}
