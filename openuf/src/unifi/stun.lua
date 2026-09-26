--[[
	The controller's STUN channel: how a UniFi device is told to inform NOW.

	Every mgmt_cfg carries `stun_url=stun://<controller>:3478/`. A device keeps
	a UDP socket open, sends STUN Binding Requests (RFC 5389) to that address,
	and reports the address the controller saw it from as `connect_request_ip`
	/ `connect_request_port` in every inform. When the controller wants the
	device to inform immediately -- an admin hit Apply, Locate, Reconnect,
	Block -- its STUN service sends a bare 20-byte STUN-shaped header with
	message type 0x8888 (length 0; the "device simulator" variant puts the MAC
	in bytes 4-9) to that address. Receiving one means: inform now.

	Taken from the 10.6.106 controller's STUN server class (it builds the
	header with `integerToTwoBytes(34952)`); see docs/GAP-ANALYSIS-10.6.md P5.
	Without this channel every controller action waits for the next
	heartbeat -- up to the full inform interval.

	The binding answer is optional: on a flat LAN the controller reaches the
	device at its own address, so when no answer has come back the socket's
	local port is reported with the device's IP.
]]--

local M = {}

M.KEEPALIVE = 60      -- seconds between Binding Requests (NAT/conntrack keepalive)
M.WAKE_TYPE = 0x8888
M.MAGIC     = "\33\18\164\66"   -- 0x2112A442

-- Injectable: the luasocket module, and a random byte source for tests.
M._socket = nil
M._random_byte = function() return math.random(0, 255) end

local function get_socket()
	if M._socket then return M._socket end
	return require("socket")
end

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function r16(s, i)
	local a, b = s:byte(i, i + 1)
	return (a or 0) * 256 + (b or 0)
end

-- 8-bit XOR with plain arithmetic: openUF runs where no bit library exists.
local function bxor8(a, b)
	local r, p = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + p end
		a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
	end
	return r
end

-- stun://host[:port][/] -> host, port
function M.parse_url(url)
	if type(url) ~= "string" then return nil end
	local host, port = url:match("^stun://%[?([^%]/:]+)%]?:?(%d*)")
	if not host or host == "" then return nil end
	return host, tonumber(port) or 3478
end

-- The mapped address out of a Binding Success Response, or nil. Accepts the
-- RFC 5389 XOR-MAPPED-ADDRESS (0x0020, and 0x8020 from older drafts) and the
-- RFC 3489 MAPPED-ADDRESS (0x0001) that classic servers still send; IPv4 only.
function M.parse_response(data, txid)
	if type(data) ~= "string" or #data < 20 then return nil end
	if r16(data, 1) ~= 0x0101 then return nil end
	-- Bytes 9-20 are the transaction id; an RFC 3489 server echoes all 16
	-- bytes (cookie + id), which puts the same id in the same place.
	if txid and data:sub(9, 20) ~= txid then return nil end
	local len = r16(data, 3)
	local i, stop = 21, math.min(#data, 20 + len)
	local mapped_ip, mapped_port
	while i + 3 <= stop do
		local atype, alen = r16(data, i), r16(data, i + 2)
		local v = data:sub(i + 4, i + 3 + alen)
		if #v >= 8 and v:byte(2) == 1 then
			if atype == 0x0020 or atype == 0x8020 then
				local m1, m2 = M.MAGIC:byte(1), M.MAGIC:byte(2)
				local port = bxor8(v:byte(3), m1) * 256 + bxor8(v:byte(4), m2)
				local o = {}
				for k = 1, 4 do o[k] = bxor8(v:byte(4 + k), M.MAGIC:byte(k)) end
				return table.concat(o, "."), port
			elseif atype == 0x0001 and not mapped_ip then
				mapped_ip = table.concat({v:byte(5), v:byte(6), v:byte(7), v:byte(8)}, ".")
				mapped_port = r16(v, 3)
			end
		end
		i = i + 4 + alen + ((4 - alen % 4) % 4)
	end
	return mapped_ip, mapped_port
end

-- True for the controller's connection request.
function M.is_wake(data)
	return type(data) == "string" and #data >= 20 and r16(data, 1) == M.WAKE_TYPE
end

local Client = {}
Client.__index = Client

-- A client, or nil when the URL is unusable or no socket can be had.
-- `local_port` should be stable across restarts: the controller keeps the
-- connect_request address it last stored, and an ephemeral port after a
-- daemon restart leaves it poking a NAT mapping nobody listens on any more
-- (seen on the bench: the wake went to the old port and was dropped). Falls
-- back to an ephemeral port when that one is taken.
function M.new(url, local_port)
	local host, port = M.parse_url(url)
	if not host then return nil end
	local socket = get_socket()
	local ok_ip, ip = pcall(function() return socket.dns.toip(host) end)
	ip = ok_ip and ip or nil
	if not ip then return nil end
	local udp = socket.udp()
	if not udp then return nil end
	udp:settimeout(0)
	if not (local_port and udp:setsockname("*", local_port)) and not udp:setsockname("*", 0) then
		udp:close()
		return nil
	end
	local _, lport = udp:getsockname()
	return setmetatable({udp = udp, url = url, host_ip = ip, port = port,
		lport = tonumber(lport), next_bind = 0}, Client)
end

-- A Binding Request the controller will answer. Its STUN service is a
-- classic RFC 3489 server (jstun) that rejects a request WITHOUT a
-- CHANGE-REQUEST attribute ("Message attribute change request is not set")
-- and any attribute other than CHANGE-REQUEST (0x0003) / RESPONSE-ADDRESS
-- (0x0002) -- so a bare RFC 5389 request gets silence. The zero
-- CHANGE-REQUEST asks for no change of address or port. The magic cookie
-- keeps the request valid RFC 5389 too; to a 3489 server it is simply the
-- first four bytes of a 16-byte transaction id.
function M.binding_request(txid)
	local change_request = u16(0x0003) .. u16(4) .. "\0\0\0\0"
	return u16(0x0001) .. u16(#change_request) .. M.MAGIC .. txid .. change_request
end

function Client:bind(now)
	local t = {}
	for k = 1, 12 do t[k] = string.char(M._random_byte()) end
	self.txid = table.concat(t)
	self.udp:sendto(M.binding_request(self.txid), self.host_ip, self.port)
	self.next_bind = now + M.KEEPALIVE
end

-- Drain the socket. Returns true when a connection request was among it.
function Client:poll()
	local woke = false
	for _ = 1, 32 do
		local data = self.udp:receivefrom()
		if not data then break end
		if M.is_wake(data) then
			woke = true
		else
			local ip, port = M.parse_response(data, self.txid)
			if ip then self.mapped_ip, self.mapped_port = ip, port end
		end
	end
	return woke
end

-- What to report as connect_request_ip / connect_request_port.
function Client:address(fallback_ip)
	return self.mapped_ip or fallback_ip, self.mapped_port or self.lport
end

function Client:close()
	pcall(function() self.udp:close() end)
end

-- Wait up to `wait` seconds on the client's socket, keeping the binding
-- fresh. Returns true when the controller asked for an inform before the
-- time was up. `now` is a seconds clock (socket.gettime).
function Client:wait(wait, now_fn)
	local socket = get_socket()
	local deadline = now_fn() + wait
	while true do
		local now = now_fn()
		if now >= self.next_bind then self:bind(now) end
		local remaining = deadline - now
		if remaining <= 0 then return false end
		local slice = math.min(remaining, math.max(0.05, self.next_bind - now))
		local r = socket.select({self.udp}, nil, slice)
		if r and #r > 0 and self:poll() then return true end
	end
end

return M
