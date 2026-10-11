--[[
	http.lua -- the inform transport: one HTTP/1.0 POST per inform (TLS when
	the URL is https://, with luasec), and the IPv4 address of the inform
	URL's host, which the payload reports as inform_ip.
]]--

local M = {}

-- POST a binary payload to the inform URL.
-- Returns the raw response body or nil, error_msg.
function M.post(url, body)
	-- Parse URL
	local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(.*)")
	if not host then return nil, "invalid URL: " .. tostring(url) end
	local is_tls = (scheme == "https")
	port = tonumber(port) or (is_tls and 8443 or 8080)
	if path == "" then path = "/inform" end

	local socket = require("socket")
	local tcp = socket.tcp()
	tcp:settimeout(10)
	local ok, err = tcp:connect(host, port)
	if not ok then
		tcp:close()
		return nil, "connect failed: " .. tostring(err)
	end

	-- For https, wrap the socket in TLS. Previously the scheme was accepted but
	-- ignored, so an https:// URL sent the inform in cleartext to a TLS port and
	-- failed opaquely. Controllers use self-signed certs, so verification is off.
	if is_tls then
		local ok_ssl, ssl = pcall(require, "ssl")
		if not ok_ssl then
			tcp:close()
			return nil, "https inform URL requires luasec (apk add luasec); " ..
				"install it or use an http:// URL"
		end
		local wrapped, werr = ssl.wrap(tcp, {
			mode = "client", protocol = "any", verify = "none", options = "all",
		})
		if not wrapped then
			tcp:close()
			return nil, "TLS wrap failed: " .. tostring(werr)
		end
		tcp = wrapped
		tcp:settimeout(10)
		local ok_h, herr = tcp:dohandshake()
		if not ok_h then
			tcp:close()
			return nil, "TLS handshake failed: " .. tostring(herr)
		end
	end

	local req = table.concat({
		"POST " .. path .. " HTTP/1.0\r\n",
		"Host: " .. host .. ":" .. tostring(port) .. "\r\n",
		"Content-Type: application/x-binary\r\n",
		"Content-Length: " .. #body .. "\r\n",
		"\r\n",
		body
	})

	tcp:send(req)

	-- Read response (HTTP/1.0 — server closes after response). With a numeric
	-- pattern LuaSocket reads *exactly* N bytes and, when the peer closes before
	-- N arrive, returns (nil, "closed", partial). The inform response is almost
	-- always smaller than one read, so the body lives entirely in that `partial`
	-- third value — it must be captured or every response is silently lost
	-- ("HTTP nil") and adoption never completes.
	local response = {}
	while true do
		local chunk, recv_err, partial = tcp:receive(4096)
		if chunk then
			response[#response + 1] = chunk
		else
			if partial and #partial > 0 then
				response[#response + 1] = partial
			end
			if recv_err ~= "closed" then
				tcp:close()
				return nil, "recv error: " .. tostring(recv_err)
			end
			break
		end
	end
	tcp:close()

	local full = table.concat(response)
	-- Extract HTTP status
	local status = tonumber(full:match("HTTP/%S+ (%d+)"))
	if status ~= 200 then
		return nil, "HTTP " .. tostring(status)
	end

	-- Return body (after blank line separating headers)
	local body_start = full:find("\r\n\r\n")
	if body_start then
		return full:sub(body_start + 4)
	end
	return full
end

-- IPv4 address of the inform URL's host, for the payload's inform_ip. Literal
-- hosts pass through; names are resolved (luasocket) and cached for five
-- minutes so a heartbeat costs no DNS round trip. nil when unresolvable.
-- now: the current time; cache: a table the caller keeps between calls.
function M.inform_ip(url, now, cache)
	local host = type(url) == "string" and url:match("^%a+://%[?([^%]/:]+)") or nil
	if not host then return nil end
	if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end
	local c = cache[host]
	if c and now - c.at < 300 then return c.ip end
	local ok, ip = pcall(function()
		local socket = require("socket")
		local addr = socket.dns.toip(host)
		return addr
	end)
	ip = ok and type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") and ip or nil
	cache[host] = {ip = ip, at = now}
	return ip
end

return M
