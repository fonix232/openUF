--[[
	RADIUS Dynamic Authorization (RFC 5176: Disconnect-Request, CoA-Request)
	the way a UniFi AP takes it: one dispatcher on UDP 3799 in front of a
	DAS listener per WLAN.

	WHAT THE CONTROLLER SENDS (10.6.106 config generator VAZShipWTNxlo, only
	to a device claiming fw_caps 0x100000, for a WLAN whose RADIUS profile has
	DAS -- or Hotspot 2.0 -- and accounting on):
	  aaa.radius.dad.status=enabled, aaa.radius.dad.port=3799   the dispatcher
	  aaa.<n>.radius.dad.status=enabled                         WLAN takes part
	  aaa.<n>.radius.dad.client.<k>.cidr=<ip>/32, .secret       may send to it
	  aaa.<n>.radius.das.status=enabled, .port=3800+n           the WLAN's own
	  aaa.<n>.radius.das.client=<ip>, .secret                   its peer
	The dispatcher's clients are every accounting server; the WLAN's peer is
	the first one.

	HOW OPENUF DOES IT. hostapd runs the WLAN's DAS listener (UCI dae_port =
	the controller's 3800+n, dae_secret = its secret) with 127.0.0.1 as the
	only client, so nothing reaches it but the dispatcher. The dispatcher
	(this module, run in the announce process) accepts a request on 3799 from
	a listed client, picks the WLAN(s), relays the bytes unchanged from
	127.0.0.1 and sends hostapd's answer back. The request and response
	authenticators are keyed on the shared secret, not on addresses, so hostapd
	still checks the server's secret end to end.

	Which WLAN: a UniFi AP's own dispatch rule is in its firmware, which this
	project does not read. openUF's: a NAS-Identifier naming a WLAN's NAS ID,
	else a Called-Station-Id ("<BSSID>:<SSID>") naming a WLAN's SSID, else
	every WLAN the client may address, answered with the first ACK (a WLAN
	without the session NAKs it).
]]--

local M = {}

M.PORT    = 3799
M.FILE    = "/etc/openuf/das.json"
M.TIMEOUT = 2

M.CODE = {
	DISCONNECT_REQUEST = 40, DISCONNECT_ACK = 41, DISCONNECT_NAK = 42,
	COA_REQUEST = 43, COA_ACK = 44, COA_NAK = 45,
}
local ATTR_CALLED_STATION_ID = 30
local ATTR_NAS_IDENTIFIER    = 32

-- The dispatch plan from the provisioned WLANs: {{port, nas_id, ssid,
-- clients = {cidr, ...}}, ...}, Enterprise WLANs with DAS only (OpenWrt's
-- generator writes the DAS listener on EAP BSSes only).
function M.plan(vaps)
	local out = {}
	for _, vap in ipairs(vaps or {}) do
		local r = vap.radius
		local eap = vap.security and vap.security:find("-eap", 1, true) ~= nil
		if eap and r and r.das and #(r.das.clients or {}) > 0 then
			local clients = {}
			for _, c in ipairs(r.das.clients) do clients[#clients + 1] = c.cidr end
			out[#out + 1] = {port = r.das.port, nas_id = r.nas_id, ssid = vap.ssid,
				clients = clients}
		end
	end
	table.sort(out, function(a, b) return a.port < b.port end)
	return out
end

-- Write the plan to path, only when it changed (flash). An empty plan
-- removes the file. Returns true when the file changed.
function M.save(plan, path, cjson)
	path = path or M.FILE
	cjson = cjson or require("cjson")
	local new = (#plan > 0) and cjson.encode(plan) or nil
	local f = io.open(path, "r")
	local old = f and f:read("*a") or nil
	if f then f:close() end
	if new == old then return false end
	if not new then
		os.remove(path)
		return true
	end
	local t = io.open(path .. ".tmp", "w")
	if not t then return false end
	t:write(new)
	t:close()
	return os.rename(path .. ".tmp", path) and true or false
end

function M.load(text, cjson)
	local ok, t = pcall((cjson or require("cjson")).decode, text or "")
	if not ok or type(t) ~= "table" then return {} end
	local out = {}
	for _, e in ipairs(t) do
		if type(e) == "table" and tonumber(e.port) and type(e.clients) == "table" then
			out[#out + 1] = e
		end
	end
	return out
end

-- code, {type = first value}, or nil for anything that is not a well-formed
-- RADIUS packet.
function M.parse(data)
	if type(data) ~= "string" or #data < 20 then return nil end
	local len = data:byte(3) * 256 + data:byte(4)
	if len < 20 or len > #data then return nil end
	local attrs, i = {}, 21
	while i <= len do
		if i + 1 > len then return nil end
		local t, l = data:byte(i), data:byte(i + 1)
		if l < 2 or i + l - 1 > len then return nil end
		if attrs[t] == nil then attrs[t] = data:sub(i + 2, i + l - 1) end
		i = i + l
	end
	return data:byte(1), attrs
end

local function ipv4(s)
	local a, b, c, d = (s or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Whether ip is inside cidr ("a.b.c.d/n"; a bare address is /32, and a
-- non-IPv4 one must match exactly).
function M.in_cidr(ip, cidr)
	local net, bits = (cidr or ""):match("^([^/]+)/(%d+)$")
	net, bits = net or cidr, tonumber(bits) or 32
	local x, n = ipv4(ip), ipv4(net)
	if not (x and n) then return ip == net end
	if bits <= 0 then return true end
	if bits > 32 then return false end
	local size = 2 ^ (32 - bits)
	return math.floor(x / size) == math.floor(n / size)
end

-- The plan entries a request from src_ip should go to, in order.
function M.route(plan, src_ip, attrs)
	local allowed = {}
	for _, e in ipairs(plan) do
		for _, c in ipairs(e.clients) do
			if M.in_cidr(src_ip, c) then allowed[#allowed + 1] = e break end
		end
	end
	if #allowed == 0 then return allowed end
	local function only(pred)
		local hit = {}
		for _, e in ipairs(allowed) do if pred(e) then hit[#hit + 1] = e end end
		return hit
	end
	local nas = attrs[ATTR_NAS_IDENTIFIER]
	if nas then
		local hit = only(function(e) return e.nas_id == nas end)
		if #hit > 0 then return hit end
	end
	local called = attrs[ATTR_CALLED_STATION_ID]
	if called then
		local ssid = called:match("^%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x:(.*)$")
		if ssid then
			local hit = only(function(e) return e.ssid == ssid end)
			if #hit > 0 then return hit end
		end
	end
	return allowed
end

local function is_ack(code)
	return code == M.CODE.DISCONNECT_ACK or code == M.CODE.COA_ACK
end

-- The answer to one datagram from src_ip, or nil (nothing to send). relay:
-- function(port, data) -> hostapd's answer or nil.
function M.handle(plan, data, src_ip, relay)
	local code, attrs = M.parse(data)
	if code ~= M.CODE.DISCONNECT_REQUEST and code ~= M.CODE.COA_REQUEST then
		return nil
	end
	local answer
	for _, e in ipairs(M.route(plan, src_ip, attrs)) do
		local r = relay(e.port, data)
		if r then
			answer = r
			if is_ack(r:byte(1)) then break end
		end
	end
	return answer
end

-- relay() for handle(): ask hostapd's listener on 127.0.0.1:port.
function M.udp_relay(socket, timeout)
	return function(port, data)
		local u = socket.udp()
		if not u:setsockname("127.0.0.1", 0) then u:close() return nil end
		u:settimeout(timeout or M.TIMEOUT)
		u:sendto(data, "127.0.0.1", port)
		local r = u:receive()
		u:close()
		return r
	end
end

return M
