--[[
	The guest portal's local HTTP answer (LAB-VALIDATED UPSTREAM ONLY, never
	run on hardware): what sends an unauthorized guest to the controller's
	portal. The nft side -- the marking, the hand-off to the bridge and the
	NAT redirect to PORT -- is guestguard.lua's, the one owner of the guest
	tables.

	inform.lua listens on PORT while the portal is enforced and answers
	between heartbeats with a 302 to redirector.url, carrying id=<guest MAC,
	from /proc/net/arp>, ap=<AP MAC>, t=<now>, url=<what the guest asked
	for> and ssid=: the parameters the controller's redirect handler reads
	(CFR, 10.4.57, devmgr/IXbVCbWPDmZdkfbJ; PROTOCOL-VALIDATION.md, "Guest
	portal (Hotspot)"). A request is read with a bound, so a guest cannot
	hold the inform loop.
]]--

local M = {}

M.PORT = require("openwrt.guestguard").PORTAL_PORT

local function is_mac(s)
	return type(s) == "string" and s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function urlencode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

-- The station MAC behind an IPv4 address, from /proc/net/arp's text: a
-- complete entry (flags 0x2) only.
function M.arp_mac(ip, text)
	for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local a, flags, mac = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)")
		if a == ip and tonumber(flags) and tonumber(flags) % 4 >= 2 and is_mac(mac)
				and mac ~= "00:00:00:00:00:00" then
			return mac:lower()
		end
	end
	return nil
end

-- Where the portal is: the controller's redirect handler takes the guest
-- from id=, the AP from ap=, and refuses a t= more than 60 s from its own
-- clock.
function M.location(ctx, mac, orig_url, ssid, now)
	local q = {"id=" .. urlencode(mac), "ap=" .. urlencode(ctx.ap or ""), "t=" .. string.format("%.0f", now)}
	if orig_url then q[#q + 1] = "url=" .. urlencode(orig_url) end
	if ssid then q[#q + 1] = "ssid=" .. urlencode(ssid) end
	return ctx.url .. (ctx.url:find("?", 1, true) and "&" or "?") .. table.concat(q, "&")
end

-- The request line and Host header, read with a bound.
local function read_request(client)
	local first, host
	for i = 1, 32 do
		local line = client:receive("*l")
		if not line or line == "" then break end
		if i == 1 then
			first = line
		else
			local h = line:match("^[Hh][Oo][Ss][Tt]:%s*([%w%.%-:%[%]]+)%s*$")
			if h then host = h end
		end
	end
	local path = first and first:match("^%u+ (/%S*) HTTP/%d%.%d$")
	if host and path and #path <= 1024 then return "http://" .. host .. path end
	return nil
end

-- Answer one waiting connection, if any. ctx: {url, ap, ssid_for(mac) or nil,
-- arp() -> /proc/net/arp text, now()}. Returns true when it answered.
function M.serve_one(server, ctx)
	local client = server:accept()
	if not client then return false end
	client:settimeout(1)
	local ok, err = pcall(function()
		local ip = client:getpeername()
		local orig = read_request(client)
		local mac = ip and M.arp_mac(ip, ctx.arp())
		if not mac then
			client:send("HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
				.. "Content-Length: 0\r\nConnection: close\r\n\r\n")
			return
		end
		local ssid = ctx.ssid_for and ctx.ssid_for(mac) or nil
		client:send("HTTP/1.1 302 Found\r\nLocation: " .. M.location(ctx, mac, orig, ssid, ctx.now())
			.. "\r\nCache-Control: no-cache, no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	end)
	client:close()
	if not ok then io.stderr:write("guestportal: answer failed: " .. tostring(err) .. "\n") end
	return true
end

-- A listening socket on M.PORT, or nil and the error.
function M.listen(socket)
	local server, err = socket.bind("*", M.PORT)
	if not server then return nil, err end
	server:settimeout(0)
	return server
end

return M
